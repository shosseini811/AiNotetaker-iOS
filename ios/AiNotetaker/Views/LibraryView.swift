import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var api: APIClient
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var search = ""
    @State private var showReport = false

    private var filtered: [Recording] {
        guard !search.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || ($0.transcript ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var totalDuration: Double {
        recordings.reduce(0) { $0 + $1.duration }
    }

    private var readyCount: Int {
        recordings.filter { $0.serverStatus == "done" }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .navigationTitle("Library")
            .navigationDestination(for: Recording.self) { recording in
                RecordingDetailView(recording: recording)
            }
            .searchable(text: $search, prompt: "Search recordings and transcripts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showReport = true } label: {
                        Image(systemName: "sparkles")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Create AI report")
                    .disabled(!api.isConfigured)
                }
            }
            .sheet(isPresented: $showReport) { ReportView() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if recordings.isEmpty {
            ContentUnavailableView {
                Label("Your voice memory starts here", systemImage: "waveform.badge.mic")
            } description: {
                Text("Record a thought or meeting. The original audio stays yours, and AiNotetaker makes it searchable.")
            }
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List {
                librarySummary
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(filtered) { recording in
                    NavigationLink(value: recording) {
                        RecordingRow(recording: recording)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onDelete(perform: delete)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 16, for: .scrollContent)
        }
    }

    private var librarySummary: some View {
        AppCard {
            HStack(spacing: 14) {
                BrandMark(systemImage: "waveform")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Memory")
                        .font(.title3.weight(.bold))
                    Text("Everything you captured, safely organized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    MetadataPill(
                        text: "\(recordings.count) \(recordings.count == 1 ? "recording" : "recordings")",
                        systemImage: "waveform"
                    )
                    MetadataPill(text: formatDuration(totalDuration), systemImage: "clock")
                    if readyCount > 0 {
                        MetadataPill(text: "\(readyCount) ready", systemImage: "sparkles")
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { filtered[$0] }
        for recording in targets {
            RecordingStore.delete(recording.fileURL)
            if let serverId = recording.serverId {
                Task { try? await api.deleteRecording(serverId) }
            }
            context.delete(recording)
        }
        try? context.save()
    }
}

struct RecordingRow: View {
    let recording: Recording

    private var preview: String? {
        let text = (recording.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.10))
                Image(systemName: recording.serverStatus == "done"
                      ? "waveform.badge.checkmark"
                      : "waveform")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(recording.title)
                    .font(.headline)
                    .lineLimit(1)
                    .autoDirection(for: recording.title)

                HStack(spacing: 6) {
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(formatDuration(recording.duration))
                    Spacer(minLength: 6)
                    StatusBadge(status: recording.serverStatus ?? "local")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let preview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .autoDirection(for: preview)
                } else {
                    Text("Original audio is safely stored")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        }
        .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
