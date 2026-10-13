import Foundation

enum NotesError: LocalizedError {
    case missingKey
    case emptyTranscript
    case api(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add your Anthropic API key in Settings to draft notes."
        case .emptyTranscript:
            return "No speech was found in the recording."
        case .api(let message):
            return message
        case .badResponse:
            return "The AI response could not be read. Try again."
        }
    }
}

struct GeneratedNotes {
    var title: String
    var notes: MeetingNotes
    var usage: [String: Any]? = nil
    /// Names the conversation gives to unnamed voices, by voice id ("2" for Speaker 2).
    var speakerNames: [String: String] = [:]
}

/// Sends a transcript to the Claude API and gets back structured meeting notes.
enum NotesGenerator {
    static let apiKeyName = "anthropic-api-key"
    static let defaultModel = "claude-sonnet-5-5"
    static let modelDefaultsKey = "notes-model"

    static var model: String {
        let saved = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
        return saved.isEmpty ? defaultModel : saved
    }

    private static let systemPrompt = """
    You are an expert meeting scribe. You get the raw, automatically transcribed text of a \
    meeting or conversation. It may contain recognition mistakes and filler words, and may or may not have speaker labels. \
    Write clear, accurate meeting notes and save them by calling the \
    save_meeting_notes tool. Always call that tool; do not reply with plain text.

    Rules:
    - Use only what is in the transcript. Never invent attendees, decisions, owners or dates.
    - Summary: 2 to 5 sentences covering purpose, main outcomes and anything urgent.
    - Speaker labels: some transcripts start each turn with who is speaking, either a real name or \
    "Speaker N". Use real names as the owners of action items and for attributing decisions. Where the \
    label is "Speaker N", do not invent a name; use that label (for example "Speaker 2") as the owner \
    unless the conversation clearly says who it is.
    - Speaker names: when turns are labelled "Speaker N" and the conversation makes it clear who \
    one of them is (they introduce themselves, someone addresses them by name and they answer, or \
    they are thanked or called on by name right before or after speaking), add an entry to \
    speaker_names with the label and the name. Only when it is reasonably clear; otherwise leave that \
    speaker out. Never give two speakers the same name.
    - Attendees: the confirmed attendee list when one is given, plus anyone else named or addressed; \
    empty if none are clear. Only real names: never list a "Speaker N" label as an attendee, since that \
    voice is usually one of the named people.
    - Abbreviations: write "COB" for close of business and "EOD" for end of day, everywhere they \
    appear, including in due dates.
    - Relative dates: whenever anyone refers to a day or period relative to the meeting, such as \
    "this Friday", "next Tuesday", "upcoming Monday", "last Thursday", "tomorrow", "yesterday", \
    "in two weeks", "a week from Friday", "end of the month", "next quarter" or "the 15th", keep \
    their words in the notes and add one entry for each distinct phrase to relative_dates. Never \
    work out the date yourself: the app turns each entry into the full date and puts it next to \
    the phrase. How to describe a phrase: anchor "weekday" with weekday (1 Monday to 7 Sunday) and \
    which (this, next, last, upcoming; a plain "Friday" or "coming Friday" is upcoming), plus \
    plus_days for things like "a week from Friday" (7); anchor "day" with offset_days (today 0, \
    tomorrow 1, yesterday -1, "in 3 days" 3, "2 days ago" -2, "a week from today" 7); anchor \
    "period" with unit (week, month, quarter or year), offset (0 this, 1 next, -1 last, 2 in two) \
    and edge (whole for "next month", start for "beginning of", end for "end of"; the end of a week \
    is Friday); anchor "day_of_month" with day and which (this, next, upcoming). In an action \
    item's due field copy the phrase as said, adding COB or EOD if said, and the app replaces it \
    with the date.
    - Time markers: when a line of the transcript starts with a number in square brackets, like \
    "[125]", that is the second it starts at. For every topic point, decision and action item give \
    "at", the marker of the line where it was said. Leave "at" out if there are no markers. The \
    markers are not part of the text; never copy them into the notes.
    - Sub-bullets: where a point has supporting detail, such as reasons, numbers, examples, \
    names or steps, put each detail in that point\'s "sub_points" (short phrases) instead of \
    making a long point or more top-level points. A point should be one clear statement; most \
    topics have 2 to 4 points and a point has 0 to 4 sub-points. Do not add sub-points that just \
    repeat the point.
    - Topics: group the discussion by core discussion point. Each topic has a short title (2 to 6 \
    words) naming the subject and a few concise bullets with the key points, even if the subject \
    came up several times in different parts of the meeting; bring those parts together under one \
    topic. Order topics by importance or first mention. Typically 2 to 7 topics; do not make a \
    topic for small talk. Leave out the discussion field.
    - Decisions: things the group agreed or decided.
    - Action items: concrete tasks someone committed to or was asked to do. Give the owner \
    when the transcript makes it clear, otherwise leave it out. Give a due date only if one was \
    stated, as the person said it.
    - Risks and blockers: concerns raised, blockers, dependencies on other people or teams, and \
    anything said to be at risk of slipping. One short line each, naming who raised it or owns it \
    when clear. Empty if none came up; do not invent risks.
    - Key dates: every deadline, due date, launch, meeting or other date mentioned, one entry each \
    as "what: when", keeping the date words as said (for example "Beta cut: next Monday"). Empty if \
    no dates came up.
    - Open questions: questions raised but not answered.
    - Next steps: follow-ups such as the next meeting or what happens after this one.
    - Title: a short, specific title (under 8 words).
    - If a section has nothing, return an empty list. If the transcript is a personal memo \
    rather than a meeting, still use the same structure.
    """

    private static let tool: [String: Any] = [
        "name": "save_meeting_notes",
        "description": "Save the finished meeting notes.",
        "input_schema": [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "attendees": ["type": "array", "items": ["type": "string"]],
                "topics": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "points": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "text": ["type": "string"],
                                        "at": ["type": "integer"],
                                        "sub_points": ["type": "array", "items": ["type": "string"]],
                                    ],
                                    "required": ["text"],
                                ],
                            ],
                        ],
                        "required": ["title", "points"],
                    ],
                ],
                "decisions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["text": ["type": "string"], "at": ["type": "integer"]],
                        "required": ["text"],
                    ],
                ],
                "action_items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "task": ["type": "string"],
                            "owner": ["type": "string"],
                            "due": ["type": "string"],
                            "at": ["type": "integer"],
                        ],
                        "required": ["task"],
                    ],
                ],
                "open_questions": ["type": "array", "items": ["type": "string"]],
                "risks": ["type": "array", "items": ["type": "string"]],
                "key_dates": ["type": "array", "items": ["type": "string"]],
                "next_steps": ["type": "array", "items": ["type": "string"]],
                "speaker_names": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["speaker": ["type": "string"], "name": ["type": "string"]],
                        "required": ["speaker", "name"],
                    ],
                ],
                "relative_dates": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "phrase": ["type": "string"],
                            "anchor": ["type": "string", "enum": ["weekday", "day", "period", "day_of_month"]],
                            "weekday": ["type": "integer"],
                            "which": ["type": "string", "enum": ["this", "next", "last", "upcoming"]],
                            "plus_days": ["type": "integer"],
                            "offset_days": ["type": "integer"],
                            "unit": ["type": "string", "enum": ["week", "month", "quarter", "year"]],
                            "offset": ["type": "integer"],
                            "edge": ["type": "string", "enum": ["whole", "start", "end"]],
                            "day": ["type": "integer"],
                        ],
                        "required": ["phrase", "anchor"],
                    ],
                ],
            ],
            "required": ["title", "summary", "attendees", "topics", "decisions",
                         "action_items", "open_questions", "next_steps"],
        ],
    ]

    static func generate(transcript: String, meetingDate: Date, attendees: [String] = [],
                         voicesIdentified: Bool = false, template: NoteTemplate? = nil) async throws -> GeneratedNotes {
        guard let key = Keychain.get(apiKeyName), !key.isEmpty else { throw NotesError.missingKey }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NotesError.emptyTranscript }

        var userMessage = "Meeting date: \(meetingDate.formatted(date: .complete, time: .shortened))\n"
        if !attendees.isEmpty {
            userMessage += "Attendees (confirmed by the user): \(attendees.joined(separator: ", "))\n"
        }
        let vocabulary = Vocabulary.terms
        if !vocabulary.isEmpty {
            userMessage += "Names and terms that may come up, spelled correctly (speech recognition may have misheard them; use these spellings in the notes): \(vocabulary.joined(separator: ", "))\n"
        }
        if text.contains("Speaker 1:") && !voicesIdentified {
            userMessage += "Speakers are labelled Speaker 1, Speaker 2 and so on because nobody has said who is who yet.\n"
        }
        if let template {
            userMessage += "\nNotes template (\(template.name)). Follow these instructions for the shape of the notes:\n\(template.instructions)\n"
        }
        userMessage += "\nTranscript:\n\(text)"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "output_config": ["effort": "low"],
            "system": systemPrompt,
            "tools": [tool],
            "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": userMessage]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotesError.badResponse
        }
        if status != 200 {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw NotesError.api(message ?? "The AI service returned an error (\(status)).")
        }
        guard let content = json["content"] as? [[String: Any]],
              let input = content.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any]
        else { throw NotesError.badResponse }

        func strings(_ name: String) -> [String] {
            (input[name] as? [Any])?.compactMap { $0 as? String }
                .map { NotesText.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty } ?? []
        }

        var times: [String: Double] = [:]
        /// Reads a list whose entries are either plain text or {text, at}.
        func timed(_ value: Any?) -> [(text: String, at: Double?, subs: [String])] {
            (value as? [Any] ?? []).compactMap { entry in
                let text: String?
                var at: Double?
                var subs: [String] = []
                if let s = entry as? String { text = s }
                else if let d = entry as? [String: Any] {
                    text = d["text"] as? String
                    at = (d["at"] as? Double) ?? (d["at"] as? Int).map(Double.init)
                    subs = (d["sub_points"] as? [String] ?? [])
                        .map { NotesText.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .filter { !$0.isEmpty }
                } else { text = nil }
                guard let clean = text.map({ NotesText.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                      !clean.isEmpty else { return nil }
                return (clean, at, subs)
            }
        }

        let items: [ActionItem] = (input["action_items"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let task = (raw["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !task.isEmpty else { return nil }
            let owner = (raw["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let due = (raw["due"] as? String).map { NotesText.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let item = ActionItem(task: NotesText.normalize(task),
                                  owner: (owner?.isEmpty ?? true) ? nil : owner,
                                  due: (due?.isEmpty ?? true) ? nil : due)
            if let at = (raw["at"] as? Double) ?? (raw["at"] as? Int).map(Double.init) { times["a:\(item.id)"] = at }
            return item
        }

        func int(_ raw: [String: Any], _ key: String) -> Int? {
            if let v = raw[key] as? Int { return v }
            if let v = raw[key] as? Double { return Int(v) }
            return nil
        }
        let specs: [RelativeDateSpec] = (input["relative_dates"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let phrase = (raw["phrase"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !phrase.isEmpty, let anchor = raw["anchor"] as? String else { return nil }
            return RelativeDateSpec(
                phrase: phrase, anchor: anchor, weekday: int(raw, "weekday"), which: raw["which"] as? String,
                plusDays: int(raw, "plus_days"), offsetDays: int(raw, "offset_days"),
                unit: raw["unit"] as? String, offset: int(raw, "offset"), edge: raw["edge"] as? String,
                day: int(raw, "day"))
        }

        let decisions = timed(input["decisions"])
        for (i, d) in decisions.enumerated() { if let at = d.at { times["d:\(i)"] = at } }
        var notes = MeetingNotes(
            summary: NotesText.normalize((input["summary"] as? String) ?? ""),
            attendees: strings("attendees"),
            discussion: strings("discussion"),
            decisions: decisions.map(\.text),
            actionItems: items,
            openQuestions: strings("open_questions"),
            nextSteps: strings("next_steps"))
        let risks = strings("risks")
        if !risks.isEmpty { notes.risks = risks }
        let keyDates = strings("key_dates")
        if !keyDates.isEmpty { notes.keyDates = keyDates }
        let topics: [DiscussionTopic] = (input["topics"] as? [[String: Any]] ?? []).compactMap { raw in
            let title = NotesText.normalize((raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let points = timed(raw["points"])
            guard !title.isEmpty else { return nil }
            let topic = DiscussionTopic(title: title, points: points.map(\.text),
                                        subs: points.contains { !$0.subs.isEmpty } ? points.map(\.subs) : nil)
            for (i, p) in points.enumerated() { if let at = p.at { times["p:\(topic.id):\(i)"] = at } }
            return topic
        }
        if !topics.isEmpty { notes.topics = topics }
        if !times.isEmpty { notes.times = times }
        RelativeDates.apply(specs, to: &notes, meetingDate: meetingDate)
        notes.keyDates = notes.keyDates?.sortedByDate()
        var speakerNames: [String: String] = [:]
        for raw in input["speaker_names"] as? [[String: Any]] ?? [] {
            guard let label = raw["speaker"] as? String,
                  let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !MeetingNotes.isSpeakerLabel(name) else { continue }
            let id = label.replacingOccurrences(of: "speaker", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { speakerNames[id] = name }
        }
        let title = (input["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GeneratedNotes(title: title.isEmpty ? "Meeting" : title, notes: notes,
                              usage: json["usage"] as? [String: Any], speakerNames: speakerNames)
    }
}


/// Small, predictable clean-ups applied to every drafted note.
enum NotesText {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"\b(?:close|end) of (?:the )?(?:business|working)(?: day)?\b"#, "COB"),
            (#"\bend of (?:the )?day\b"#, "EOD"),
            (#"\bcob\b"#, "COB"),
            (#"\beod\b"#, "EOD"),
        ]
        return patterns.compactMap { p in
            (try? NSRegularExpression(pattern: p.0, options: [.caseInsensitive])).map { ($0, p.1) }
        }
    }()

    /// "close of business" becomes COB and "end of day" becomes EOD.
    static func normalize(_ text: String) -> String {
        var result = text
        for (regex, replacement) in rules {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}

/// One relative date phrase the AI found, described in a fixed form that code can turn into a real date.
struct RelativeDateSpec {
    var phrase: String
    var anchor: String          // weekday, day, period or day_of_month
    var weekday: Int?           // 1 Monday ... 7 Sunday
    var which: String?          // this, next, last or upcoming
    var plusDays: Int?
    var offsetDays: Int?
    var unit: String?           // week, month, quarter or year
    var offset: Int?
    var edge: String?           // whole, start or end
    var day: Int?
}

/// Turns phrases like "next Tuesday" or "end of the month" into full dates, with exact calendar math.
/// Weeks run Monday to Sunday. "This Friday" is the Friday of the current week, "next Friday" the Friday of the
/// following week, "last Friday" the most recent Friday before the meeting, and a plain or "upcoming" Friday the
/// next one after the meeting day. The end of a week is Friday.
enum RelativeDates {
    private static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }()

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static func full(_ date: Date) -> String { format(date, "EEE, MMM d, yyyy") }

    /// The full date (or period) a phrase means on the day of the meeting, or nil if it cannot be worked out.
    static func resolve(_ spec: RelativeDateSpec, meetingDate: Date) -> String? {
        let cal = calendar
        let today = cal.startOfDay(for: meetingDate)
        func add(_ unit: Calendar.Component, _ n: Int, to date: Date) -> Date { cal.date(byAdding: unit, value: n, to: date) ?? date }
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start else { return nil }

        switch spec.anchor {
        case "weekday":
            guard let w = spec.weekday, (1...7).contains(w) else { return nil }
            let thisOne = add(.day, w - 1, to: weekStart)
            var date: Date
            switch spec.which ?? "upcoming" {
            case "this": date = thisOne
            case "next": date = add(.day, 7, to: thisOne)
            case "last": date = thisOne < today ? thisOne : add(.day, -7, to: thisOne)
            default: date = thisOne > today ? thisOne : add(.day, 7, to: thisOne)
            }
            if let extra = spec.plusDays { date = add(.day, extra, to: date) }
            return full(date)

        case "day":
            guard let n = spec.offsetDays else { return nil }
            return full(add(.day, n, to: today))

        case "period":
            guard let unit = spec.unit else { return nil }
            let n = spec.offset ?? 0
            let edge = spec.edge ?? "whole"
            switch unit {
            case "week":
                let start = add(.day, 7 * n, to: weekStart)
                if edge == "end" { return full(add(.day, 4, to: start)) }
                return "week of " + full(start)
            case "month":
                guard let first = cal.dateInterval(of: .month, for: add(.month, n, to: today))?.start else { return nil }
                if edge == "start" { return full(first) }
                if edge == "end" { return full(add(.day, -1, to: add(.month, 1, to: first))) }
                return format(first, "MMM yyyy")
            case "quarter":
                let month = cal.component(.month, from: today)
                let startMonth = ((month - 1) / 3) * 3 + 1
                var parts = cal.dateComponents([.year], from: today)
                parts.month = startMonth
                parts.day = 1
                guard let thisQuarter = cal.date(from: parts) else { return nil }
                let first = add(.month, 3 * n, to: thisQuarter)
                if edge == "start" { return full(first) }
                if edge == "end" { return full(add(.day, -1, to: add(.month, 3, to: first))) }
                let q = (cal.component(.month, from: first) - 1) / 3 + 1
                return "Q\(q) \(cal.component(.year, from: first))"
            case "year":
                var parts = cal.dateComponents([.year], from: today)
                parts.year = (parts.year ?? 0) + n
                parts.month = 1
                parts.day = 1
                guard let first = cal.date(from: parts) else { return nil }
                if edge == "start" { return full(first) }
                if edge == "end" { return full(add(.day, -1, to: add(.year, 1, to: first))) }
                return String(cal.component(.year, from: first))
            default: return nil
            }

        case "day_of_month":
            guard let day = spec.day, (1...31).contains(day) else { return nil }
            func date(inMonthOffset m: Int) -> Date? {
                guard let monthStart = cal.dateInterval(of: .month, for: add(.month, m, to: today))?.start,
                      let range = cal.range(of: .day, in: .month, for: monthStart) else { return nil }
                return add(.day, min(day, range.count) - 1, to: monthStart)
            }
            switch spec.which ?? "upcoming" {
            case "this": return date(inMonthOffset: 0).map(full)
            case "next": return date(inMonthOffset: 1).map(full)
            default:
                if let d = date(inMonthOffset: 0), d > today { return full(d) }
                return date(inMonthOffset: 1).map(full)
            }

        default:
            return nil
        }
    }

    /// Puts the full date next to each relative phrase in the notes, and replaces the phrase in due dates.
    static func apply(_ specs: [RelativeDateSpec], to notes: inout MeetingNotes, meetingDate: Date) {
        var seen = Set<String>()
        let resolved: [(phrase: String, date: String)] = specs
            .sorted { $0.phrase.count > $1.phrase.count }
            .compactMap { spec in
                guard seen.insert(spec.phrase.lowercased()).inserted,
                      let date = resolve(spec, meetingDate: meetingDate) else { return nil }
                return (spec.phrase, date)
            }
        guard !resolved.isEmpty else { return }

        func annotate(_ text: String) -> String {
            var result = text
            for (phrase, date) in resolved {
                guard let regex = try? NSRegularExpression(
                    pattern: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b(?! \\()",
                    options: [.caseInsensitive]) else { continue }
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$0 (" + NSRegularExpression.escapedTemplate(for: date) + ")")
            }
            return result
        }
        func dueDate(_ text: String) -> String {
            var result = text
            for (phrase, date) in resolved {
                guard let regex = try? NSRegularExpression(
                    pattern: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b",
                    options: [.caseInsensitive]) else { continue }
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: date))
            }
            return result
        }

        notes.summary = annotate(notes.summary)
        notes.discussion = notes.discussion.map(annotate)
        if var topics = notes.topics {
            for i in topics.indices {
                topics[i].points = topics[i].points.map(annotate)
                if let subs = topics[i].subs { topics[i].subs = subs.map { $0.map(annotate) } }
            }
            notes.topics = topics
        }
        notes.decisions = notes.decisions.map(annotate)
        notes.openQuestions = notes.openQuestions.map(annotate)
        notes.nextSteps = notes.nextSteps.map(annotate)
        notes.risks = notes.risks?.map(annotate)
        notes.keyDates = notes.keyDates?.map(annotate)
        for i in notes.actionItems.indices {
            notes.actionItems[i].task = annotate(notes.actionItems[i].task)
            if let due = notes.actionItems[i].due { notes.actionItems[i].due = dueDate(due) }
        }
    }
}
