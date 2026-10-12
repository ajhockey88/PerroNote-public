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

    static func ask(_ question: String, history: [Turn], meeting: Meeting) async throws -> (answer: String, usage: TokenUsage) {
        guard let key = Keychain.get(NotesGenerator.apiKeyName), !key.isEmpty else { throw NotesError.missingKey }

        var context = "Meeting: \(meeting.title)\nDate: \(meeting.date.formatted(date: .complete, time: .shortened))\n"
        if let names = meeting.attendeeNames, !names.isEmpty { context += "Attendees: \(names.joined(separator: ", "))\n" }
        if let notes = meeting.notes { context += "\nDrafted notes:\n\(notes.markdown(title: meeting.title, date: meeting.date))\n" }
        context += "\nTranscript:\n\(meeting.timedTranscript)"

        // The meeting text goes first and is marked for caching, so later questions about the same
        // meeting reuse it at a fraction of the price instead of paying for the transcript again.
        let cachedContext: [[String: Any]] = [[
            "type": "text",
            "text": context + "\n\nI will now ask questions about this meeting.",
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
            "system": systemPrompt,
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

struct AskMeetingView: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MeetingStore
    @State private var turns: [MeetingAsk.Turn] = []
    @State private var question = ""
    @State private var working = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private let suggestions = ["What were the key decisions?", "What did I agree to do?", "What was left unresolved?"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if turns.isEmpty {
                                Text("Ask anything about this meeting. Answers come from the transcript and notes.")
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
                    TextField("Ask this meeting", text: $question, axis: .vertical)
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
            .navigationTitle("Ask This Meeting")
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
                let result = try await MeetingAsk.ask(q, history: history, meeting: meeting)
                store.addUsage(meeting.id, result.usage)
                turns.append(MeetingAsk.Turn(isUser: false, text: result.answer))
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}
