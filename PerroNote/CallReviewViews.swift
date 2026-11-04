import SwiftUI
import Charts

// MARK: - Shared pieces (also drawn into the Word report)

extension CallReview.Level {
    var color: Color {
        switch self {
        case .good: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .fair: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .poor: return Color(red: 1.0, green: 0.23, blue: 0.19)
        }
    }
}

enum ReviewColors {
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let red = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let agent = Color(red: 0.36, green: 0.36, blue: 0.84)
    static let caller = Color(red: 0.90, green: 0.28, blue: 0.30)

    static func step(_ r: CallReview.StepResult) -> Color {
        switch r {
        case .pass: return green
        case .partial: return orange
        case .missed: return red
        case .notApplicable: return .gray
        }
    }

    static func moment(_ k: CallReview.MomentKind) -> Color {
        switch k {
        case .good: return green
        case .frustration: return red
        default: return orange
        }
    }

    static func rating(_ score: Int) -> Color { score >= 4 ? green : score == 3 ? Color(red: 0.98, green: 0.78, blue: 0.1) : orange }
}

struct ScoreRing: View {
    let review: CallReview
    var size: CGFloat = 74

    var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.18), lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: CGFloat(review.score) / 100)
                .stroke(review.level.color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(review.score)").font(.system(size: size * 0.3, weight: .bold)).monospacedDigit()
                Text("of 100").font(.system(size: size * 0.11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .padding(size * 0.06)
    }
}

struct ReviewPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// The score with the verdict, as on the Review tab.
struct ReviewHeadline: View {
    let review: CallReview

    var body: some View {
        HStack(spacing: 14) {
            ScoreRing(review: review)
            VStack(alignment: .leading, spacing: 5) {
                Text(review.verdict).font(.headline)
                if !review.summary.isEmpty {
                    Text(review.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 5) {
                    ReviewPill(text: review.outcome.title, color: review.outcome == .resolved ? ReviewColors.green : ReviewColors.orange)
                    if !review.missedSteps.isEmpty {
                        ReviewPill(text: "\(review.missedSteps.count) step\(review.missedSteps.count == 1 ? "" : "s") missed", color: ReviewColors.red)
                    }
                    if !review.missedGuidelines.isEmpty {
                        ReviewPill(text: "\(review.missedGuidelines.count) guideline\(review.missedGuidelines.count == 1 ? "" : "s") missed", color: ReviewColors.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The score and three tiles, drawn into the Word report.
struct ReviewScoreTiles: View {
    let review: CallReview

    private func tile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 19, weight: .bold)).foregroundStyle(color.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
    }

    var body: some View {
        HStack(spacing: 18) {
            ScoreRing(review: review, size: 104)
            VStack(alignment: .leading, spacing: 8) {
                Text(review.verdict).font(.system(size: 20, weight: .bold))
                HStack(spacing: 10) {
                    tile("OUTCOME", review.outcome.title, review.outcome == .resolved ? ReviewColors.green : ReviewColors.orange)
                    tile("STEPS MISSED", "\(review.missedSteps.count) of \(review.steps.filter { $0.result != .notApplicable }.count)",
                         review.missedSteps.isEmpty ? ReviewColors.green : ReviewColors.red)
                    tile("FLAGS", review.flagSummary, review.flags.isEmpty ? ReviewColors.green : ReviewColors.orange)
                }
            }
        }
        .padding(16)
        .background(Color.white)
    }
}

struct HandlingBars: View {
    let review: CallReview
    var big = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: big ? 12 : 9) {
            ForEach(review.handling) { r in
                GridRow {
                    Text(r.area).font(big ? .system(size: 15) : .subheadline)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.gray.opacity(0.15))
                            Capsule().fill(ReviewColors.rating(r.score))
                                .frame(width: g.size.width * CGFloat(r.score) / 5)
                        }
                    }
                    .frame(height: big ? 12 : 7)
                    Text("\(r.score)/5").font((big ? Font.system(size: 15) : .subheadline).weight(.bold)).monospacedDigit()
                }
            }
        }
    }
}

struct MoodChart: View {
    let review: CallReview
    let duration: Double
    var big = false

    private struct Point: Identifiable {
        let id = UUID()
        let at: Double
        let level: Double
        let who: String
    }

    private static func moodName(_ n: Double) -> String { n >= 5 ? "Calm" : n <= 1 ? "Tense" : "" }

    private var points: [Point] {
        review.mood.flatMap { [Point(at: $0.at, level: $0.agent, who: "Agent"), Point(at: $0.at, level: $0.caller, who: "Caller")] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.at), y: .value("Mood", p.level))
                        .foregroundStyle(by: .value("Who", p.who))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: big ? 3 : 2.5))
                }
                ForEach(review.moments.filter { $0.at != nil }) { m in
                    RuleMark(x: .value("Time", m.at ?? 0))
                        .foregroundStyle(ReviewColors.moment(m.kind).opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(["Agent": ReviewColors.agent, "Caller": ReviewColors.caller])
            .chartYScale(domain: 1...5)
            .chartXScale(domain: 0...max(duration, review.mood.last?.at ?? 1, 1))
            .chartYAxis {
                AxisMarks(values: [1.0, 3.0, 5.0]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(Self.moodName(v.as(Double.self) ?? 0)) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisValueLabel { Text(formatDuration(v.as(Double.self) ?? 0)) }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: big ? 170 : 130)
            Text("Read from words and pacing, not tone of voice")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - The Review tab

struct CallReviewTab: View {
    let id: UUID
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject private var store: MeetingStore
    @State private var playingKey: String?
    @State private var sharing = false
    @State private var editingInfo = false
    @State private var agentText = ""
    @State private var ticketText = ""

    var body: some View {
        if let meeting = store.meeting(id) {
            VStack(alignment: .leading, spacing: 16) {
                if store.reviewing.contains(id) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reviewing the call against your process\u{2026}").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                if let error = store.reviewErrors[id] {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
                }
                if let review = meeting.callReview {
                    content(meeting, review)
                } else if !store.reviewing.contains(id) {
                    empty(meeting)
                }
            }
            .sheet(isPresented: $sharing) { CallReviewShareView(id: id) }
            .alert("Agent and ticket", isPresented: $editingInfo) {
                TextField("Agent name", text: $agentText).textInputAutocapitalization(.words)
                TextField("Ticket or incident number", text: $ticketText).textInputAutocapitalization(.characters)
                Button("Save") {
                    let a = agentText.trimmingCharacters(in: .whitespaces), t = ticketText.trimmingCharacters(in: .whitespaces)
                    store.update(id) {
                        $0.callReview?.agentName = a.isEmpty ? nil : a
                        $0.callReview?.ticket = t.isEmpty ? nil : t
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shown at the top of the review and the Word report.")
            }
        }
    }

    private func empty(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review this call").font(.headline)
            Text("Checks the call against your process in Settings > Call review, rates how it was handled and flags moments worth a listen. Uses the transcript only.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                Task { await store.reviewCall(id) }
            } label: {
                Label("Review call", systemImage: "checklist").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled((meeting.transcript ?? "").isEmpty || meeting.isBusy)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func card<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        body()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func content(_ meeting: Meeting, _ review: CallReview) -> some View {
        Button {
            agentText = review.agentName ?? ""
            ticketText = review.ticket ?? ""
            editingInfo = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle")
                Text(review.callerInfo ?? "Add agent and ticket").lineLimit(1)
                Image(systemName: "pencil").font(.caption)
            }
            .font(.subheadline)
            .foregroundStyle(review.callerInfo == nil ? Color.secondary : Color.primary)
        }
        .buttonStyle(.plain)
        card { ReviewHeadline(review: review) }

        Button { sharing = true } label: {
            Label("Email or share the Word report", systemImage: "doc.richtext")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.bordered)

        header("Process \u{00B7} \(review.processName)")
        card {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(review.steps.enumerated()), id: \.element.id) { i, step in
                    if i > 0 { Divider().padding(.vertical, 7) }
                    HStack(alignment: .top, spacing: 10) {
                        stepIcon(step.result)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.name).fontWeight(step.result == .missed ? .bold : .regular)
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        playButton(meeting, at: step.at, key: "s:\(step.id)")
                    }
                }
            }
        }

        if let checks = review.guidelines, !checks.isEmpty {
            header("Reference documents \u{00B7} \(checks.count) checked")
            card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().padding(.vertical, 7) }
                        HStack(alignment: .top, spacing: 10) {
                            stepIcon(c.result)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.requirement).fontWeight(c.result == .missed ? .bold : .regular)
                                if !c.detail.isEmpty {
                                    Text(c.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                                if !c.source.isEmpty {
                                    Label(c.source, systemImage: "doc.text").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            playButton(meeting, at: c.at, key: "g:\(c.id)")
                        }
                    }
                }
            }
        }

        if !review.handling.isEmpty {
            header("Call handling")
            card { HandlingBars(review: review) }
        }

        if let stats = CallTalkStats.measure(meeting, review: review) {
            header("Talk time and dead air")
            card { TalkTimeChart(stats: stats) }
            if !stats.deadAir.isEmpty {
                header("Dead air \u{00B7} \(stats.deadAir.count) moment\(stats.deadAir.count == 1 ? "" : "s")")
                card {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(stats.ordered.enumerated()), id: \.element.id) { i, g in
                            if i > 0 { Divider().padding(.vertical, 9) }
                            HStack(alignment: .top, spacing: 10) {
                                Text(formatDuration(g.start)).font(.footnote.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Color.accentColor).frame(width: 40, alignment: .leading).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        ReviewPill(text: g.title, color: ReviewColors.deadAir(g))
                                        Text("\(Int(g.length.rounded()))s").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                    }
                                    if let note = g.note {
                                        if !note.reason.isEmpty { Text(note.reason).font(.footnote) }
                                        if let quote = note.quote {
                                            Text("\u{201C}\(quote)\u{201D}").font(.footnote).foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text("Tap Review again to see why it went quiet.").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                playButton(meeting, at: g.start, key: "d:\(g.start)", label: true)
                            }
                        }
                    }
                }
            }
        }

        if review.mood.count > 1 {
            header("Mood over the call")
            card { MoodChart(review: review, duration: meeting.duration) }
        }

        if !review.moments.isEmpty {
            header("Flagged moments \u{00B7} \(review.moments.count)")
            ForEach(review.moments) { m in
                card {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            if let at = m.at {
                                Text(formatDuration(at)).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Color.accentColor)
                            }
                            ReviewPill(text: m.label, color: ReviewColors.moment(m.kind))
                            Spacer()
                            playButton(meeting, at: m.at, key: "m:\(m.id)", label: true)
                        }
                        (Text(m.speaker == "agent" ? "Agent: " : "Caller: ").bold() + Text("\u{201C}\(m.quote)\u{201D}"))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
                        if !m.note.isEmpty {
                            Text(m.note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        if !review.coaching.isEmpty {
            header("Coaching points")
            card { bulletList(review.coaching) }
        }
        if !review.painPoints.isEmpty {
            header("Caller pain points")
            card { bulletList(review.painPoints) }
        }

        Button {
            Task { await store.reviewCall(id) }
        } label: {
            Label("Review again", systemImage: "arrow.clockwise").font(.footnote)
        }
        .foregroundStyle(.secondary)
        .disabled(store.reviewing.contains(id))
        Text("Reviewed from the transcript only. Check flagged moments against the recording before acting on them.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}").foregroundStyle(.secondary)
                    Text(t).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func stepIcon(_ r: CallReview.StepResult) -> some View {
        let symbol: String
        switch r {
        case .pass: symbol = "checkmark"
        case .missed: symbol = "xmark"
        case .partial: symbol = "minus"
        case .notApplicable: symbol = "circle.dashed"
        }
        return Image(systemName: symbol)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(ReviewColors.step(r), in: Circle())
            .padding(.top, 1)
    }

    @ViewBuilder
    private func playButton(_ meeting: Meeting, at: Double?, key: String, label: Bool = false) -> some View {
        if let at {
            let active = playingKey == key && player.isPlaying
            Button {
                if active { player.pause() } else {
                    playingKey = key
                    player.play(url: MeetingStore.audioURL(for: meeting.audioFile), from: max(0, at - 1))
                }
            } label: {
                if label {
                    Label(active ? "Pause" : "Play", systemImage: active ? "pause.fill" : "play.fill")
                        .font(.footnote.weight(.semibold))
                } else {
                    Text(formatDuration(at)).font(.footnote.weight(.semibold).monospacedDigit())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(meeting.audioFile.isEmpty)
        } else if !label {
            Text("\u{2014}").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Emailing the Word report

struct CallReviewShareView: View {
    let id: UUID
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var sections = Set(CallReviewDocx.Section.allCases.filter { $0 != .transcript })
    @State private var recipient: OutlookAccount?
    @State private var customEmail = ""
    @State private var sending = false
    @State private var error: String?
    @State private var sent = false
    @State private var share: ShareItems?

    private var accounts: [OutlookAccount] { OutlookSettings.accounts }

    var body: some View {
        NavigationStack {
            Form {
                if let meeting = store.meeting(id), let review = meeting.callReview {
                    Section {
                        HStack(spacing: 12) {
                            Text("W").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: 40, height: 48)
                                .background(Color(red: 0.09, green: 0.35, blue: 0.74), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CallReviewDocx.fileName(for: meeting)).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text("Score \(review.score) \u{00B7} \(review.verdict)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(CallReviewDocx.Section.allCases, id: \.self) { s in
                            Toggle(s.title, isOn: Binding(
                                get: { sections.contains(s) },
                                set: { on in if on { sections.insert(s) } else { sections.remove(s) } }))
                        }
                    } header: {
                        Text("What goes in")
                    }

                    Section {
                        Picker("To", selection: $recipient) {
                            Text("Choose").tag(OutlookAccount?.none)
                            ForEach(accounts) { a in Text(a.name).tag(OutlookAccount?.some(a)) }
                            Text("Other address").tag(OutlookAccount?.some(OutlookAccount(id: Self.otherID, name: "Other", email: "")))
                        }
                        if recipient?.id == Self.otherID {
                            TextField("name@example.com", text: $customEmail)
                                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        LabeledContent("Subject") {
                            Text(CallReviewExport.subject(meeting, review)).font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        Button {
                            send(meeting, review)
                        } label: {
                            Label(sending ? "Sending\u{2026}" : "Email Word report", systemImage: "envelope.fill")
                                .font(.headline).frame(maxWidth: .infinity)
                        }
                        .disabled(sending || target == nil || sections.isEmpty)
                    } header: {
                        Text("Email")
                    } footer: {
                        if !MailSettings.isConfigured {
                            Text("Add your Gmail address and app password under Send to Outlook in Settings first.")
                        } else if sent {
                            Text("Sent.").foregroundStyle(.green)
                        }
                    }

                    Section {
                        Button {
                            if let url = file(meeting, review) { share = ShareItems(items: [url]) }
                        } label: {
                            Label("Save to Files or share\u{2026}", systemImage: "square.and.arrow.up")
                        }
                        .disabled(sections.isEmpty)
                    }
                }
            }
            .navigationTitle("Share call review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Could not send", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .sheet(item: $share) { ShareSheet(items: $0.items).ignoresSafeArea() }
            .onAppear { if recipient == nil { recipient = accounts.first } }
        }
    }

    private static let otherID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    private var target: OutlookAccount? {
        guard let r = recipient else { return nil }
        if r.id == Self.otherID {
            let e = customEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = OutlookAccount(name: e, email: e)
            return a.isValid ? a : nil
        }
        return r
    }

    private func file(_ meeting: Meeting, _ review: CallReview) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(CallReviewDocx.fileName(for: meeting))
        do {
            try CallReviewDocx.data(for: meeting, review: review, sections: sections).write(to: url, options: .atomic)
            return url
        } catch {
            self.error = "The Word report could not be created."
            return nil
        }
    }

    private func send(_ meeting: Meeting, _ review: CallReview) {
        guard let to = target else { return }
        guard MailSettings.isConfigured else { error = "Add your Gmail address and app password under Send to Outlook in Settings first."; return }
        let attachment = GmailMailer.Attachment(
            name: CallReviewDocx.fileName(for: meeting), mimeType: MeetingDocx.mimeType,
            data: CallReviewDocx.data(for: meeting, review: review, sections: sections))
        let credentials = GmailMailer.Credentials(address: MailSettings.address, appPassword: MailSettings.appPassword)
        let subject = CallReviewExport.subject(meeting, review)
        let html = CallReviewExport.html(meeting, review)
        let plain = CallReviewExport.plain(meeting, review)
        sending = true
        sent = false
        Task {
            do {
                try await GmailMailer.send(from: credentials, to: to, subject: subject, html: html, plain: plain, attachment: attachment)
                sent = true
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
