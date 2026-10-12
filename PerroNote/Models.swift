import Foundation

struct ActionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var task: String
    var owner: String?
    var due: String?
    var done = false
}

/// One core discussion point with the details that were said about it.
struct DiscussionTopic: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var points: [String]
    /// Sub-bullets for each point, same order as `points`. Missing or short means no sub-bullets.
    var subs: [[String]]? = nil

    func subPoints(at index: Int) -> [String] {
        guard let subs, subs.indices.contains(index) else { return [] }
        return subs[index]
    }

    /// Makes sure `subs` has one entry per point so it can be edited by position.
    mutating func padSubs() {
        var s = subs ?? []
        while s.count < points.count { s.append([]) }
        subs = s
    }

    mutating func removePoint(at index: Int) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
        if subs?.indices.contains(index) == true { subs?.remove(at: index) }
    }
}

/// What one request to Claude used, as reported by Anthropic with the response.
struct TokenUsage: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case draft, redraft, question }
    var id = UUID()
    var kind: Kind
    var model: String
    var date = Date()
    /// Input tokens not read from or written to the cache.
    var input: Int
    var output: Int
    var cacheRead = 0
    var cacheWrite = 0

    /// Every input token, cached or not.
    var allInput: Int { input + cacheRead + cacheWrite }
    var total: Int { allInput + output }

    /// Reads the `usage` object of an API response.
    init(kind: Kind, model: String, json: [String: Any]?) {
        self.kind = kind
        self.model = model
        func n(_ k: String) -> Int { (json?[k] as? Int) ?? Int((json?[k] as? Double) ?? 0) }
        input = n("input_tokens")
        output = n("output_tokens")
        cacheRead = n("cache_read_input_tokens")
        cacheWrite = n("cache_creation_input_tokens")
    }

    /// Dollars at the model's list price, or nil for a model whose price is not known here.
    var estimatedCost: Double? {
        let price: (in: Double, out: Double)
        switch model {
        case "claude-sonnet-5-5", "claude-sonnet-5": price = (2, 10)
        case "claude-haiku-5-5": price = (0.10, 0.50)
        case "claude-opus-5-5": price = (4, 20)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6": price = (5, 25)
        case "claude-sonnet-4-6": price = (3, 15)
        case "claude-haiku-4-5": price = (1, 5)
        case "claude-fable-5-1", "claude-fable-5": price = (10, 50)
        default: return nil
        }
        let m = 1_000_000.0
        return (Double(input) * price.in + Double(cacheRead) * price.in * 0.1
                + Double(cacheWrite) * price.in * 1.25 + Double(output) * price.out) / m
    }
}

struct MeetingNotes: Codable, Hashable {
    var summary: String
    var attendees: [String]
    var discussion: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var nextSteps: [String]
    /// Discussion grouped by topic. Older meetings only have `discussion`.
    var topics: [DiscussionTopic]? = nil
    /// Where in the audio each note came from, in seconds. Used only inside the app, never exported.
    /// Keys: "p:<topic id>:<point number>", "d:<decision number>", "a:<action item id>".
    var times: [String: Double]? = nil

    /// Call after removing item number `removed` under a key prefix so later items keep the right time.
    mutating func dropTime(prefix: String, removed: Int) {
        guard let old = times else { return }
        var new: [String: Double] = [:]
        for (key, value) in old {
            guard key.hasPrefix(prefix), let n = Int(key.dropFirst(prefix.count)) else { new[key] = value; continue }
            if n < removed { new[key] = value } else if n > removed { new[prefix + String(n - 1)] = value }
        }
        times = new
    }
}

enum MeetingStatus: String, Codable {
    case recorded, transcribing, diarizing, generating, done, failed
}

/// One stretch of the transcript spoken by one voice.
struct TranscriptLine: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The detected voice's id inside this meeting ("1", "2", ...). Nil when voices were not separated.
    var speaker: String?
    var start: Double
    var end: Double
    var text: String
}

/// A voice found in one meeting, before or after you say who it is.
struct DetectedVoice: Codable, Identifiable, Hashable {
    var id: String
    var personID: UUID?
    var name: String?
    var talkTime: Double
    /// A clean few seconds of this voice to play back.
    var snippetStart: Double
    var snippetEnd: Double
    /// The voice print, kept on the phone.
    var embedding: [Float]
    var suggestedPersonID: UUID?
    var suggestedName: String?

    var label: String { name ?? "Speaker \(id)" }
}

struct Meeting: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var duration: TimeInterval
    var audioFile: String
    var transcript: String?
    var notes: MeetingNotes?
    var status: MeetingStatus = .recorded
    var errorMessage: String?
    var titleEdited = false
    var lines: [TranscriptLine]?
    /// The transcript in short timed pieces, kept so notes can point back to the audio.
    var timeline: [TranscriptLine]?
    var voices: [DetectedVoice]?
    /// Who was there, as typed or picked by you.
    var attendeeNames: [String]?
    var speakersConfirmed: Bool?
    /// Why voices could not be told apart, when that failed.
    var voiceNote: String?
    /// True once you have typed changes into the notes, so a redraft would replace them.
    var notesEdited: Bool?
    /// Claude usage for this meeting, one entry per request. Older meetings have none.
    var usage: [TokenUsage]?

    var isBusy: Bool { status == .transcribing || status == .diarizing || status == .generating }

    var hasVoices: Bool { (voices?.count ?? 0) > 1 }
    var voicesNeedIdentifying: Bool { hasVoices && !(speakersConfirmed ?? false) }

    func label(for speaker: String?) -> String {
        guard let speaker else { return "" }
        return voices?.first { $0.id == speaker }?.label ?? "Speaker \(speaker)"
    }

    /// The transcript for the AI with the second each piece starts at, like "[125] Priya: ...".
    var timedTranscript: String {
        let source = hasVoices ? lines : timeline
        guard let source, !source.isEmpty else { return labeledTranscript }
        return source.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { line in
            let who = (hasVoices && line.speaker != nil) ? "\(label(for: line.speaker)): " : ""
            return "[\(Int(line.start))] \(who)\(line.text)"
        }.joined(separator: "\n")
    }

    /// The transcript with a speaker name in front of each turn, for the AI and for search.
    var labeledTranscript: String {
        guard let lines, !lines.isEmpty, hasVoices else { return transcript ?? "" }
        return lines.map { $0.speaker == nil ? $0.text : "\(label(for: $0.speaker)): \($0.text)" }
            .joined(separator: "\n")
    }
}

extension MeetingNotes {
    func markdown(title: String, date: Date) -> String {
        var out = "# \(title)\n\n_\(date.formatted(date: .long, time: .shortened))_\n\n"
        out += "## Summary\n\(summary)\n\n"
        func list(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out += "## \(heading)\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        list("Attendees", attendees)
        if let topics, !topics.isEmpty {
            out += "## Discussion\n"
            for t in topics {
                out += "### \(t.title)\n"
                for (i, p) in t.points.enumerated() {
                    out += "- \(p)\n"
                    for s in t.subPoints(at: i) { out += "  - \(s)\n" }
                }
                out += "\n"
            }
        } else { list("Discussion", discussion) }
        list("Decisions", decisions)
        if !actionItems.isEmpty {
            out += "## Action Items\n"
            for item in actionItems {
                var line = "- [\(item.done ? "x" : " ")] \(item.task)"
                if let owner = item.owner, !owner.isEmpty { line += " (@\(owner))" }
                if let due = item.due, !due.isEmpty { line += " - due \(due)" }
                out += line + "\n"
            }
            out += "\n"
        }
        list("Open Questions", openQuestions)
        list("Next Steps", nextSteps)
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

extension Meeting {
    /// Everything searchable about a meeting, lower-level text joined for a simple contains match.
    var searchableText: String {
        var parts = [title, labeledTranscript] + (attendeeNames ?? [])
        if let n = notes {
            parts += [n.summary]
            parts += n.attendees
            parts += n.discussion
            for t in n.topics ?? [] {
                parts.append(t.title)
                parts += t.points
                for s in t.subs ?? [] { parts += s }
            }
            parts += n.decisions
            parts += n.openQuestions
            parts += n.nextSteps
            for item in n.actionItems { parts += [item.task, item.owner ?? "", item.due ?? ""] }
        }
        return parts.joined(separator: "\n")
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let hay = searchableText
        return q.split(separator: " ").allSatisfy { hay.localizedCaseInsensitiveContains($0) }
    }
}

enum DateFilter: Equatable {
    case all, today, yesterday, thisWeek, lastWeek, thisMonth
    case day(Date)
    case week(Date)

    var title: String {
        switch self {
        case .all: return "All dates"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .thisMonth: return "This month"
        case .day(let d): return d.formatted(.dateTime.month(.abbreviated).day().year())
        case .week(let d):
            let start = Calendar.current.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            return "Week of " + start.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    func contains(_ date: Date) -> Bool {
        let cal = Calendar.current
        switch self {
        case .all: return true
        case .today: return cal.isDateInToday(date)
        case .yesterday: return cal.isDateInYesterday(date)
        case .thisWeek: return cal.isDate(date, equalTo: Date(), toGranularity: .weekOfYear)
        case .lastWeek:
            guard let last = cal.date(byAdding: .weekOfYear, value: -1, to: Date()) else { return false }
            return cal.isDate(date, equalTo: last, toGranularity: .weekOfYear)
        case .thisMonth: return cal.isDate(date, equalTo: Date(), toGranularity: .month)
        case .day(let d): return cal.isDate(date, inSameDayAs: d)
        case .week(let d): return cal.isDate(date, equalTo: d, toGranularity: .weekOfYear)
        }
    }
}

extension Date {
    /// The nearest quarter hour (:00, :15, :30, :45). Every time zone's offset is a whole number
    /// of quarter hours, so rounding the absolute time lands on the same marks on the clock.
    func roundedToQuarterHour() -> Date {
        let step: TimeInterval = 15 * 60
        return Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / step).rounded() * step)
    }
}
