import SwiftUI

/// Finds words in every meeting's transcript by plain text matching on the phone. Nothing is sent anywhere and no AI is used.
enum TranscriptSearch {
    struct Hit: Identifiable {
        let id = UUID()
        let speaker: String?
        let at: Double?
        let text: String
    }

    struct Result: Identifiable {
        let meeting: Meeting
        let hits: [Hit]
        var id: UUID { meeting.id }
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    private static func matches(_ text: String, _ terms: [String]) -> Bool {
        terms.allSatisfy { text.range(of: $0, options: options) != nil }
    }

    /// Every line that has all the words in it, grouped by meeting, newest meeting first.
    static func search(_ query: String, in meetings: [Meeting]) -> [Result] {
        let words = terms(query)
        guard !words.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        var out: [Result] = []
        for meeting in meetings.sorted(by: { $0.date > $1.date }) {
            var hits: [Hit] = []
            if let lines = meeting.lines, !lines.isEmpty {
                for line in lines where matches(line.text, words) {
                    let name = line.speaker.flatMap { id in meeting.voices?.first { $0.id == id }?.label }
                    hits.append(Hit(speaker: name, at: line.start, text: line.text))
                }
            } else if let transcript = meeting.transcript, !transcript.isEmpty {
                // No separated voices: look sentence by sentence.
                let sentences = transcript.components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
                for s in sentences where matches(s, words) {
                    hits.append(Hit(speaker: nil, at: nil, text: s.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            if !hits.isEmpty { out.append(Result(meeting: meeting, hits: hits)) }
        }
        return out
    }

    /// A short piece of the line around the first match, with every searched word highlighted.
    static func snippet(_ text: String, _ words: [String]) -> AttributedString {
        var shown = text
        if text.count > 160, let first = words.compactMap({ text.range(of: $0, options: options) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let start = text.index(first.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(first.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
            shown = (start > text.startIndex ? "\u{2026}" : "") + String(text[start..<end]) + (end < text.endIndex ? "\u{2026}" : "")
        }
        var attributed = AttributedString(shown)
        for w in words {
            var from = attributed.startIndex
            while from < attributed.endIndex,
                  let r = attributed[from...].range(of: w, options: options) {
                attributed[r].backgroundColor = .yellow.opacity(0.45)
                attributed[r].font = .subheadline.weight(.semibold)
                from = r.upperBound
            }
        }
        return attributed
    }
}

/// Search every transcript. Tap a result to open that meeting.
struct TranscriptSearchView: View {
    var onOpen: (UUID) -> Void
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [TranscriptSearch.Result] { TranscriptSearch.search(query, in: store.meetings) }

    var body: some View {
        NavigationStack {
            let found = results
            let words = TranscriptSearch.terms(query)
            List {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text("Type a word or phrase to find it in every meeting\u{2019}s transcript. Matching is by the words you type, on this phone.")
                        .foregroundStyle(.secondary)
                } else if found.isEmpty {
                    Text("No transcript has all of those words in one line.").foregroundStyle(.secondary)
                }
                ForEach(found) { result in
                    Section {
                        ForEach(result.hits.prefix(5)) { hit in
                            Button { onOpen(result.meeting.id); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    if hit.speaker != nil || hit.at != nil {
                                        Text([hit.speaker, hit.at.map { formatDuration($0) }].compactMap { $0 }.joined(separator: " \u{00B7} "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(TranscriptSearch.snippet(hit.text, words)).font(.subheadline).foregroundStyle(.primary)
                                }
                            }
                        }
                        if result.hits.count > 5 {
                            Button { onOpen(result.meeting.id); dismiss() } label: {
                                Text("+ \(result.hits.count - 5) more in this meeting").font(.footnote)
                            }
                        }
                    } header: {
                        Text("\(result.meeting.title) \u{00B7} \(result.meeting.date.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transcripts")
            .navigationTitle("Search transcripts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
