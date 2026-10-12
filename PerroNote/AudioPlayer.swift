import AVFoundation
import Foundation

final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.currentTime = p.currentTime
            self.duration = p.duration
        }
    }

    /// Moves to a point in the recording without starting playback.
    func seek(to seconds: Double, url: URL) {
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        player?.currentTime = max(0, seconds)
        currentTime = max(0, seconds)
        duration = player?.duration ?? duration
    }

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        isPlaying = player?.play() ?? false
        if isPlaying { startTimer() }
    }

    /// Starts playing from a moment in the recording.
    func play(url: URL, from seconds: Double) {
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        guard let player else { return }
        player.currentTime = max(0, min(seconds, player.duration))
        isPlaying = player.play()
        if isPlaying { startTimer() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Continues from where it was paused.
    func resume() {
        guard let player else { return }
        isPlaying = player.play()
        if isPlaying { startTimer() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.timer?.invalidate()
            self.timer = nil
        }
    }
}
