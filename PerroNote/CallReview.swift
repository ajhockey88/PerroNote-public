import Foundation
import SwiftUI

// MARK: - The review saved on a meeting

/// How a help desk call measured up: the process checklist, call handling, mood and the moments worth a look.
/// Drafted by Claude from the transcript only, so tone is read from words and pacing, not the voice itself.
struct CallReview: Codable, Hashable {
    enum StepResult: String, Codable, CaseIterable {
        case pass, partial, missed, notApplicable = "not_applicable"

        var title: String {
            switch self {
            case .pass: return "Pass"
            case .partial: return "Partial"
            case .missed: return "Missed"
            case .notApplicable: return "N/A"
            }
        }
    }

    struct Step: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var importance: ProcessStep.Importance
        var result: StepResult
        var detail: String
        /// Second in the recording where it happened, if it did.
        var at: Double?
    }

    struct Rating: Codable, Hashable, Identifiable {
        var id: String { area }
        var area: String
        /// 1 to 5.
        var score: Int
        var note: String
    }

    /// Calm (5) to tense (1) for each side at one point in the call.
    struct MoodPoint: Codable, Hashable {
        var at: Double
        var agent: Double
        var caller: Double
    }

    enum MomentKind: String, Codable, CaseIterable {
        case frustration, curt, rushing, silence, confusion, good, other

        var title: String {
            switch self {
            case .frustration: return "Frustration"
            case .curt: return "Curt tone"
            case .rushing: return "Rushing to end"
            case .silence: return "Long silence or hold"
            case .confusion: return "Confusion"
            case .good: return "Good moment"
            case .other: return "Worth a look"
            }
        }
    }

    struct Moment: Codable, Hashable, Identifiable {
        var id = UUID()
        var kind: MomentKind
        /// A short label such as "Caller frustration".
        var label: String
        /// "agent" or "caller".
        var speaker: String
        var quote: String
        var note: String
        var at: Double?
    }

    /// One requirement from your reference documents that applied to this call.
    struct GuidelineCheck: Codable, Hashable, Identifiable {
        var id = UUID()
        var requirement: String
        /// The document it comes from.
        var source: String
        var result: StepResult
        var detail: String
        var at: Double?
    }

    enum Outcome: String, Codable {
        case resolved, unresolved, escalated, unclear

        var title: String {
            switch self {
            case .resolved: return "Resolved"
            case .unresolved: return "Not resolved"
            case .escalated: return "Escalated"
            case .unclear: return "Unclear"
            }
        }
    }

    var processName: String
    var summary: String
    var outcome: Outcome
    var steps: [Step]
    var handling: [Rating]
    var mood: [MoodPoint]
    var moments: [Moment]
    var coaching: [String]
    var painPoints: [String]
    /// The voice id ("1", "2") of the help desk agent, when voices were separated.
    var agentSpeaker: String?
    var date = Date()
    /// Checks against your reference documents. Nil when there were none.
    var guidelines: [GuidelineCheck]? = nil

    // MARK: Score

    /// 0 to 100: the process counts for 60 percent (weighted by importance) and call handling for 40.
    var score: Int {
        func credit(_ r: StepResult) -> Double { r == .pass ? 1 : r == .partial ? 0.5 : 0 }
        let counted = steps.filter { $0.result != .notApplicable }
        let checks = (guidelines ?? []).filter { $0.result != .notApplicable }
        // Each guideline from your documents counts like a nice-to-have step.
        let weight = counted.reduce(0.0) { $0 + $1.importance.weight } + Double(checks.count)
        let earned = counted.reduce(0.0) { $0 + $1.importance.weight * credit($1.result) }
            + checks.reduce(0.0) { $0 + credit($1.result) }
        let process = weight > 0 ? earned / weight : 1
        let ratings = handling.map { Double(min(max($0.score, 1), 5)) }
        let care = ratings.isEmpty ? process : (ratings.reduce(0, +) / Double(ratings.count) - 1) / 4
        return Int((100 * (0.6 * process + 0.4 * care)).rounded())
    }

    var missedSteps: [Step] { steps.filter { $0.result == .missed } }
    var missedGuidelines: [GuidelineCheck] { (guidelines ?? []).filter { $0.result == .missed } }
    var missedCritical: Bool { missedSteps.contains { $0.importance == .critical } }
    var flags: [Moment] { moments.filter { $0.kind != .good } }
    var goodMoments: [Moment] { moments.filter { $0.kind == .good } }

    var verdict: String {
        let s = score
        if s >= 85 && !missedCritical { return "Great call" }
        if s >= 70 && !missedCritical { return "Good call, small fixes" }
        if s >= 55 { return "Needs coaching" }
        return "Needs attention"
    }

    /// Stepped from green through orange to red, for the ring and the summary.
    var level: Level {
        let s = score
        if s >= 85 && !missedCritical { return .good }
        if s >= 55 { return .fair }
        return .poor
    }

    enum Level { case good, fair, poor }

    var flagSummary: String {
        let n = flags.count, g = goodMoments.count
        return g > 0 ? "\(n) + \(g) good" : "\(n)"
    }
}

// MARK: - Your process

/// One step of your help desk process, as written in Settings > Call review.
struct ProcessStep: Codable, Hashable, Identifiable {
    enum Importance: String, Codable, CaseIterable {
        case critical, required, optional

        var title: String {
            switch self {
            case .critical: return "Critical"
            case .required: return "Required"
            case .optional: return "Nice to have"
            }
        }

        var weight: Double {
            switch self {
            case .critical: return 3
            case .required: return 2
            case .optional: return 1
            }
        }
    }

    var id = UUID()
    var name: String
    var importance: Importance = .required
}

/// What to watch for in a call, switched on or off in Settings.
enum WatchFor: String, Codable, CaseIterable, Identifiable {
    case frustration, curt, rushing, silence, confusion, good

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frustration: return "Frustration or anger"
        case .curt: return "Curt or dismissive tone"
        case .rushing: return "Rushing to end the call"
        case .silence: return "Long silence or hold"
        case .confusion: return "Confusion or repeated questions"
        case .good: return "Good moments to praise"
        }
    }

    var kind: CallReview.MomentKind { CallReview.MomentKind(rawValue: rawValue) ?? .other }
}

struct CallReviewSettingsData: Codable, Hashable {
    var enabled = true
    /// Meetings with this tag are reviewed automatically once their notes are drafted.
    var tag = "Help desk"
    var processName = "Help desk standard"
    var steps: [ProcessStep] = [
        ProcessStep(name: "Greeting and name"),
        ProcessStep(name: "Verify caller identity", importance: .critical),
        ProcessStep(name: "Log ticket number"),
        ProcessStep(name: "Troubleshoot before reset"),
        ProcessStep(name: "Confirm the fix works"),
        ProcessStep(name: "Ask \u{201C}anything else?\u{201D}", importance: .optional),
    ]
    var watch: [WatchFor] = WatchFor.allCases
    /// Extra guidance for the reviewer, in your own words.
    var notes = ""
}

enum CallReviewSettings {
    private static let key = "call-review-settings"

    static var current: CallReviewSettingsData {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let saved = try? JSONDecoder().decode(CallReviewSettingsData.self, from: data) else { return CallReviewSettingsData() }
            return saved
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// True when this meeting carries the call review tag.
    static func applies(to meeting: Meeting) -> Bool {
        let s = current
        let tag = s.tag.trimmingCharacters(in: .whitespaces)
        guard s.enabled, !tag.isEmpty else { return false }
        return (meeting.tags ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

// MARK: - Asking Claude

struct GeneratedReview {
    var review: CallReview
    var usage: [String: Any]?
}

enum CallReviewer {
    private static let systemPrompt = """
    You are an experienced help desk quality reviewer. You get the automatically transcribed text of one \
    support call, which may contain recognition mistakes, plus the support team's process checklist. Review \
    the call fairly and save the review by calling the save_call_review tool. Always call that tool.

    Rules:
    - Use only what is in the transcript. Never invent quotes, steps or events. Quotes must be words that \
    were actually said (fix obvious recognition slips only).
    - You only have the words, not the audio. Judge tone and emotion from wording, interruptions, repetition, \
    pacing and pauses (gaps between time markers). Do not claim things only a voice could show.
    - Agent and caller: work out which speaker is the help desk agent (the one helping) and which is the \
    caller. Give agent_speaker as the agent's label exactly as it appears (for example "Speaker 2" or a name), \
    or leave it out if the transcript has no speaker labels.
    - Time markers: when a line starts with a number in square brackets, like "[125]", that is the second it \
    starts at. Give "at" from the marker of the line where something happened. Never copy markers into text.
    - Process steps: return exactly one entry per checklist step, in order, with its number. result is \
    "pass" when clearly done, "partial" when started but incomplete, "missed" when it should have happened \
    and did not, "not_applicable" when the call gave no reason for it. detail is one short line saying what \
    happened or what was missing.
    - Call handling: rate each area from 1 (poor) to 5 (excellent), with a short note: courtesy (polite, \
    respectful), empathy (acknowledges the caller's situation and feelings), clarity (clear steps, plain \
    words), patience (lets the caller finish, does not rush), ownership (takes responsibility for the fix).
    - Mood: 6 to 12 points spread across the call, each with "at" and a calm-to-tense level for the agent \
    and the caller from 1 (tense, upset, short) to 5 (calm, relaxed).
    - Moments: the specific moments a coach should hear, only of the kinds listed, each with the speaker \
    ("agent" or "caller"), the exact quote, a short label (like "Caller frustration" or "Agent curt tone") and \
    a coaching note. For an agent's weak moment, the note suggests better wording. Include good moments too \
    when that kind is listed. Up to 8 moments, the most useful first; none if nothing stands out.
    - Reference documents: when the team's own documents (procedures, scripts, policies, knowledge \
    articles) are attached, they are the standard. Read them fully, then go through every requirement, rule \
    or expected behavior in them that applied to this call and add one guidelines entry each: the \
    requirement in a short line, the document title as source, a result (pass, partial, missed, or \
    not_applicable only if it truly could not apply), a detail line on what happened, and "at" where it \
    happened. Do not repeat checklist steps there unless the document adds something specific. Where a \
    document gives exact wording, a required order or a time limit, check it exactly. Use the documents for \
    the coaching points too. Leave guidelines empty when no documents are attached.
    - Outcome: resolved, unresolved, escalated or unclear.
    - Summary: 2 to 4 sentences: what the call was about, how it ended, and the main things to coach.
    - Coaching: 2 to 5 short, concrete points for the agent, starting with the most important. End with \
    one thing to keep doing when there is one, starting "Keep doing:".
    - Pain points: what made this harder for the caller (repeat contacts, long waits, confusing steps, \
    broken tools). Empty if none came up.
    """

    private static func tool(steps: Int, kinds: [String]) -> [String: Any] {
        let kindEnum: [String] = kinds + ["other"]
        let results: [String] = ["pass", "partial", "missed", "not_applicable"]
        let string: [String: Any] = ["type": "string"]
        let integer: [String: Any] = ["type": "integer"]
        let stringList: [String: Any] = ["type": "array", "items": string]
        func list(_ properties: [String: Any], required: [String], description: String? = nil) -> [String: Any] {
            var out: [String: Any] = ["type": "array",
                                      "items": ["type": "object", "properties": properties, "required": required] as [String: Any]]
            if let description { out["description"] = description }
            return out
        }
        let stepProps: [String: Any] = ["number": integer, "result": ["type": "string", "enum": results] as [String: Any],
                                        "detail": string, "at": integer]
        let areaEnum: [String] = ["courtesy", "empathy", "clarity", "patience", "ownership"]
        let handlingProps: [String: Any] = ["area": ["type": "string", "enum": areaEnum] as [String: Any],
                                            "score": integer, "note": string]
        let number: [String: Any] = ["type": "number"]
        let moodProps: [String: Any] = ["at": integer, "agent": number, "caller": number]
        let momentProps: [String: Any] = ["kind": ["type": "string", "enum": kindEnum] as [String: Any],
                                          "label": string,
                                          "speaker": ["type": "string", "enum": ["agent", "caller"]] as [String: Any],
                                          "quote": string, "note": string, "at": integer]
        let guidelineProps: [String: Any] = ["requirement": string, "source": string,
                                             "result": ["type": "string", "enum": results] as [String: Any],
                                             "detail": string, "at": integer]
        let outcomeEnum: [String] = ["resolved", "unresolved", "escalated", "unclear"]
        var properties: [String: Any] = [:]
        properties["summary"] = string
        properties["outcome"] = ["type": "string", "enum": outcomeEnum] as [String: Any]
        properties["agent_speaker"] = string
        properties["steps"] = list(stepProps, required: ["number", "result", "detail"],
                                   description: "One entry per checklist step (\(steps) in all), numbered from 1.")
        properties["handling"] = list(handlingProps, required: ["area", "score", "note"])
        properties["mood"] = list(moodProps, required: ["at", "agent", "caller"])
        properties["moments"] = list(momentProps, required: ["kind", "label", "speaker", "quote", "note"])
        properties["guidelines"] = list(guidelineProps, required: ["requirement", "source", "result", "detail"])
        properties["coaching"] = stringList
        properties["pain_points"] = stringList
        let required: [String] = ["summary", "outcome", "steps", "handling", "mood", "moments", "coaching", "pain_points"]
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": required]
        return ["name": "save_call_review", "description": "Save the finished call review.", "input_schema": schema]
    }

    static let areas = ["Courtesy", "Empathy", "Clarity", "Patience", "Ownership"]

    static func review(_ meeting: Meeting, settings: CallReviewSettingsData = CallReviewSettings.current) async throws -> GeneratedReview {
        guard let key = Keychain.get(NotesGenerator.apiKeyName), !key.isEmpty else { throw NotesError.missingKey }
        let text = meeting.timedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NotesError.emptyTranscript }
        let steps = settings.steps.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let kinds = settings.watch.map(\.rawValue)

        var message = "Call date: \(meeting.date.formatted(date: .complete, time: .shortened))\n"
        message += "Call length: \(formatDuration(meeting.duration))\n"
        if let voices = meeting.voices, voices.count > 1 {
            message += "Speakers: \(voices.map(\.label).joined(separator: ", "))\n"
        }
        message += "\nProcess checklist (\(settings.processName)):\n"
        for (i, s) in steps.enumerated() { message += "\(i + 1). \(s.name) (\(s.importance.title.lowercased()))\n" }
        message += "\nMoment kinds to look for: \(kinds.isEmpty ? "none" : kinds.joined(separator: ", "))\n"
        let extra = settings.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { message += "\nReviewer guidance from the team:\n\(extra)\n" }
        let documents = ReferenceDocs.contentBlocks()
        if !documents.isEmpty {
            message += "\nThe team's reference documents are attached above (\(documents.count)). Review the call against them and fill in guidelines.\n"
        }
        message += "\nTranscript:\n\(text)"
        let content: [[String: Any]] = documents + [["type": "text", "text": message]]

        let body: [String: Any] = [
            "model": NotesGenerator.model,
            "max_tokens": 12000,
            "output_config": ["effort": "medium"],
            "system": systemPrompt,
            "tools": [tool(steps: steps.count, kinds: kinds)],
            "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotesError.badResponse }
        if status != 200 {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw NotesError.api(message ?? "The AI service returned an error (\(status)).")
        }
        guard let content = json["content"] as? [[String: Any]],
              let input = content.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any]
        else { throw NotesError.badResponse }

        func clean(_ v: Any?) -> String {
            NotesText.normalize(((v as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func number(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            return nil
        }
        func strings(_ name: String) -> [String] {
            (input[name] as? [Any] ?? []).map(clean).filter { !$0.isEmpty }
        }

        // Steps come back by number; any the reply skipped count as not applicable rather than vanishing.
        var byNumber: [Int: [String: Any]] = [:]
        for raw in input["steps"] as? [[String: Any]] ?? [] {
            if let n = number(raw["number"]).map({ Int($0) }) { byNumber[n] = raw }
        }
        let reviewed: [CallReview.Step] = steps.enumerated().map { i, s in
            let raw = byNumber[i + 1]
            return CallReview.Step(
                name: s.name, importance: s.importance,
                result: CallReview.StepResult(rawValue: (raw?["result"] as? String) ?? "") ?? .notApplicable,
                detail: clean(raw?["detail"]),
                at: number(raw?["at"]))
        }

        var ratings: [String: CallReview.Rating] = [:]
        for raw in input["handling"] as? [[String: Any]] ?? [] {
            guard let area = (raw["area"] as? String)?.lowercased(), let score = number(raw["score"]) else { continue }
            let title = areas.first { $0.lowercased() == area } ?? area.capitalized
            ratings[title] = CallReview.Rating(area: title, score: min(max(Int(score.rounded()), 1), 5), note: clean(raw["note"]))
        }

        let mood: [CallReview.MoodPoint] = (input["mood"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let at = number(raw["at"]), let a = number(raw["agent"]), let c = number(raw["caller"]) else { return nil }
            return CallReview.MoodPoint(at: max(0, at), agent: min(max(a, 1), 5), caller: min(max(c, 1), 5))
        }.sorted { $0.at < $1.at }

        let moments: [CallReview.Moment] = (input["moments"] as? [[String: Any]] ?? []).compactMap { raw in
            let quote = clean(raw["quote"])
            guard !quote.isEmpty else { return nil }
            let kind = CallReview.MomentKind(rawValue: (raw["kind"] as? String) ?? "") ?? .other
            let label = clean(raw["label"])
            return CallReview.Moment(kind: kind, label: label.isEmpty ? kind.title : label,
                                     speaker: (raw["speaker"] as? String) == "agent" ? "agent" : "caller",
                                     quote: quote, note: clean(raw["note"]), at: number(raw["at"]))
        }

        var agent: String?
        if let label = (input["agent_speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            agent = meeting.voices?.first { $0.label.caseInsensitiveCompare(label) == .orderedSame || "Speaker \($0.id)".caseInsensitiveCompare(label) == .orderedSame }?.id
        }

        let guidelines: [CallReview.GuidelineCheck] = (input["guidelines"] as? [[String: Any]] ?? []).compactMap { raw in
            let requirement = clean(raw["requirement"])
            guard !requirement.isEmpty else { return nil }
            return CallReview.GuidelineCheck(
                requirement: requirement, source: clean(raw["source"]),
                result: CallReview.StepResult(rawValue: (raw["result"] as? String) ?? "") ?? .notApplicable,
                detail: clean(raw["detail"]), at: number(raw["at"]))
        }

        var review = CallReview(
            processName: settings.processName,
            summary: clean(input["summary"]),
            outcome: CallReview.Outcome(rawValue: (input["outcome"] as? String) ?? "") ?? .unclear,
            steps: reviewed,
            handling: areas.compactMap { ratings[$0] },
            mood: mood,
            moments: moments,
            coaching: strings("coaching"),
            painPoints: strings("pain_points"),
            agentSpeaker: agent)
        if !documents.isEmpty { review.guidelines = guidelines }
        return GeneratedReview(review: review, usage: json["usage"] as? [String: Any])
    }
}

// MARK: - Settings > Call review

struct CallReviewSettingsView: View {
    @State private var s = CallReviewSettings.current

    var body: some View {
        Form {
            Section {
                Toggle("Review tagged calls automatically", isOn: $s.enabled)
                LabeledContent("Tag") {
                    TextField("Help desk", text: $s.tag)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                }
            } footer: {
                Text("Calls with this tag are reviewed as soon as their notes are ready, and get a Review tab beside the notes. Any meeting can be reviewed from its \u{22EF} menu with Review call.")
            }

            Section {
                TextField("Process name", text: $s.processName)
                ForEach($s.steps) { $step in
                    HStack {
                        TextField("Step", text: $step.name)
                        Menu {
                            Picker("Importance", selection: $step.importance) {
                                ForEach(ProcessStep.Importance.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        } label: {
                            ReviewPill(text: step.importance.title, color: color(step.importance))
                        }
                    }
                }
                .onDelete { s.steps.remove(atOffsets: $0) }
                .onMove { s.steps.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    s.steps.append(ProcessStep(name: ""))
                } label: { Label("Add step", systemImage: "plus") }
            } header: {
                HStack {
                    Text("Process steps")
                    Spacer()
                    EditButton().font(.caption).textCase(nil)
                }
            } footer: {
                Text("Missing a critical step counts three times as much as a required one; nice-to-have steps count least. The score is 60% process and 40% call handling.")
            }

            ReferenceDocsSection()

            Section("Watch for") {
                ForEach(WatchFor.allCases) { w in
                    Toggle(w.title, isOn: Binding(
                        get: { s.watch.contains(w) },
                        set: { on in
                            if on { if !s.watch.contains(w) { s.watch.append(w) } } else { s.watch.removeAll { $0 == w } }
                        }))
                }
            }

            Section {
                TextEditor(text: $s.notes).frame(minHeight: 90).font(.footnote)
            } header: {
                Text("Extra guidance for the reviewer")
            } footer: {
                Text("Optional. For example: \u{201C}Escalations must name the tier 2 queue.\u{201D}")
            }

            Section {
                Label {
                    Text("Get the caller's consent before recording, and check your employer's AI and recording policy. Mood and tone are read from the words and pauses only, not the voice.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Call review")
        .onChange(of: s) { CallReviewSettings.current = $0 }
    }

    private func color(_ i: ProcessStep.Importance) -> Color {
        switch i {
        case .critical: return ReviewColors.red
        case .required: return .accentColor
        case .optional: return .gray
        }
    }
}
