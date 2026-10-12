import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case permissionDenied
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is off. Turn it on in Settings > PerroNote."
        case .couldNotStart:
            return "The recording could not be started."
        }
    }
}

/// Records a meeting to an AAC file in Documents/Audio. Keeps recording with the screen
/// locked or the app in the background (UIBackgroundModes: audio).
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0...1, for the level meter.
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileName: String?
    private var startedAt: Date?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start() async throws {
        let granted = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        guard granted else { throw RecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let name = "\(UUID().uuidString).m4a"
        let url = MeetingStore.audioURL(for: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw RecorderError.couldNotStart }
        recorder = rec
        fileName = name
        startedAt = Date()
        elapsed = 0
        isRecording = true
        isPaused = false
        startTimer()
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
        level = 0
    }

    func resume() {
        guard isRecording, isPaused else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        recorder?.record()
        isPaused = false
    }

    /// Stops and returns the file name, final duration and the time recording began.
    func stop() -> (fileName: String, duration: TimeInterval, startedAt: Date)? {
        guard let rec = recorder, let name = fileName else { return nil }
        let duration = rec.currentTime
        let started = startedAt ?? Date().addingTimeInterval(-duration)
        rec.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        fileName = nil
        startedAt = nil
        isRecording = false
        isPaused = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (name, duration, started)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder else { return }
            self.elapsed = rec.currentTime
            if rec.isRecording {
                rec.updateMeters()
                // -50 dB (quiet) ... 0 dB (loud) mapped to 0...1
                self.level = max(0, min(1, (rec.averagePower(forChannel: 0) + 50) / 50))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            switch type {
            case .began:
                self.pause()
            case .ended:
                let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    self.resume()
                }
            @unknown default:
                break
            }
        }
    }
}
