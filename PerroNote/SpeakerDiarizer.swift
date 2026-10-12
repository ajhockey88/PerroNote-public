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

    private static func makeManager(speakers: Int?) -> OfflineDiarizerManager {
        var config = OfflineDiarizerConfig()
        switch UserDefaults.standard.integer(forKey: sensitivityKey) {
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
            return DiarizationOutput(segments: segments, embeddings: embeddings)
        } catch {
            throw DiarizerError.failed(error.localizedDescription)
        }
    }
}
