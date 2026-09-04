import SwiftUI
import SwiftData

struct RecordingDetailView: View {
    @Bindable var recording: Recording
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @StateObject private var player = AudioPlayer()
    @State private var busy = false
    @State private var message: String?
    @State private var variant = "original"
    @State private var cleanURL: URL?
    @State private var editingTranscript = false
    @State private var transcriptDraft = ""
    @State private var transcriptEditorError: String?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                LazyVStack(spacing: 14) {
                    heroCard
                    playbackCard
                    actionsCard

                    if let transcript = recording.transcript, !transcript.isEmpty {
                        transcriptCard(transcript)
                    }

                    if let analysis = recording.analysis {
                        analysisCards(analysis)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)

            if busy {
                ProgressView()
                    .controlSize(.large)
                    .padding(22)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
                    .accessibilityLabel("Working")
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $editingTranscript) {
            transcriptEditor
        }
        .onDisappear { player.stop() }
        .alert("AiNotetaker", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var heroCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    BrandMark(systemImage: "waveform", size: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VOICE MEMORY")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(AppTheme.accent)
                        Text(recording.createdAt.formatted(date: .long, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    StatusBadge(status: recording.serverStatus ?? "local")
                }

                TextField("Recording title", text: $recording.title)
                    .font(.title2.weight(.bold))
                    .textFieldStyle(.plain)
                    .autoDirection(for: recording.title)
                    .submitLabel(.done)
                    .onSubmit { rename() }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        MetadataPill(text: formatDuration(recording.duration), systemImage: "clock")
                        MetadataPill(text: formatBytes(recording.fileSize), systemImage: "externaldrive")
                        MetadataPill(
                            text: recording.hasDenoised == true ? "Original + cleaned" : "Original preserved",
                            systemImage: "checkmark.shield"
                        )
                    }
                }

                if let error = recording.lastError, !error.isEmpty {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
        }
    }

    private var playbackCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(
                    title: "Listen",
                    subtitle: recording.hasDenoised == true ? "Choose the source you prefer" : "Your untouched original",
                    systemImage: "play.circle.fill"
                )

                Picker("Source", selection: $variant) {
                    Text("Original").tag("original")
                    if recording.hasDenoised == true {
                        Text("Noise-removed").tag("denoised")
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: variant) { _, _ in loadPlayer() }

                HStack(spacing: 15) {
                    Button {
                        if player.loadedURL == nil { loadPlayer() }
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(AppTheme.brandGradient, in: Circle())
                            .shadow(color: AppTheme.accent.opacity(0.24), radius: 10, y: 5)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    VStack(spacing: 5) {
                        Slider(value: Binding(get: { player.progress }, set: { player.seek(to: $0) }))
                            .tint(AppTheme.accent)
                        HStack {
                            Text(formatDuration(player.currentTime))
                            Spacer()
                            Text(formatDuration(player.duration > 0 ? player.duration : recording.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actionsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(
                    title: "Actions",
                    subtitle: actionSubtitle,
                    systemImage: "wand.and.stars"
                )

                if recording.serverId == nil {
                    Button { upload() } label: {
                        actionLabel(
                            uploadActionTitle,
                            systemImage: recording.serverStatus == "queued" ? "clock.arrow.circlepath" : "icloud.and.arrow.up",
                            emphasized: true
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !api.isConfigured || !connectivity.isOnline)
                    if !api.isConfigured {
                        Text("Connect your server in Settings to enable transcription.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button { refresh() } label: {
                        actionLabel("Refresh status", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)

                    if recording.serverStatus == "error" || recording.serverStatus == "done" {
                        Button { reprocess() } label: {
                            actionLabel("Re-run full processing", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }

                    if let transcript = recording.transcript, !transcript.isEmpty {
                        Button { reanalyze() } label: {
                            actionLabel("Refresh AI memory", systemImage: "sparkles")
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)

                        Button { saveAsNote() } label: {
                            actionLabel(
                                recording.noteId == nil ? "Save transcript as a note" : "Saved as a note",
                                systemImage: recording.noteId == nil ? "note.text.badge.plus" : "checkmark.circle.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || recording.noteId != nil)

                        ShareLink(item: transcript) {
                            actionLabel("Share transcript", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var actionSubtitle: String {
        if recording.serverStatus == "queued" {
            return "Safe on this iPhone — upload resumes automatically"
        }
        if recording.serverId == nil { return "Turn this audio into a searchable memory" }
        return "Manage processing and use the transcript"
    }

    private var uploadActionTitle: String {
        if busy { return "Uploading…" }
        if !connectivity.isOnline || recording.serverStatus == "queued" {
            return "Waiting for connection"
        }
        return "Upload, clean & transcribe"
    }

    private func actionLabel(_ title: String, systemImage: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 28)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .opacity(0.55)
        }
        .foregroundStyle(emphasized ? Color.white : AppTheme.accent)
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(
            emphasized ? AnyShapeStyle(AppTheme.brandGradient) : AnyShapeStyle(AppTheme.accent.opacity(0.09)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func transcriptCard(_ transcript: String) -> some View {
        memoryCard("Transcript", subtitle: "Exactly what was spoken", systemImage: "text.quote", tint: .blue) {
            if let model = recording.transcriptionModel, !model.isEmpty {
                Label(
                    recording.transcriptCorrected == true ? "Created with \(model) · corrected by you" : "Created with \(model)",
                    systemImage: recording.transcriptCorrected == true ? "person.crop.circle.badge.checkmark" : "cpu"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(transcript)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .autoDirection(for: transcript)

            if recording.serverId != nil {
                Button {
                    transcriptDraft = transcript
                    editingTranscript = true
                } label: {
                    Label("Correct transcript", systemImage: "pencil.line")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
        }
    }

    private var transcriptEditor: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                TextEditor(text: $transcriptDraft)
                    .font(.body)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    }
                    .padding(16)
                    .autoDirection(for: transcriptDraft)
            }
            .navigationTitle("Correct Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingTranscript = false }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveTranscript()
                    } label: {
                        if busy { ProgressView() } else { Text("Save") }
                    }
                    .fontWeight(.semibold)
                    .disabled(busy || transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Saving also refreshes the summary, decisions, and action items so they stay consistent with your correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .interactiveDismissDisabled(busy)
            .alert("Couldn’t Save Transcript", isPresented: Binding(
                get: { transcriptEditorError != nil },
                set: { if !$0 { transcriptEditorError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(transcriptEditorError ?? "")
            }
        }
    }

    @ViewBuilder
    private func analysisCards(_ analysis: Analysis) -> some View {
        if let summary = analysis.summary, !summary.isEmpty {
            memoryCard("Summary", subtitle: "The short version", systemImage: "text.alignleft", tint: AppTheme.accent) {
                Text(summary)
                    .lineSpacing(3)
                    .autoDirection(for: summary)
            }
        }

        if let points = analysis.keyPoints, !points.isEmpty {
            memoryCard("Key Points", systemImage: "list.bullet", tint: .blue) {
                memoryList(points, systemImage: "circle.fill", tint: .blue)
            }
        }

        if let decisions = analysis.decisions, !decisions.isEmpty {
            memoryCard("Decisions", subtitle: "What was agreed", systemImage: "checkmark.seal.fill", tint: .green) {
                memoryList(decisions, systemImage: "checkmark.circle.fill", tint: .green)
            }
        }

        if let items = analysis.actionItems, !items.isEmpty {
            memoryCard("Action Items", subtitle: "What happens next", systemImage: "checklist", tint: .orange) {
                memoryList(items, systemImage: "circle", tint: .orange)
            }
        }

        if let questions = analysis.openQuestions, !questions.isEmpty {
            memoryCard("Open Questions", subtitle: "Still to resolve", systemImage: "questionmark.circle.fill", tint: .purple) {
                memoryList(questions, systemImage: "questionmark.circle", tint: .purple)
            }
        }

        if let people = analysis.people, !people.isEmpty {
            memoryCard("People & Organizations", systemImage: "person.2.fill", tint: .indigo) {
                Text(people.joined(separator: "  ·  "))
                    .font(.subheadline.weight(.medium))
                    .autoDirection(for: people.joined(separator: "  ·  "))
            }
        }

        if let topics = analysis.topics, !topics.isEmpty {
            memoryCard("Topics", systemImage: "number", tint: .pink) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(topics, id: \.self) { topic in
                            Text("#\(topic)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(AppTheme.accent.opacity(0.09), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func memoryCard<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                content()
            }
        }
    }

    private func memoryList(_ items: [String], systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { indexed in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(tint)
                        .frame(width: 18, height: 20)
                    Text(indexed.element)
                        .font(.subheadline)
                        .lineSpacing(2)
                        .autoDirection(for: indexed.element)
                }
            }
        }
    }

    // MARK: - Playback

    private func loadPlayer() {
        if variant == "denoised" {
            if let cleanURL {
                player.load(cleanURL)
                return
            }
            guard let serverId = recording.serverId else { return }
            busy = true
            Task {
                do {
                    let url = try await api.downloadAudio(serverId, variant: "denoised")
                    cleanURL = url
                    player.load(url)
                } catch {
                    message = error.localizedDescription
                    variant = "original"
                }
                busy = false
            }
        } else {
            player.load(recording.fileURL)
        }
    }

    // MARK: - Actions

    private func upload() {
        busy = true
        Task {
            await SyncManager.upload(recording, api: api, context: context)
            busy = false
        }
    }

    private func refresh() {
        busy = true
        Task {
            await SyncManager.refresh(recording, api: api, context: context)
            busy = false
        }
    }

    private func reprocess() {
        guard let serverId = recording.serverId else { return }
        busy = true
        Task {
            do {
                try await api.processRecording(serverId)
                recording.serverStatus = "processing"
                recording.lastError = nil
                try? context.save()
                await SyncManager.refreshUntilDone(recording, api: api, context: context)
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func reanalyze() {
        guard let serverId = recording.serverId else { return }
        busy = true
        Task {
            do {
                let server = try await api.analyzeRecording(serverId)
                SyncManager.apply(server, to: recording)
                try? context.save()
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func saveAsNote() {
        guard let serverId = recording.serverId else { return }
        busy = true
        Task {
            do {
                let note = try await api.createNote(fromRecording: serverId)
                recording.noteId = note.id
                try? context.save()
                message = "Saved as note “\(note.title)”."
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func rename() {
        try? context.save()
        guard let serverId = recording.serverId else { return }
        let title = recording.title
        Task { _ = try? await api.renameRecording(serverId, title: title) }
    }

    private func saveTranscript() {
        guard let serverId = recording.serverId else { return }
        let corrected = transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return }
        busy = true
        Task {
            do {
                let server = try await api.updateTranscript(
                    serverId, transcript: corrected, refreshAnalysis: true
                )
                SyncManager.apply(server, to: recording)
                try? context.save()
                editingTranscript = false
            } catch {
                transcriptEditorError = error.localizedDescription
            }
            busy = false
        }
    }
}
