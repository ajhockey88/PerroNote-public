import SwiftUI

// MARK: - Holds, resolution and plain language, from the AI review

extension CallReview {
    /// One time the caller was asked to wait.
    struct HoldCheck: Codable, Hashable, Identifiable {
        var id = UUID()
        var start: Double
        var end: Double
        /// The agent asked or told the caller before going quiet.
        var asked: Bool
        /// The second the agent first checked back in during the wait.
        var checkedIn: Double?
        var thanked: Bool
        var suggestion: String?

        var length: Double { max(0, end - start) }
        /// How long the caller waited before hearing from the agent again.
        var firstWait: Double { (checkedIn ?? end) - start }

        static let checkInLimit = 60.0

        enum CheckIn { case notNeeded, onTime, late, never }

        var checkIn: CheckIn {
            if length <= Self.checkInLimit { return .notNeeded }
            guard checkedIn != nil else { return .never }
            return firstWait <= Self.checkInLimit ? .onTime : .late
        }

        var good: Bool { asked && thanked && (checkIn == .notNeeded || checkIn == .onTime) }
    }

    struct Resolution: Codable, Hashable {
        enum Result: String, Codable {
            case fixed, callback, escalated, notFixed = "not_fixed"

            var title: String {
                switch self {
                case .fixed: return "Fixed on this call"
                case .callback: return "Callback needed"
                case .escalated: return "Escalated"
                case .notFixed: return "Not fixed"
                }
            }

            var symbol: String {
                switch self {
                case .fixed: return "checkmark"
                case .callback: return "phone.arrow.up.right"
                case .escalated: return "arrow.up.forward"
                case .notFixed: return "xmark"
                }
            }

            var color: Color {
                switch self {
                case .fixed: return ReviewColors.green
                case .callback: return ReviewColors.orange
                case .escalated: return ReviewColors.holdText
                case .notFixed: return ReviewColors.red
                }
            }
        }

        var result: Result
        var detail: String
        var issueClear: Double?
        var causeFound: Double?
        var fixApplied: Double?
        var confirmed: Double?
        var repeatContact: Bool

        var stages: [(String, Double?)] {
            [("Issue clear", issueClear), ("Cause found", causeFound), ("Fix applied", fixApplied), ("Confirmed", confirmed)]
        }
    }

    struct PlainLanguage: Codable, Hashable {
        struct Term: Codable, Hashable, Identifiable {
            var id: String { term }
            var term: String
            var count: Int
            var explained: Bool
        }

        /// 1 (full of unexplained jargon) to 5 (plain throughout).
        var score: Int
        var terms: [Term]
        /// The worst jargon moment.
        var at: Double?
        var said: String?
        var better: String?
        var reaction: String?
    }
}

// MARK: - Small shared pieces

/// A pill with a mark in front, such as "✓ Asked first".
struct CheckChip: View {
    enum Kind { case good, warn, bad, info }
    let text: String
    let state: Kind

    private var color: Color {
        switch state {
        case .good: return Color(red: 0.12, green: 0.54, blue: 0.24)
        case .warn: return Color(red: 0.70, green: 0.42, blue: 0.0)
        case .bad: return ReviewColors.deadAirText
        case .info: return ReviewColors.holdText
        }
    }

    private var symbol: String? {
        switch state {
        case .good: return "checkmark"
        case .warn: return "exclamationmark"
        case .bad: return "xmark"
        case .info: return nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .heavy)) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

private struct PlayLink: View {
    let at: Double
    let play: (Double) -> Void

    var body: some View {
        Button { play(at) } label: {
            Label("Play", systemImage: "play.fill").font(.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Hold etiquette

struct HoldEtiquetteCard: View {
    let holds: [CallReview.HoldCheck]
    var play: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(holds.enumerated()), id: \.element.id) { i, h in
                if i > 0 { Divider().padding(.vertical, 11) }
                hold(i + 1, h)
            }
        }
    }

    private func hold(_ n: Int, _ h: CallReview.HoldCheck) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                (Text("Hold \(n) ").bold() + Text("at \(formatDuration(h.start)) \u{00B7} \(formatDuration(h.length)) long").foregroundColor(.secondary))
                    .font(.subheadline)
                Spacer()
                if let play { PlayLink(at: h.start, play: play) }
            }
            HoldBar(hold: h)
            FlowLayout(spacing: 6, rowSpacing: 6) {
                CheckChip(text: h.asked ? "Asked first" : "Not asked", state: h.asked ? .good : .bad)
                switch h.checkIn {
                case .notNeeded: CheckChip(text: "Under 60s", state: .good)
                case .onTime: CheckChip(text: "Checked in on time", state: .good)
                case .late: CheckChip(text: "Checked back late", state: .warn)
                case .never: CheckChip(text: "Never checked in", state: .bad)
                }
                CheckChip(text: h.thanked ? "Thanked caller" : "Not thanked", state: h.thanked ? .good : .bad)
            }
            if let s = h.suggestion, !h.good {
                Text("Try: \u{201C}\(s)\u{201D}").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// The wait as a bar: asked at the start, the check-in, thanked at the end, and the time past 60 seconds in orange.
private struct HoldBar: View {
    let hold: CallReview.HoldCheck

    var body: some View {
        let h = hold
        VStack(spacing: 3) {
            Canvas { ctx, size in
                let pad: Double = 8, w = Double(size.width) - 2 * pad, mid: Double = 10
                let len = max(h.length, 1)
                func x(_ seconds: Double) -> Double { pad + w * min(max(seconds, 0), len) / len }
                ctx.fill(Path(roundedRect: CGRect(x: pad, y: mid - 5, width: w, height: 10), cornerRadius: 5), with: .color(ReviewColors.hold))
                let limit = CallReview.HoldCheck.checkInLimit
                if h.length > limit {
                    let lateTo = min(h.firstWait, h.length)
                    if lateTo > limit {
                        ctx.fill(Path(CGRect(x: x(limit), y: mid - 5, width: x(lateTo) - x(limit), height: 10)), with: .color(ReviewColors.deadAir))
                    }
                    var dash = Path()
                    dash.move(to: CGPoint(x: x(limit), y: 0))
                    dash.addLine(to: CGPoint(x: x(limit), y: 20))
                    ctx.stroke(dash, with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                func mark(_ at: Double, _ ok: Bool?, _ symbol: String) {
                    let color = ok == nil ? ReviewColors.orange : (ok! ? ReviewColors.green : ReviewColors.red)
                    let c = CGPoint(x: at, y: mid)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(color))
                    ctx.draw(Text(Image(systemName: symbol)).font(.system(size: 7, weight: .heavy)).foregroundColor(.white), at: c)
                }
                mark(pad, h.asked, h.asked ? "checkmark" : "xmark")
                if let c = h.checkedIn, c > h.start, c < h.end {
                    let onTime = c - h.start <= limit
                    mark(x(c - h.start), onTime ? true : nil, onTime ? "checkmark" : "exclamationmark")
                }
                mark(pad + w, h.thanked, h.thanked ? "checkmark" : "xmark")
            }
            .frame(height: 20)
            HStack {
                Text("Asked")
                Spacer()
                if let c = h.checkedIn, c > h.start, c < h.end { Text("Checked in at \(Int(c - h.start))s"); Spacer() }
                else if h.length > CallReview.HoldCheck.checkInLimit { Text("No check-in by 60s"); Spacer() }
                Text("Thanked")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Interruptions

struct InterruptionsCard: View {
    let stats: CallTalkStats
    let note: String?

    /// Three or more cut-ins by the same person within a minute.
    private var clusters: [(Double, Double)] {
        var out: [(Double, Double)] = []
        for side in [true, false] {
            let times = stats.cutIns.filter { $0.byAgent == side }.map(\.at)
            var i = 0
            while i < times.count {
                var j = i
                while j + 1 < times.count && times[j + 1] - times[i] <= 60 { j += 1 }
                if j - i >= 2 { out.append((times[i], times[j])); i = j + 1 } else { i += 1 }
            }
        }
        return out
    }

    var body: some View {
        let agent = stats.cutIns.filter(\.byAgent).count
        let caller = stats.cutIns.count - agent
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 18) {
                count(agent, "Agent cut in", ReviewColors.agent)
                count(caller, "Caller cut in", ReviewColors.caller)
                Spacer()
            }
            Canvas { ctx, size in
                let w = Double(size.width), h = Double(size.height), d = max(stats.duration, 1), pad: Double = 6
                func x(_ t: Double) -> Double { pad + (w - 2 * pad) * t / d }
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Color.gray.opacity(0.08)))
                var line = Path()
                line.move(to: CGPoint(x: pad, y: h / 2))
                line.addLine(to: CGPoint(x: w - pad, y: h / 2))
                ctx.stroke(line, with: .color(Color.gray.opacity(0.35)), lineWidth: 1)
                for c in clusters {
                    let r = CGRect(x: x(c.0) - 8, y: 3, width: x(c.1) - x(c.0) + 16, height: h - 6)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(ReviewColors.deadAir), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                for c in stats.cutIns {
                    var t = Path()
                    let cx = x(c.at)
                    if c.byAgent {
                        t.move(to: CGPoint(x: cx, y: h / 2 - 2)); t.addLine(to: CGPoint(x: cx - 5, y: h / 2 - 13)); t.addLine(to: CGPoint(x: cx + 5, y: h / 2 - 13))
                    } else {
                        t.move(to: CGPoint(x: cx, y: h / 2 + 2)); t.addLine(to: CGPoint(x: cx - 5, y: h / 2 + 13)); t.addLine(to: CGPoint(x: cx + 5, y: h / 2 + 13))
                    }
                    t.closeSubpath()
                    ctx.fill(t, with: .color(c.byAgent ? ReviewColors.agent : ReviewColors.caller))
                }
            }
            .frame(height: 44)
            HStack {
                Text("0:00")
                Spacer()
                Text("\u{25BC}").foregroundColor(ReviewColors.agent) + Text(" agent cut in   ") + Text("\u{25B2}").foregroundColor(ReviewColors.caller) + Text(" caller cut in")
                Spacer()
                Text(formatDuration(stats.duration))
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if let note, !note.isEmpty {
                Text(note).font(.footnote)
            }
        }
    }

    private func count(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(.system(size: 24, weight: .heavy)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - First contact resolution

struct ResolutionCard: View {
    let resolution: CallReview.Resolution

    var body: some View {
        let r = resolution
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: r.result.symbol)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(r.result.color)
                    .frame(width: 52, height: 52)
                    .background(r.result.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.result.title).font(.headline)
                    if !r.detail.isEmpty { Text(r.detail).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            track(r)
            FlowLayout(spacing: 6, rowSpacing: 6) {
                CheckChip(text: r.result == .callback ? "Callback needed" : "No callback", state: r.result == .callback ? .warn : .good)
                CheckChip(text: r.result == .escalated ? "Escalated" : "No escalation", state: r.result == .escalated ? .info : .good)
                if r.repeatContact { CheckChip(text: "Caller had contacted before", state: .warn) }
            }
        }
    }

    private func track(_ r: CallReview.Resolution) -> some View {
        let stages = r.stages
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                VStack(spacing: 4) {
                    ZStack {
                        HStack(spacing: 0) {
                            Rectangle().fill(i == 0 ? Color.clear : (s.1 != nil && stages[i - 1].1 != nil ? ReviewColors.green : Color.gray.opacity(0.25)))
                            Rectangle().fill(i == stages.count - 1 ? Color.clear : (s.1 != nil && stages[i + 1].1 != nil ? ReviewColors.green : Color.gray.opacity(0.25)))
                        }
                        .frame(height: 3)
                        Circle().fill(s.1 != nil ? ReviewColors.green : Color.gray.opacity(0.3)).frame(width: 20, height: 20)
                        if i == stages.count - 1 && s.1 != nil {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        }
                    }
                    Text(s.0).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(s.1.map(formatDuration) ?? "\u{2014}").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Plain language

struct PlainLanguageCard: View {
    let plain: CallReview.PlainLanguage
    var play: ((Double) -> Void)? = nil

    private var scoreColor: Color { ReviewColors.rating(plain.score) }

    var body: some View {
        let p = plain
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Caller-friendly").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(p.score) / 5").font(.subheadline.weight(.heavy)).foregroundStyle(scoreColor)
            }
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Capsule().fill(i <= p.score ? scoreColor : Color.gray.opacity(0.2)).frame(height: 8)
                }
            }
            if p.terms.isEmpty {
                Text("No jargon: the agent kept it plain.").font(.footnote).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(p.terms) { t in
                        CheckChip(text: t.explained ? "\(t.term), explained" : (t.count > 1 ? "\(t.term) \u{00D7}\(t.count)" : t.term),
                                  state: t.explained ? .good : .bad)
                    }
                }
                HStack(spacing: 12) {
                    legend(ReviewColors.deadAirText, "Not explained")
                    legend(Color(red: 0.12, green: 0.54, blue: 0.24), "Explained to the caller")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let said = p.said {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let at = p.at { Text(formatDuration(at)).font(.footnote.weight(.bold).monospacedDigit()) }
                        Spacer()
                        if let play, let at = p.at { PlayLink(at: at, play: play) }
                    }
                    Text("Said: \u{201C}\(said)\u{201D}").font(.footnote).foregroundStyle(.secondary)
                    if let better = p.better { Text("Try: \u{201C}\(better)\u{201D}").font(.footnote) }
                    if let reaction = p.reaction {
                        Text("Caller: \u{201C}\(reaction)\u{201D}").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }
}
