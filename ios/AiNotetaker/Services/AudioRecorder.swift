import AVFoundation
import Foundation

/// Lossless (Apple Lossless, 24-bit) microphone recorder that keeps recording
/// while the phone is locked (UIBackgroundModes = audio).
///
/// Quality choices, in order of impact:
///  • The best available input is preferred automatically: a USB/Lightning audio
///    interface or wired microphone beats the built-in mics, which beat any
///    Bluetooth headset. Bluetooth headset mics use a narrowband phone-call
///    codec, so they are OFF unless you opt in (Settings → Microphone).
///  • On the built-in mics, "Voice" mode selects the bottom mic with a cardioid
///    pattern (rejects room noise); "Room" selects an omnidirectional pattern.
///  • The `.measurement` session mode turns off iOS's own processing (automatic
///    gain, EQ, noise suppression) so the file holds the raw signal. Noise
///    removal happens on the server, on a copy. The exception is "keep other
///    audio playing" mode: iOS lowers system output volume under `.measurement`,
///    which would make the music you're recording play quietly, so that mode
///    uses `.default` instead to keep playback at full level.
///  • The file is written at the input's native sample rate (48 kHz on iPhone
///    mics) with no resampling, 24-bit, Apple Lossless.
@MainActor
final class AudioRecorder: ObservableObject {
    enum State { case idle, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0   // 0...1 for the meter
    @Published private(set) var isClipping = false
    @Published private(set) var inputDescription: String = ""
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pausedByInterruption = false
    private var clippingUntil = Date.distantPast
    private(set) var currentFileURL: URL?

    init() {
        observeInterruptions()
        observeRouteChanges()
    }

    // MARK: - Preferences (Settings → Microphone)

    private var micMode: String { UserDefaults.standard.string(forKey: "micMode") ?? "voice" }
    private var allowBluetoothMic: Bool { UserDefaults.standard.bool(forKey: "allowBluetoothMic") }
    private var mixWithOtherAudio: Bool { UserDefaults.standard.bool(forKey: "mixWithOtherAudio") }

    // MARK: - Control

    func start() async {
        guard state == .idle else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            errorMessage = "Microphone access is off. Enable it in Settings → Privacy & Security → Microphone."
            return
        }
        var pendingURL: URL?
        do {
            let session = AVAudioSession.sharedInstance()
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
            if allowBluetoothMic { options.insert(.allowBluetooth) }
            // Let music/podcasts from other apps keep playing so the mic picks
            // them up (room-quality; iOS never exposes a clean internal copy).
            // Off by default so ordinary voice notes stay clean.
            if mixWithOtherAudio { options.insert(.mixWithOthers) }
            // `.measurement` gives the rawest possible capture, but iOS also
            // drops system OUTPUT volume in that mode — which would make the
            // music you're trying to record play (and so record) quietly. When
            // mixing, `.default` keeps playback at full level; the small amount
            // of input processing it re-enables is a good trade for audible music.
            let mode: AVAudioSession.Mode = mixWithOtherAudio ? .default : .measurement
            try session.setCategory(.playAndRecord, mode: mode, options: options)
            // Preferred hardware format belongs on the inactive session. Input
            // discovery and data-source / polar-pattern selection do not: Apple
            // only guarantees availableInputs after activation.
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredInputNumberOfChannels(1)
            try session.setActive(true, options: [])
            configureBestInput(session)

            // Record at the input's real rate so nothing is resampled.
            let sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000
            inputDescription = describeInput(session, sampleRate: sampleRate)

            let url = RecordingStore.newFileURL()
            pendingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 24,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.isMeteringEnabled = true
            newRecorder.prepareToRecord()
            guard newRecorder.record() else {
                throw NSError(domain: "AiNotetaker", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The recorder could not start."])
            }
            recorder = newRecorder
            currentFileURL = url
            pendingURL = nil
            elapsed = 0
            level = 0
            isClipping = false
            clippingUntil = .distantPast
            pausedByInterruption = false
            state = .recording
            startTimer()
        } catch {
            if let pendingURL = pendingURL {
                RecordingStore.delete(pendingURL)
            }
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            deactivateSession()
        }
    }

    func pause() {
        guard state == .recording, let recorder else { return }
        pausedByInterruption = false
        recorder.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true, options: [])
            configureBestInput(session)
            guard recorder.record() else {
                throw NSError(
                    domain: "AiNotetaker",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The recorder could not resume."]
                )
            }
            pausedByInterruption = false
            inputDescription = describeInput(session, sampleRate: session.sampleRate)
            state = .recording
        } catch {
            errorMessage = "Couldn't resume recording: \(error.localizedDescription)"
        }
    }

    private func pauseForInterruption() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        pausedByInterruption = true
        state = .paused
    }

    /// Stops and returns the file URL + duration of the finished recording.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let url = currentFileURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        stopTimer()
        self.recorder = nil
        currentFileURL = nil
        state = .idle
        elapsed = 0
        level = 0
        isClipping = false
        clippingUntil = .distantPast
        pausedByInterruption = false
        deactivateSession()
        return (url, duration)
    }

    // MARK: - Input selection

    /// Prefer USB / wired inputs over the built-in mics, and configure the
    /// built-in mic's data source and polar pattern for the chosen mode.
    private func configureBestInput(_ session: AVAudioSession) {
        guard let inputs = session.availableInputs, !inputs.isEmpty else { return }

        let ranked: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .builtInMic]
        var chosen: AVAudioSessionPortDescription?
        for type in ranked {
            if let port = inputs.first(where: { $0.portType == type }) {
                chosen = port
                break
            }
        }
        if chosen == nil && allowBluetoothMic {
            chosen = inputs.first(where: { $0.portType == .bluetoothHFP })
        }
        guard let port = chosen ?? inputs.first else { return }

        if port.portType == .builtInMic, micMode != "auto",
           let sources = port.dataSources, !sources.isEmpty {
            let wantedOrientations: [AVAudioSession.Orientation] =
                micMode == "room" ? [.back, .front, .bottom] : [.bottom, .front, .back]
            let wantedPattern: AVAudioSession.PolarPattern =
                micMode == "room" ? .omnidirectional : .cardioid
            var source: AVAudioSessionDataSourceDescription?
            for orientation in wantedOrientations {
                if let match = sources.first(where: { $0.orientation == orientation }) {
                    source = match
                    break
                }
            }
            if let source = source ?? sources.first {
                if let patterns = source.supportedPolarPatterns, patterns.contains(wantedPattern) {
                    try? source.setPreferredPolarPattern(wantedPattern)
                }
                try? port.setPreferredDataSource(source)
            }
        }
        try? session.setPreferredInput(port)
    }

    private func describeInput(_ session: AVAudioSession, sampleRate: Double) -> String {
        var parts: [String] = []
        if let input = session.currentRoute.inputs.first {
            var name = input.portType == .builtInMic ? "Built-in mic" : input.portName
            if let source = input.selectedDataSource {
                name += " · " + source.dataSourceName.lowercased()
                if let pattern = source.selectedPolarPattern {
                    name += " · " + pattern.rawValue.lowercased()
                }
            }
            parts.append(name)
        }
        parts.append(String(format: "%g kHz", sampleRate / 1000))
        parts.append("24-bit lossless")
        return parts.joined(separator: " · ")
    }

    // MARK: - Internals

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)   // -160 ... 0
        level = max(0, min(1, (decibels + 50) / 50))

        // Digital clipping permanently destroys detail. Hold the warning long
        // enough to be noticed even when only a short peak reaches 0 dBFS.
        let peak = recorder.peakPower(forChannel: 0)
        if state == .recording && peak >= -1 {
            clippingUntil = Date().addingTimeInterval(1.5)
        }
        isClipping = state == .recording && Date() < clippingUntil
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    if self.state == .recording { self.pauseForInterruption() }
                case .ended:
                    guard self.pausedByInterruption else { return }
                    if shouldResume {
                        self.resume()
                    } else {
                        self.pausedByInterruption = false
                        self.errorMessage = "Recording was paused by another audio app. Tap Resume to continue."
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    /// If a device is plugged in or removed mid-recording, re-assert the best input.
    private func observeRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                guard let self, self.state != .idle else { return }
                let session = AVAudioSession.sharedInstance()
                self.configureBestInput(session)
                self.inputDescription = self.describeInput(session, sampleRate: session.sampleRate)
            }
        }
    }
}
