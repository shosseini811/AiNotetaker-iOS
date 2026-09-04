import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @AppStorage("autoUpload") private var autoUpload = true
    @AppStorage("micMode") private var micMode = "voice"
    @AppStorage("allowBluetoothMic") private var allowBluetoothMic = false
    @AppStorage("mixWithOtherAudio") private var mixWithOtherAudio = false
    @State private var status: String?
    @State private var checking = false
    @State private var config: ServerConfig?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                Form {
                    settingsIntro

                    Section {
                        LabeledContent {
                            TextField("https://mac-mini.your-tailnet.ts.net", text: $api.serverURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Label("Address", systemImage: "server.rack")
                        }

                        LabeledContent {
                            SecureField("Required", text: $api.token)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Label("API token", systemImage: "key.fill")
                        }

                        Button { test() } label: {
                            HStack {
                                if checking {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                }
                                Text(checking ? "Checking…" : "Test Connection")
                                    .fontWeight(.semibold)
                                Spacer()
                                if !checking { Image(systemName: "arrow.right") }
                            }
                            .frame(minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .disabled(checking || !api.isConfigured)

                        if let status {
                            Label {
                                Text(status.dropFirst(2))
                            } icon: {
                                Image(systemName: status.hasPrefix("✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            }
                            .font(.footnote)
                            .foregroundStyle(status.hasPrefix("✓") ? Color.green : Color.red)
                        }
                    } header: {
                        Label("Private Server", systemImage: "externaldrive.connected.to.line.below")
                    } footer: {
                        Text("Your Mac remains the system of record. The token protects access from other devices.")
                    }

                    Section {
                        LabeledContent {
                            Label(connectivity.routeLabel,
                                  systemImage: connectivity.isOnline ? "checkmark.circle.fill" : "wifi.slash")
                                .foregroundStyle(connectivity.isOnline ? Color.green : Color.orange)
                        } label: {
                            Text("Phone network")
                        }

                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: accessIcon)
                                .font(.title3)
                                .foregroundStyle(accessColor)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(accessTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text(accessDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)

                        if let active = api.activeEndpoint {
                            LabeledContent("Using address", value: active.displayName)
                                .font(.footnote)
                        }

                        if !api.learnedRemoteURL.isEmpty {
                            Label("Learned from your Mac: \(api.learnedRemoteURL)",
                                  systemImage: "checkmark.seal.fill")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        } else if !api.remoteAccessHint.isEmpty {
                            Label(api.remoteAccessHint, systemImage: "wrench.and.screwdriver.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }

                        if api.hasAddressThatWorksAnywhere && api.token.isEmpty {
                            Label("Add the API token printed by the Mac setup script.",
                                  systemImage: "exclamationmark.shield.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Label("Access Anywhere", systemImage: "network.badge.shield.half.filled")
                    } footer: {
                        Text("Your Mac reports every address it answers on, and AiNotetaker uses whichever one works right now — home Wi‑Fi, other Wi‑Fi, or cellular. Recordings made offline stay safely queued on this iPhone.")
                    }

                    if let config {
                        Section {
                            readinessRow("Speech-to-text", ready: config.transcriptionConfigured)
                            if let model = config.transcriptionModel {
                                LabeledContent("Transcription model", value: model)
                            }
                            readinessRow("AI analysis", ready: config.analysisConfigured)
                            LabeledContent("Noise removal", value: config.denoiseEngine)
                            LabeledContent("Version", value: config.version ?? "–")
                        } header: {
                            Label("System Health", systemImage: "heart.text.square")
                        }
                    }

                    Section {
                        Picker("Pickup", selection: $micMode) {
                            Label("Voice · cardioid", systemImage: "person.wave.2").tag("voice")
                            Label("Room · omnidirectional", systemImage: "person.3").tag("room")
                            Label("Automatic", systemImage: "wand.and.stars").tag("auto")
                        }
                        Toggle(isOn: $allowBluetoothMic) {
                            Label("Allow Bluetooth microphone", systemImage: "airpodspro")
                        }
                        Toggle(isOn: $mixWithOtherAudio) {
                            Label("Keep other audio playing", systemImage: "speaker.wave.2")
                        }

                        VStack(alignment: .leading, spacing: 15) {
                            qualityNote(
                                "waveform",
                                "Lossless original",
                                "24-bit Apple Lossless at the microphone’s native rate, with iOS processing off."
                            )
                            qualityNote(
                                "cable.connector",
                                "Best input automatically",
                                "USB and wired microphones are preferred. Bluetooth stays off by default because its call-quality codec loses detail."
                            )
                            qualityNote(
                                "person.wave.2",
                                "Match the room",
                                "Voice focuses on one speaker. Room captures people around the phone."
                            )
                            qualityNote(
                                "speaker.wave.2",
                                "Other audio is a special case",
                                "Enable mixing only when you want the microphone to capture sound playing through the phone speaker."
                            )
                        }
                        .padding(.vertical, 5)
                    } header: {
                        Label("Microphone", systemImage: "mic.fill")
                    }

                    Section {
                        Toggle(isOn: $autoUpload) {
                            Label("Upload and transcribe automatically", systemImage: "icloud.and.arrow.up")
                        }
                    } header: {
                        Label("After Recording", systemImage: "arrow.triangle.2.circlepath")
                    } footer: {
                        Text("Recording continues when the phone is locked. The original stays untouched; noise removal creates a separate 24-bit copy.")
                    }

                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                            Text(privacyDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Label("Privacy", systemImage: "hand.raised.fill")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
        }
    }

    private var settingsIntro: some View {
        AppCard {
            HStack(spacing: 14) {
                BrandMark(systemImage: "slider.horizontal.3")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Made for your workflow")
                        .font(.title3.weight(.bold))
                    Text("Quality first, with sensible defaults")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func readinessRow(_ title: String, ready: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(ready ? "Ready" : "Not configured",
                  systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ready ? Color.green : Color.orange)
        }
    }

    private func qualityNote(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .foregroundStyle(AppTheme.accent)
                .background(AppTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacyDescription: String {
        let destination: String
        switch config?.transcriptionProvider {
        case "azure-mai": destination = "Microsoft Azure Speech"
        case "openai": destination = "your configured speech provider"
        default: destination = "OpenRouter"
        }
        return "Audio goes only to your server and \(destination) for transcription. AI analysis receives transcript text, never the audio again."
    }

    /// What matters is whether *any* saved address survives leaving this Wi‑Fi,
    /// not only the one that was typed here — the app learns the rest from the Mac.
    private var access: ServerAddressKind {
        api.candidates.first { $0.worksAwayFromWiFi }?.kind ?? api.serverAddressKind
    }

    private var accessTitle: String {
        switch access {
        case .tailscale: return "Private remote access"
        case .secureRemote: return "Secure remote address"
        case .localOnly: return "Same Wi‑Fi only"
        case .insecureRemote: return "Insecure remote address"
        case .invalid: return "Invalid server address"
        case .unset: return "Add your server address"
        }
    }

    private var accessDetail: String {
        switch access {
        case .tailscale:
            return "Ready to reach your Mac privately from Wi‑Fi or cellular. AiNotetaker switches between your saved addresses on its own."
        case .secureRemote:
            return "This HTTPS address works away from home. Keep the API token enabled."
        case .localOnly:
            return "Every address AiNotetaker knows is local (192.168.x.x, 10.x.x.x, localhost, or .local), so uploads pause once you leave this network. Run scripts/setup-remote-access.sh on the Mac — the app picks up the permanent address by itself the next time it connects here."
        case .insecureRemote:
            return "Use HTTPS or Tailscale before sending private recordings over this address."
        case .invalid:
            return "Check the spelling and use a complete server hostname."
        case .unset:
            return "Enter the address your Mac prints at startup. AiNotetaker learns any other address it answers on from there."
        }
    }

    private var accessIcon: String {
        switch access {
        case .tailscale, .secureRemote: return "lock.shield.fill"
        case .localOnly: return "wifi.router.fill"
        case .insecureRemote, .invalid: return "exclamationmark.triangle.fill"
        case .unset: return "link.badge.plus"
        }
    }

    private var accessColor: Color {
        switch access {
        case .tailscale, .secureRemote: return .green
        case .localOnly, .unset: return .orange
        case .insecureRemote, .invalid: return .red
        }
    }

    private func test() {
        checking = true
        status = nil
        Task {
            do {
                let result = try await api.fetchConfig()
                config = result
                if result.authRequired && !result.authenticated {
                    status = "✗ Connected, but the server rejected the token."
                } else {
                    let via = api.activeEndpoint.map { " via \($0.displayName)" } ?? ""
                    status = "✓ Connected to \(result.appTitle) v\(result.version ?? "?")\(via)"
                }
            } catch {
                status = "✗ \(error.localizedDescription)"
            }
            checking = false
        }
    }
}
