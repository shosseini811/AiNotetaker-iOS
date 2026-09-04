import AVFoundation
import Foundation

/// Simple player for local files (ALAC .m4a originals, FLAC cleaned copies).
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            loadedURL = url
        } catch {
            player = nil
            loadedURL = nil
        }
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        stopTimer()
        progress = 0
        currentTime = 0
        duration = 0
        loadedURL = nil
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let target = max(0, min(player.duration, fraction * player.duration))
        player.currentTime = target
        currentTime = target
        progress = fraction
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
        if !player.isPlaying {
            isPlaying = false
            stopTimer()
            if player.currentTime >= player.duration - 0.05 || player.currentTime == 0 {
                progress = 0
                currentTime = 0
            }
        }
    }
}
