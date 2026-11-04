import SwiftUI

// MARK: - Why a silence happened, from the AI review

extension CallReview {
    /// The reviewer's read on one long silence that the phone measured.
    struct DeadAirNote: Codable, Hashable {
        enum Kind: String, Codable {
            /// The agent told the caller they would be waiting.
            case hold
            /// The caller was busy doing something they were asked to do.
            case caller
            /// Nobody said why.
            case unexplained
        }

        /// The second the silence starts, as given to the reviewer.
        var at: Double
        var kind: Kind
        var reason: String
        var quote: String?
    }
}

// MARK: - Measured on the phone

/// Who talked how much and where the call went quiet, measured from the transcript's word timings.
/// Nothing here comes from the AI; the review only adds the reasons for each long silence.
struct CallTalkStats {
    enum Who { case agent, caller, anyone }

    struct Speech {
        var start: Double
        var end: Double
        var who: Who
    }

    struct DeadAir: Identifiable {
        var start: Double
        var end: Double
        var note: CallReview.DeadAirNote?
        var id: Double { start }
        var length: Double { end - start }

        /// True when the caller was told, or was busy with something they were asked to do.
        var explained: Bool { note?.kind == .hold || note?.kind == .caller }

        var title: String {
            switch note?.kind {
            case .hold: return "Hold, caller told"
            case .caller: return "Waiting on caller"
            case .unexplained: return "Unexplained silence"
            case nil: return "Silence"
            }
        }
    }

    var duration: Double
    var speech: [Speech]
    var deadAir: [DeadAir]
    var threshold: Double
    /// True when the agent's voice is known, so talk time splits into agent and caller.
    var split: Bool
    var agentTalk: Double
    var callerTalk: Double

    var talk: Double { agentTalk + callerTalk }
    var silence: Double { max(0, duration - talk) }
    var longest: Double { deadAir.map(\.length).max() ?? 0 }

    func percent(_ seconds: Double) -> Int { duration > 0 ? Int((100 * seconds / duration).rounded()) : 0 }

    /// The silences to look at first: unexplained ones, then the rest, each in call order.
    var ordered: [DeadAir] {
        deadAir.filter { !$0.explained } + deadAir.filter(\.explained)
    }

    /// Pauses shorter than this inside a stretch of speech still count as talking.
    static let pause = 1.2

    static func limit(_ settings: CallReviewSettingsData = CallReviewSettings.current) -> Double {
        Double(settings.deadAirLimit)
    }

    static func measure(_ meeting: Meeting, review: CallReview? = nil, threshold: Double = limit()) -> CallTalkStats? {
        let pieces = (meeting.timeline?.isEmpty == false ? meeting.timeline : meeting.lines) ?? []
        let spoken = pieces.filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.start < $1.start }
        guard !spoken.isEmpty else { return nil }

        let agent = review?.agentSpeaker
        let turns = meeting.hasVoices ? (meeting.lines ?? []) : []
        let split = agent != nil && !turns.isEmpty

        // Timeline pieces carry no voice, so each takes the voice of the turn it overlaps most.
        func speaker(of piece: TranscriptLine) -> String? {
            if let s = piece.speaker { return s }
            var best: (String?, Double) = (nil, 0)
            for t in turns where t.end > piece.start && t.start < piece.end {
                let overlap = min(t.end, piece.end) - max(t.start, piece.start)
                if overlap > best.1 { best = (t.speaker, overlap) }
            }
            return best.0
        }

        var speech: [Speech] = []
        var agentTalk = 0.0, callerTalk = 0.0
        var lastEnd: Double?
        var gaps: [DeadAir] = []
        for piece in spoken {
            let who: Who = split ? (speaker(of: piece) == agent ? .agent : .caller) : .anyone
            // Pieces can overlap when two people talk at once; only count new time.
            let from = max(piece.start, lastEnd ?? piece.start)
            let length = max(0, piece.end - from)
            if who == .agent { agentTalk += length } else { callerTalk += length }
            speech.append(Speech(start: piece.start, end: piece.end, who: who))
            if let lastEnd, piece.start - lastEnd >= threshold {
                gaps.append(DeadAir(start: lastEnd, end: piece.start))
            }
            lastEnd = max(lastEnd ?? piece.end, piece.end)
        }

        // Each silence takes the reviewer's note given for it, if there is one.
        let notes = review?.deadAir ?? []
        for i in gaps.indices {
            let g = gaps[i]
            gaps[i].note = notes
                .filter { abs($0.at - g.start) <= max(8, g.length) }
                .min { abs($0.at - g.start) < abs($1.at - g.start) }
        }

        let duration = max(meeting.duration, lastEnd ?? 0)
        return CallTalkStats(duration: duration, speech: speech, deadAir: gaps, threshold: threshold,
                             split: split, agentTalk: agentTalk, callerTalk: callerTalk)
    }
}

extension ReviewColors {
    static let deadAir = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let hold = Color(red: 0.62, green: 0.70, blue: 0.96)
    static let silence = Color(red: 0.78, green: 0.78, blue: 0.80)
    static let talk = Color(red: 0.36, green: 0.36, blue: 0.84)
    static let holdText = Color(red: 0.25, green: 0.35, blue: 0.88)
    static let deadAirText = Color(red: 0.85, green: 0.28, blue: 0.06)

    static func deadAir(_ d: CallTalkStats.DeadAir) -> Color { d.explained ? holdText : deadAirText }
}

// MARK: - The chart

/// Tiles, a talk split bar and a timeline of who spoke when, with the long silences marked.
/// Shown on the Review tab and drawn into the Word report.
struct TalkTimeChart: View {
    let stats: CallTalkStats
    var big = false

    private func tile(_ value: String, _ label: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: big ? 22 : 19, weight: .bold)).monospacedDigit()
                .foregroundStyle(warn ? ReviewColors.deadAirText : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: big ? 12 : 11)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }

    var body: some View {
        let s = stats
        let anyDeadAir = !s.deadAir.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if s.split {
                    tile("\(s.percent(s.agentTalk)) / \(s.percent(s.callerTalk))", "Agent / caller talk %", warn: false)
                } else {
                    tile("\(s.percent(s.talk))%", "Talk time", warn: false)
                }
                tile(formatDuration(s.silence), "Silence (\(s.percent(s.silence))%)", warn: anyDeadAir)
                tile(anyDeadAir ? formatDuration(s.longest) : "None", "Longest dead air", warn: anyDeadAir)
            }

            // The talk split, adding up to the whole call.
            Canvas { ctx, size in
                ctx.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
                var x = 0.0
                let parts: [(Double, Color)] = s.split
                    ? [(s.agentTalk, ReviewColors.agent), (s.callerTalk, ReviewColors.caller), (s.silence, ReviewColors.silence)]
                    : [(s.talk, ReviewColors.talk), (s.silence, ReviewColors.silence)]
                for (seconds, color) in parts {
                    let w = s.duration > 0 ? size.width * seconds / s.duration : 0
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(color))
                    x += w
                }
            }
            .frame(height: 10)

            // Who spoke when: agent on top, caller below, long silences across both.
            Canvas { ctx, size in
                let w = size.width, h = size.height, d = max(s.duration, 1)
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Color.gray.opacity(0.08)))
                for g in s.deadAir {
                    let rect = CGRect(x: w * g.start / d, y: 4, width: max(1, w * g.length / d), height: h - 8)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(g.explained ? ReviewColors.hold : ReviewColors.deadAir))
                }
                let lane = (h - 30) / 2
                for p in s.speech {
                    let y: Double
                    let color: Color
                    switch p.who {
                    case .agent: y = 8; color = ReviewColors.agent
                    case .caller: y = h - 8 - lane; color = ReviewColors.caller
                    case .anyone: y = (h - lane) / 2; color = ReviewColors.talk
                    }
                    let rect = CGRect(x: w * p.start / d, y: y, width: max(0.8, w * (p.end - p.start) / d - 0.4), height: lane)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                }
            }
            .frame(height: big ? 76 : 62)

            HStack {
                Text("0:00")
                Spacer()
                Text(formatDuration(s.duration / 2))
                Spacer()
                Text(formatDuration(s.duration))
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if s.split {
                    legend(ReviewColors.agent, "Agent")
                    legend(ReviewColors.caller, "Caller")
                } else {
                    legend(ReviewColors.talk, "Talking")
                }
                legend(ReviewColors.deadAir, "Dead air \(Int(s.threshold))s+")
                if s.deadAir.contains(where: \.explained) { legend(ReviewColors.hold, "Hold, caller told") }
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}
