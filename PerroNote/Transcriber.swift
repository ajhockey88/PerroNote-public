import AVFoundation
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case notAuthorized
    case unavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition is off. Turn it on in Settings > PerroNote."
        case .unavailable:
            return "Speech recognition isn't available for this language right now."
        case .exportFailed:
            return "The recording could not be prepared for transcription."
        }
    }
}

struct TimedWord: Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct TimeSpan: Sendable {
    var start: Double
    var end: Double
}

struct TranscriptionResult: Sendable {
    var text: String
    var words: [TimedWord]
    /// Stretches where the audio has speech but no words were recognized.
    var gaps: [TimeSpan] = []
}

/// Converts a recording to text with Apple's Speech framework. On-device recognition is used
/// when the iPhone supports it (no length limit, nothing leaves the phone). Otherwise the audio
/// is cut into short pieces, because Apple's server recognition stops after about a minute.
/// Each word keeps its time in the recording so it can be matched to a voice later.
enum Transcriber {
    /// 0 = the Parakeet model (best accuracy, one-time download), 1 = Apple's built-in recognizer.
    static let engineKey = "transcription-engine"

    static func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        if UserDefaults.standard.integer(forKey: engineKey) == 0,
           var better = try? await ParakeetTranscriber.transcribe(fileURL: fileURL),
           better.words.count >= 5 {
            let energy = (try? loudness(fileURL)) ?? []
            better.gaps = findGaps(energy: energy, words: better.words)
            return better
        }
        return try await transcribeWithApple(fileURL: fileURL)
    }

    private static func transcribeWithApple(fileURL: URL) async throws -> TranscriptionResult {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriberError.notAuthorized }

        guard let recognizer = SFSpeechRecognizer(locale: .current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw TranscriberError.unavailable }

        let onDevice = recognizer.supportsOnDeviceRecognition
        let seconds = (try? await AVURLAsset(url: fileURL).load(.duration).seconds) ?? 0

        // Measure how loud the recording is, tenth of a second by tenth of a second. That shows
        // where speech is, and where quiet pauses are, so the audio can be cut between sentences.
        let energy = (try? loudness(fileURL)) ?? []
        var result = TranscriptionResult(text: "", words: [])

        // Long recordings are read in pieces of about 40 seconds. Reading a long file in one go can
        // silently skip a stretch (the first 30 seconds went missing in one test).
        var pieces: [(url: URL, start: Double)] = []
        if energy.count > 450 {
            pieces = (try? writePieces(fileURL, cuts: planCuts(energy))) ?? []
        }
        if pieces.count <= 1 { pieces.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        if pieces.count > 1 {
            defer { pieces.forEach { try? FileManager.default.removeItem(at: $0.url) } }
            var parts: [String] = []
            var words: [TimedWord] = []
            for piece in pieces {
                let r = (try? await recognize(piece.url, with: recognizer, onDevice: onDevice, offset: piece.start))
                    ?? TranscriptionResult(text: "", words: [])
                if !r.text.isEmpty { parts.append(r.text) }
                words += r.words
            }
            result = TranscriptionResult(text: parts.joined(separator: " "), words: words)
        }

        // Short recordings, or pieces that found little: try the whole file, then fixed-size pieces.
        if !looksComplete(result, seconds: seconds) {
            if onDevice, let whole = try? await recognize(fileURL, with: recognizer, onDevice: true, offset: 0),
               whole.words.count > result.words.count {
                result = whole
            }
            if !looksComplete(result, seconds: seconds) || !onDevice {
                let chunked = try await recognizeInPieces(fileURL, with: recognizer, onDevice: onDevice)
                if chunked.words.count > result.words.count || result.text.isEmpty { result = chunked }
            }
        }
        result.gaps = findGaps(energy: energy, words: result.words)
        return result
    }

    /// A conversation has far more than 20 words a minute. Less than that means recognition gave up.
    private static func looksComplete(_ r: TranscriptionResult, seconds: Double) -> Bool {
        if seconds < 15 { return true }
        return r.words.count >= max(5, Int(seconds / 60 * 20))
    }

    private static func recognizeInPieces(_ fileURL: URL, with recognizer: SFSpeechRecognizer,
                                          onDevice: Bool) async throws -> TranscriptionResult {
        // 16 kHz mono WAV is the format speech recognition handles most reliably. Fall back to
        // exporting AAC pieces if the conversion fails.
        let pieces: [(url: URL, start: Double)]
        if let converted = try? convertedPieces(fileURL, seconds: 50), !converted.isEmpty {
            pieces = converted
        } else {
            pieces = try await split(fileURL, seconds: 50)
        }
        defer { pieces.forEach { try? FileManager.default.removeItem(at: $0.url) } }
        var parts: [String] = []
        var words: [TimedWord] = []
        for piece in pieces {
            let result = try await recognize(piece.url, with: recognizer, onDevice: onDevice, offset: piece.start)
            if !result.text.isEmpty { parts.append(result.text) }
            words += result.words
        }
        return TranscriptionResult(text: parts.joined(separator: " "), words: words)
    }

    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer, onDevice: Bool,
                                  offset: Double) async throws -> TranscriptionResult {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TranscriptionResult, Error>) in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments
                        .filter { !$0.substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .map {
                            TimedWord(text: $0.substring, start: $0.timestamp + offset,
                                      end: $0.timestamp + $0.duration + offset)
                        }
                    cont.resume(returning: TranscriptionResult(
                        text: result.bestTranscription.formattedString, words: words))
                } else if let error {
                    finished = true
                    let ns = error as NSError
                    // 1110 / 203: no speech detected in this audio. Treat it as empty.
                    if ns.code == 1110 || ns.code == 203 || ns.code == 1107 {
                        cont.resume(returning: TranscriptionResult(text: "", words: []))
                    } else {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Cuts the recording into pieces of `seconds` and converts each to 16 kHz mono 16-bit WAV.
    private static func convertedPieces(_ url: URL, seconds: Double) throws -> [(url: URL, start: Double)] {
        let input = try AVAudioFile(forReading: url)
        let inFormat = input.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscriberError.exportFailed
        }
        let rate = inFormat.sampleRate
        let piece = AVAudioFramePosition(seconds * rate)
        let total = input.length
        var made: [(url: URL, start: Double)] = []
        var start: AVAudioFramePosition = 0
        while start < total {
            input.framePosition = start
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            let file = try AVAudioFile(forWriting: out, settings: outFormat.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            var remaining = min(piece, total - start)
            while remaining > 0 {
                let want = AVAudioFrameCount(min(AVAudioFramePosition(8192), remaining))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: want) else {
                    throw TranscriberError.exportFailed
                }
                try input.read(into: buffer, frameCount: want)
                if buffer.frameLength == 0 { break }
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / rate) + 1024
                guard let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                    throw TranscriberError.exportFailed
                }
                var supplied = false
                var failure: NSError?
                converter.convert(to: converted, error: &failure) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                if failure != nil { throw TranscriberError.exportFailed }
                try file.write(from: converted)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
            made.append((out, Double(start) / rate))
            start += piece
        }
        return made
    }

    /// Decodes the recording to 16 kHz mono 16-bit samples and hands them over a block at a time.
    private static func decode(_ url: URL, _ handle: ([Int16]) throws -> Void) throws {
        let input = try AVAudioFile(forReading: url)
        let inFormat = input.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscriberError.exportFailed
        }
        let frames: AVAudioFrameCount = 8192
        while input.framePosition < input.length {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
                throw TranscriberError.exportFailed
            }
            try input.read(into: inBuf, frameCount: frames)
            if inBuf.frameLength == 0 { break }
            let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / inFormat.sampleRate) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                throw TranscriberError.exportFailed
            }
            var supplied = false
            var failure: NSError?
            converter.convert(to: outBuf, error: &failure) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return inBuf
            }
            if failure != nil { throw TranscriberError.exportFailed }
            if outBuf.frameLength > 0, let channel = outBuf.int16ChannelData {
                try handle(Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuf.frameLength))))
            }
        }
    }

    /// Loudness (RMS, 0 to 1) of every tenth of a second.
    private static func loudness(_ url: URL) throws -> [Float] {
        var energy: [Float] = []
        var sum: Float = 0
        var count = 0
        try decode(url) { block in
            for sample in block {
                let v = Float(sample) / 32768
                sum += v * v
                count += 1
                if count == 1600 {
                    energy.append((sum / 1600).squareRoot())
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { energy.append((sum / Float(count)).squareRoot()) }
        return energy
    }

    /// Picks places to cut: about every 40 seconds, at the quietest tenth of a second within 4 seconds
    /// either side. Returns positions in tenths of a second, starting at 0 and ending at the length.
    private static func planCuts(_ energy: [Float]) -> [Int] {
        let n = energy.count
        var cuts = [0]
        var position = 0
        while n - position > 450 {
            let nominal = position + 400
            let low = max(position + 100, nominal - 40)
            let high = min(n - 50, nominal + 40)
            var best = nominal
            var quietest = Float.greatestFiniteMagnitude
            if low < high {
                for i in low...high where energy[i] < quietest {
                    quietest = energy[i]
                    best = i
                }
            }
            cuts.append(best)
            position = best
        }
        cuts.append(n)
        return cuts
    }

    /// Writes each stretch between the cuts to its own 16 kHz mono WAV file.
    private static func writePieces(_ url: URL, cuts: [Int]) throws -> [(url: URL, start: Double)] {
        guard cuts.count > 2,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                            channels: 1, interleaved: true) else { return [] }
        var made: [(url: URL, start: Double)] = []
        var file: AVAudioFile?
        var index = 0
        var cursor = 0
        try decode(url) { block in
            var offset = 0
            while offset < block.count && index < cuts.count - 1 {
                if file == nil {
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
                    file = try AVAudioFile(forWriting: out, settings: outFormat.settings,
                                           commonFormat: .pcmFormatInt16, interleaved: true)
                    made.append((out, Double(cuts[index]) / 10))
                }
                let boundary = cuts[index + 1] * 1600
                let take = min(block.count - offset, max(boundary - cursor, 1))
                if let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(take)),
                   let channel = buffer.int16ChannelData {
                    buffer.frameLength = AVAudioFrameCount(take)
                    block.withUnsafeBufferPointer { source in
                        channel[0].update(from: source.baseAddress! + offset, count: take)
                    }
                    try file?.write(from: buffer)
                }
                cursor += take
                offset += take
                if cursor >= boundary {
                    file = nil
                    index += 1
                }
            }
        }
        return made
    }

    /// Finds stretches of 8 seconds or more where something is being said but no word was recognized.
    private static func findGaps(energy: [Float], words: [TimedWord]) -> [TimeSpan] {
        let bins = energy.count / 10
        guard bins >= 8 else { return [] }
        var level: [Float] = []
        for b in 0..<bins {
            let slice = energy[(b * 10)..<(b * 10 + 10)]
            level.append(slice.reduce(0, +) / Float(slice.count))
        }
        let active = level.filter { $0 > 0.008 }.sorted()
        guard !active.isEmpty else { return [] }
        let threshold = max(0.008, 0.4 * active[active.count / 2])

        func covered(_ b: Int) -> Bool {
            let t = Double(b) + 0.5
            return words.contains { $0.start - 2 <= t && t <= $0.end + 2 }
        }
        var gaps: [TimeSpan] = []
        var runStart: Int?
        var lastMissing = 0
        for b in 0..<bins {
            if level[b] > threshold && !covered(b) {
                if runStart == nil { runStart = b }
                lastMissing = b
            } else if let start = runStart, b - lastMissing > 2 {
                if lastMissing + 1 - start >= 8 { gaps.append(TimeSpan(start: Double(start), end: Double(lastMissing + 1))) }
                runStart = nil
            }
        }
        if let start = runStart, lastMissing + 1 - start >= 8 {
            gaps.append(TimeSpan(start: Double(start), end: Double(lastMissing + 1)))
        }
        return gaps
    }

    private static func split(_ url: URL, seconds: Double) async throws -> [(url: URL, start: Double)] {
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0 else { throw TranscriberError.exportFailed }

        var urls: [(url: URL, start: Double)] = []
        var start = 0.0
        while start < total {
            let length = min(seconds, total - start)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw TranscriberError.exportFailed
            }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            export.outputURL = out
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600))
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }
            guard export.status == .completed else { throw TranscriberError.exportFailed }
            urls.append((out, start))
            start += length
        }
        return urls
    }
}
