import AVFoundation
import Foundation

/// Brings in a recording made somewhere else (Voice Memos, a Zoom or Teams file, a video) as a new meeting.
enum AudioImport {
    struct Imported {
        let fileName: String
        let duration: TimeInterval
        let date: Date
        let title: String
    }

    enum ImportError: LocalizedError {
        case noAudio
        case failed(String?)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "That file has no sound in it."
            case .failed(let why): return "The recording could not be imported." + (why.map { " \($0)" } ?? "")
            }
        }
    }

    /// Copies the picked file in and converts its sound to the same kind of file the recorder makes.
    static func bringIn(_ source: URL) async throws -> Imported {
        let scoped = source.startAccessingSecurityScopedResource()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        let fileDate = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        do {
            try FileManager.default.copyItem(at: source, to: temp)
        } catch {
            if scoped { source.stopAccessingSecurityScopedResource() }
            throw ImportError.failed(error.localizedDescription)
        }
        if scoped { source.stopAccessingSecurityScopedResource() }
        defer { try? FileManager.default.removeItem(at: temp) }

        let asset = AVURLAsset(url: temp)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw ImportError.noAudio
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        // When the file says when it was recorded, the meeting goes on that day.
        var recorded: Date?
        if let item = try? await asset.load(.creationDate) {
            recorded = try? await item.load(.dateValue)
        }

        let name = "\(UUID().uuidString).m4a"
        let out = MeetingStore.audioURL(for: name)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.failed(nil)
        }
        export.outputURL = out
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw ImportError.failed(export.error?.localizedDescription)
        }

        let title = source.deletingPathExtension().lastPathComponent
        return Imported(fileName: name, duration: duration.isFinite ? duration : 0,
                        date: recorded ?? fileDate ?? Date(), title: title)
    }
}
