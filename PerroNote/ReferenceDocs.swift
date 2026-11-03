import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Your help desk procedures and guidelines, picked from Files, used as the standard every call is reviewed against.
/// Copies are kept on the phone and sent to Claude with each review.
enum ReferenceDocs {
    static let types: [UTType] = [.pdf, .plainText, .rtf, UTType(filenameExtension: "md") ?? .plainText,
                                  UTType(filenameExtension: "docx") ?? .data]

    static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallReviewDocs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var files: [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return list.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies a picked file in, replacing one with the same name.
    static func add(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let target = folder.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The text of a document, or nil for a PDF (sent as is) or a file that can't be read.
    static func text(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": return nil
        case "docx": return DocxText.read(url)
        case "rtf":
            guard let data = try? Data(contentsOf: url),
                  let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            else { return nil }
            return s.string
        default:
            return (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
    }

    /// One content block per document for the Claude request; the last is marked for caching, so reviewing
    /// many calls with the same documents costs much less after the first.
    static func contentBlocks() -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for url in files {
            let title = url.deletingPathExtension().lastPathComponent
            if url.pathExtension.lowercased() == "pdf" {
                guard let data = try? Data(contentsOf: url) else { continue }
                blocks.append(["type": "document", "title": title,
                               "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]])
            } else if let text = text(of: url)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                blocks.append(["type": "document", "title": title,
                               "source": ["type": "text", "media_type": "text/plain", "data": text]])
            }
        }
        if !blocks.isEmpty { blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"] }
        return blocks
    }
}

/// Reads the words out of a Word file: finds word/document.xml in the zip and strips the markup.
enum DocxText {
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let xml = entry("word/document.xml", in: data),
              let s = String(data: xml, encoding: .utf8) else { return nil }
        var t = s.replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "<w:tab/>", with: "\t")
            .replacingOccurrences(of: "<w:br/>", with: "\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    private static func u16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
    private static func u32(_ d: [UInt8], _ i: Int) -> Int { u16(d, i) | u16(d, i + 2) << 16 }

    /// One file from a zip, using its central directory. Stored and deflated entries are supported.
    static func entry(_ name: String, in data: Data) -> Data? {
        let d = [UInt8](data)
        guard d.count > 22 else { return nil }
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 65_557) {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(d, eocd + 10)
        var p = u32(d, eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x0201_4B50 else { return nil }
            let method = u16(d, p + 10)
            let compressed = u32(d, p + 20)
            let nameLen = u16(d, p + 28), extraLen = u16(d, p + 30), commentLen = u16(d, p + 32)
            let local = u32(d, p + 42)
            guard p + 46 + nameLen <= d.count else { return nil }
            let entryName = String(decoding: d[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            if entryName == name {
                guard local + 30 <= d.count, u32(d, local) == 0x0403_4B50 else { return nil }
                let start = local + 30 + u16(d, local + 26) + u16(d, local + 28)
                guard start + compressed <= d.count else { return nil }
                let body = Data(d[start..<(start + compressed)])
                if method == 0 { return body }
                if method == 8 { return try? (body as NSData).decompressed(using: .zlib) as Data }
                return nil
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return nil
    }
}

/// The reference documents list in Settings > Call review.
struct ReferenceDocsSection: View {
    @State private var files = ReferenceDocs.files
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(files, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(systemName: icon(url)).foregroundStyle(Color.accentColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(2)
                        Text(ReferenceDocs.size(url)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { ReferenceDocs.remove(files[i]) }
                files = ReferenceDocs.files
            }
            Button { picking = true } label: { Label("Add documents\u{2026}", systemImage: "doc.badge.plus") }
        } header: {
            Text("Reference documents")
        } footer: {
            Text("Procedures, scripts, policies or knowledge articles in PDF, Word, text or Markdown. Every call is checked against what they say, and the review lists each requirement that applied. They are sent to Claude with each review; swipe to remove one.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: ReferenceDocs.types, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do { try ReferenceDocs.add(url) } catch { self.error = "\(url.lastPathComponent) could not be added." }
                }
                files = ReferenceDocs.files
            case .failure(let e):
                error = e.localizedDescription
            }
        }
        .alert("Could not add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func icon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "docx": return "doc.text"
        default: return "doc.plaintext"
        }
    }
}
