import FluidAudio
import Foundation

/// Speech to text with NVIDIA's Parakeet model, run through FluidAudio on the phone. It copes much better
/// than Apple's built-in recognizer with room recordings and several people talking. The model (roughly
/// half a gigabyte) downloads once the first time it is used; the audio itself never leaves the phone.
enum ParakeetTranscriber {
    static func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(fileURL, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return TranscriptionResult(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), words: words)
    }
}
