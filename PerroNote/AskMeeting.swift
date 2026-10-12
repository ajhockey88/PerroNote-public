import SwiftUI

/// Answers questions about one meeting using the transcript and notes.
enum MeetingAsk {
    struct Turn: Identifiable, Hashable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    private static let systemPrompt = """
    You answer questions about one meeting. You get its transcript (lines may start with a number in \
    square brackets, the second the line starts at) and the drafted notes. Answer only from them. If \
    the meeting does not say, say so plainly. Be brief and specific, name who said what when the \
    transcript shows it, and when useful mention roughly when it came up as minutes and seconds, \
    like 12:30. Plain text only, no markdown headings. Write COB and EOD for close of business and \
    end of day.
    """

    private static let allSystemPrompt = """
    You answer questions across all of someone's recorded meetings. You get each meeting's title, date, \
    attendees and drafted notes, and the transcripts of the most recent ones. Answer only from them. If \
    the meetings do not say, say so plainly. Be brief and specific, and always say which meeting (title \
    and date) something came from. Name who said or owns what when the notes show it. Plain text only, \
    no markdown headings. Write COB and EOD for close of business and end of day.
    """

    /// Transcripts are added newest first until about this many characters, so the request stays a sensible size.
    private static let transcriptBudget = 250_000

    static func ask(_ question: String, history: [Turn], meeting: Meeting) async throws -> (answer: String, usage: TokenUsage) {
        var context = "Meeting: \(meeting.title)\nDate: \(meeting.date.formatted(date: .complete, time: .shortened))\n"
        if let names = meeting.attendeeNames, !names.isEmpty { context += "Attendees: \(names.joined(separator: ", "))\n" }
        if let notes = meeting.notes { context += "\nDrafted notes:\n\(notes.markdown(title: meeting.title, date: meeting.date))\n" }
        context += "\nTranscript:\n\(meeting.timedTranscript)"
        return try await send(question, history: history, context: context + "\n\nI will now ask questions about this meeting.",
                              system: systemPrompt)
    }

    /// Answers a question about every meeting: all the notes, plus as many recent transcripts as fit.
    static func askAll(_ question: String, history: [Turn], meetings: [Meeting]) async throws -> (answer: String, usage: TokenUsage) {
        let sorted = meetings.filter { $0.notes != nil || !($0.transcript ?? "").isEmpty }.sorted { $0.date > $1.date }
        guard !sorted.isEmpty else { throw NotesError.emptyTranscript }
        var budget = transcriptBudget
        var context = "Today is \(Date().formatted(date: .complete, time: .omitted)). There are \(sorted.count) meetings, newest first.\n"
        for (i, m) in sorted.enumerated() {
            context += "\n=== Meeting \(i + 1): \(m.title) (\(m.date.formatted(date: .complete, time: .shortened))) ===\n"
            if let tags = m.tags, !tags.isEmpty { context += "Tags: \(tags.joined(separator: ", "))\n" }
            if let names = m.attendeeNames, !names.isEmpty { context += "Attendees: \(names.joined(separator: ", "))\n" }
            if let notes = m.notes { context += notes.markdown(title: m.title, date: m.date) }
            let transcript = m.labeledTranscript
            if !transcript.isEmpty, transcript.count <= budget {
                budget -= transcript.count
                context += "\nTranscript:\n\(transcript)\n"
            }
        }
        return try await send(question, history: history, context: context + "\n\nI will now ask questions about these meetings.",
                              system: allSystemPrompt)
    }

    private static func send(_ question: String, history: [Turn], context: String,
                             system: String) async throws -> (answer: String, usage: TokenUsage) {
        guard let key = Keychain.get(NotesGenerator.apiKeyName), !key.isEmpty else { throw NotesError.missingKey }

        // The meeting text goes first and is marked for caching, so later questions about the same
        // meetings reuse it at a fraction of the price instead of paying for the transcripts again.
        let cachedContext: [[String: Any]] = [[
            "type": "text",
            "text": context,
            "cache_control": ["type": "ephemeral"],
        ]]
        var messages: [[String: Any]] = [["role": "user", "content": cachedContext],
                                         ["role": "assistant", "content": "Ready. What would you like to know?"]]
        for turn in history { messages.append(["role": turn.isUser ? "user" : "assistant", "content": turn.text]) }
        messages.append(["role": "user", "content": question])

        let body: [String: Any] = [
            "model": NotesGenerator.model,
            "max_tokens": 2000,
            "output_config": ["effort": "low"],
            "system": system,
            "messages": messages,
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
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
        let parts = (json["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        let answer = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw NotesError.badResponse }
        return (NotesText.normalize(answer), TokenUsage(kind: .question, model: NotesGenerator.model, json: json["usage"] as? [String: Any]))
    }
}

/// Questions about one meeting, or about all of them when `meeting` is nil.
struct AskMeetingView: View {
    let meeting: Meeting?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MeetingStore
    @State private var turns: [MeetingAsk.Turn] = []
    @State private var question = ""
    @State private var working = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        meeting == nil
            ? ["What did I commit to this week?", "What's still open with each person?", "When did we last talk about the budget?"]
            : ["What were the key decisions?", "What did I agree to do?", "What was left unresolved?"]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if turns.isEmpty {
                                Text(meeting == nil
                                     ? "Ask anything across all your meetings. Answers come from every meeting's notes and the transcripts of recent ones."
                                     : "Ask anything about this meeting. Answers come from the transcript and notes.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { question = s; send() }
                                        .buttonStyle(.bordered)
                                }
                            }
                            ForEach(turns) { turn in
                                Text(turn.text)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: turn.isUser ? .trailing : .leading)
                                    .background(turn.isUser ? Color.indigo.opacity(0.18) : Color(.secondarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 12))
                                    .id(turn.id)
                            }
                            if working { ProgressView().padding(.leading, 6) }
                            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                        }
                        .padding()
                    }
                    .onChange(of: turns.count) { _ in
                        if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(meeting == nil ? "Ask all meetings" : "Ask this meeting", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(working || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
            }
            .paperScreen()
            .navigationTitle(meeting == nil ? "Ask All Meetings" : "Ask This Meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !working else { return }
        let history = turns
        turns.append(MeetingAsk.Turn(isUser: true, text: q))
        question = ""
        errorText = nil
        working = true
        Task {
            do {
                if let meeting {
                    let result = try await MeetingAsk.ask(q, history: history, meeting: meeting)
                    store.addUsage(meeting.id, result.usage)
                    turns.append(MeetingAsk.Turn(isUser: false, text: result.answer))
                } else {
                    let result = try await MeetingAsk.askAll(q, history: history, meetings: store.meetings)
                    turns.append(MeetingAsk.Turn(isUser: false, text: result.answer))
                }
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}
