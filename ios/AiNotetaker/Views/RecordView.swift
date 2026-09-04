import SwiftUI
import SwiftData
import UIKit

struct RecordView: View {
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @Environment(\.modelContext) private var context
    @AppStorage("autoUpload") private var autoUpload = true
    @State private var showingSaved = false
    @State private var lastSavedTitle = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                GeometryReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            Spacer(minLength: 8)
                            recordingCard
                            Spacer(minLength: 10)
                            controls
                            Spacer(minLength: 6)
                        }
                        .frame(minHeight: max(0, proxy.size.height - 12))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }

                if showingSaved {
                    savedToast
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .alert("Recording", isPresented: Binding(
                get: { recorder.errorMessage != nil },
                set: { if !$0 { recorder.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(recorder.errorMessage ?? "")
            }
        }
    }

    private var recordingCard: some View {
        AppCard {
            VStack(spacing: 20) {
                HStack {
                    Label("VOICE MEMORY", systemImage: "waveform")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.accent)
                    Spacer()
                    liveStateBadge
                }

                ZStack {
                    Circle()
                        .fill((recorder.isClipping ? Color.red : AppTheme.accent).opacity(0.10))
                        .frame(width: 74, height: 74)
                    Circle()
                        .stroke((recorder.isClipping ? Color.red : AppTheme.accent).opacity(0.16), lineWidth: 1)
                        .frame(width: 74, height: 74)
                        .scaleEffect(recorder.state == .recording ? 1.14 : 1)
                        .opacity(recorder.state == .recording ? 0.15 : 0.8)
                        .animation(
                            .easeInOut(duration: 1.25).repeatForever(autoreverses: true),
                            value: recorder.state == .recording
                        )
                    Image(systemName: recorder.state == .idle ? "waveform" : "waveform.badge.mic")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(recorder.isClipping ? Color.red : AppTheme.accent)
                        .symbolEffect(.pulse, options: .repeating, isActive: recorder.state == .recording)
                }

                Text(formatDuration(recorder.elapsed))
                    .font(.system(size: 62, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.65)
                    .accessibilityLabel("Recording time \(formatDuration(recorder.elapsed))")

                VStack(spacing: 12) {
                    Text(statusText)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(recorder.isClipping ? Color.red : Color.secondary)
                        .animation(.easeInOut(duration: 0.2), value: recorder.isClipping)

                    LevelMeter(level: recorder.level)
                }

                if !recorder.inputDescription.isEmpty {
                    Label {
                        Text(recorder.inputDescription)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    } icon: {
                        Image(systemName: "mic.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(AppTheme.quietSurface, in: Capsule())
                    .accessibilityLabel("Active input: \(recorder.inputDescription)")
                } else if recorder.state == .idle {
                    HStack(spacing: 8) {
                        MetadataPill(text: "24-bit", systemImage: "waveform.path")
                        MetadataPill(text: "Lossless", systemImage: "checkmark.seal")
                        MetadataPill(text: "Private", systemImage: "lock.fill")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var liveStateBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(stateLabel)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(stateColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(stateColor.opacity(0.11), in: Capsule())
    }

    private var stateLabel: String {
        switch recorder.state {
        case .idle: return "Ready"
        case .recording: return recorder.isClipping ? "Too loud" : "Recording"
        case .paused: return "Paused"
        }
    }

    private var stateColor: Color {
        if recorder.isClipping { return .red }
        switch recorder.state {
        case .idle: return .green
        case .recording: return .red
        case .paused: return .orange
        }
    }

    private var statusText: String {
        switch recorder.state {
        case .idle:
            return "Ready when you are"
        case .recording:
            return recorder.isClipping
                ? "Move the microphone farther away to protect the recording"
                : "Recording safely — you can lock the screen"
        case .paused:
            return "Paused — resume or save what you captured"
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle:
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await recorder.start() }
            } label: {
                VStack(spacing: 11) {
                    primaryControl(icon: "mic.fill", color: .red)
                    Text("Start recording")
                        .font(.headline)
                    Text("One tap. Your original stays untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")
            .accessibilityHint("Records a 24-bit Apple Lossless voice memory")
        case .recording, .paused:
            HStack(spacing: 44) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if recorder.state == .recording { recorder.pause() } else { recorder.resume() }
                } label: {
                    secondaryControl(
                        icon: recorder.state == .recording ? "pause.fill" : "play.fill",
                        title: recorder.state == .recording ? "Pause" : "Resume"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    finish()
                } label: {
                    VStack(spacing: 10) {
                        primaryControl(icon: "stop.fill", color: .red)
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop and save recording")
            }
        }
    }

    private func primaryControl(icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 33, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 88, height: 88)
            .background(color.gradient, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.32), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.34), radius: 16, y: 9)
            .contentShape(Circle())
    }

    private func secondaryControl(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .frame(width: 64, height: 64)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.07))
                }
                .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var savedToast: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved to Library")
                    .font(.subheadline.weight(.semibold))
                Text(savedStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    private var savedStatusText: String {
        guard autoUpload && api.isConfigured else { return "Stored safely on this iPhone" }
        return connectivity.isOnline
            ? "Uploading for transcription"
            : "Stored safely — uploads automatically when online"
    }

    private func finish() {
        guard let result = recorder.stop() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let title = "Recording " + Date().formatted(date: .abbreviated, time: .shortened)
        let recording = Recording(
            title: title,
            duration: result.duration,
            fileName: result.url.lastPathComponent,
            fileSize: RecordingStore.fileSize(result.url)
        )
        if autoUpload && api.isConfigured {
            recording.serverStatus = "queued"
        }
        context.insert(recording)
        try? context.save()
        lastSavedTitle = title
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            showingSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeOut(duration: 0.2)) {
                showingSaved = false
            }
        }
        if autoUpload && api.isConfigured && connectivity.isOnline {
            Task { await SyncManager.upload(recording, api: api, context: context) }
        }
    }
}
