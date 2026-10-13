import FluidAudio
import Foundation

struct DiarizedSegment: Sendable {
    var speaker: String
    var start: Double
    var end: Double
    var quality: Float
}

struct DiarizationOutput: Sendable {
    var segments: [DiarizedSegment]
    /// One voice print per voice, keyed by the same id the segments use.
    var embeddings: [String: [Float]]
}

enum DiarizerError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let why): return why
        }
    }
}

/// Finds who spoke when, on the phone, with FluidAudio's open-source models (pyannote and WeSpeaker).
/// The models download once the first time this runs; the audio itself is never uploaded.
enum SpeakerDiarizer {
    /// 0 = fewer voices, 1 = balanced (the library's default), 2 = more voices, 3 = even more.
    static let sensitivityKey = "voice-sensitivity"

    /// The setting value for Automatic, also used when nothing has been chosen yet.
    static let autoSetting = 4

    private static var setting: Int {
        UserDefaults.standard.object(forKey: sensitivityKey) == nil ? autoSetting : UserDefaults.standard.integer(forKey: sensitivityKey)
    }

    private static func makeManager(speakers: Int?) -> OfflineDiarizerManager {
        var config = OfflineDiarizerConfig()
        switch setting {
        case autoSetting: config.clustering.threshold = 0.45  // find every voice first; small fragments are folded back afterwards
        case 0: config.clustering.threshold = 0.75
        case 2: config.clustering.threshold = 0.45
        case 3: config.clustering.threshold = 0.35
        default: break
        }
        // When you say how many people were there, the voices are grouped into exactly that many.
        if let speakers, speakers >= 2 { config.clustering.numSpeakers = speakers }
        return OfflineDiarizerManager(config: config)
    }

    static func run(fileURL: URL, speakers: Int? = nil) async throws -> DiarizationOutput {
        do {
            let manager = makeManager(speakers: speakers)
            try await manager.prepareModels()
            let result = try await manager.process(fileURL)
            let segments = result.segments.map {
                DiarizedSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds),
                                end: Double($0.endTimeSeconds), quality: $0.qualityScore)
            }

            var embeddings: [String: [Float]] = result.speakerDatabase ?? [:]
            if embeddings.isEmpty {
                var sums: [String: [Float]] = [:]
                for seg in result.segments {
                    if var current = sums[seg.speakerId], current.count == seg.embedding.count {
                        for i in 0..<current.count { current[i] += seg.embedding[i] }
                        sums[seg.speakerId] = current
                    } else {
                        sums[seg.speakerId] = seg.embedding
                    }
                }
                embeddings = sums
            }
            if speakers == nil, setting == autoSetting {
                return fold(DiarizationOutput(segments: segments, embeddings: embeddings))
            }
            return DiarizationOutput(segments: segments, embeddings: embeddings)
        } catch {
            throw DiarizerError.failed(error.localizedDescription)
        }
    }

    /// Folds tiny voices back into the nearest bigger one. A real quiet person talks for a while;
    /// a fragment of a few seconds is almost always someone already heard.
    static func fold(_ output: DiarizationOutput) -> DiarizationOutput {
        var segments = output.segments
        var embeddings = output.embeddings
        var seconds: [String: Double] = [:], counts: [String: Int] = [:]
        for s in segments { seconds[s.speaker, default: 0] += s.end - s.start; counts[s.speaker, default: 0] += 1 }
        guard seconds.count > 2 else { return output }
        let total = seconds.values.reduce(0, +)
        let keepFloor = max(5.0, total * 0.03)

        func cosine(_ a: String, _ b: String) -> Float {
            guard let x = embeddings[a], let y = embeddings[b] else { return 0 }
            return VoiceMath.cosine(x, y)
        }

        // Smallest first, so a fragment lands on something that is itself staying.
        for id in seconds.keys.sorted(by: { (seconds[$0] ?? 0) < (seconds[$1] ?? 0) }) {
            let secs = seconds[id] ?? 0, n = counts[id] ?? 0
            guard secs < keepFloor || n < 2, seconds.count > 2 else { continue }
            let others = seconds.keys.filter { $0 != id && (seconds[$0] ?? 0) >= keepFloor }
            guard let nearest = others.max(by: { cosine(id, $0) < cosine(id, $1) }) else { continue }
            let tiny = secs < 3 || n < 2
            guard tiny || cosine(id, nearest) >= 0.6 else { continue }
            for i in segments.indices where segments[i].speaker == id { segments[i].speaker = nearest }
            seconds[nearest, default: 0] += secs
            counts[nearest, default: 0] += n
            seconds[id] = nil; counts[id] = nil; embeddings[id] = nil
        }
        return DiarizationOutput(segments: segments, embeddings: embeddings)
    }
}
