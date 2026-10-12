import SwiftUI

/// What the action items banner on the meetings page counts. Set under Settings > Action items banner.
enum BannerSettings {
    static let showKey = "banner-show"
    static let peopleKey = "banner-people"
    static let dueKey = "banner-due"
    static let myNameKey = "my-name"
    /// Stands for you in the people list, matched against your name in Settings.
    static let me = "@me"

    enum Due: Int, CaseIterable, Identifiable {
        case all, thisWeek, today, overdue
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .all: return "All action items"
            case .thisWeek: return "Due this week"
            case .today: return "Due today"
            case .overdue: return "Overdue"
            }
        }
    }

    /// The people chosen, stored as one line each. Empty means everyone.
    static func people(from raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func raw(from people: [String]) -> String { people.joined(separator: "\n") }

    /// True when this owner is you: your full name, your first name, or "me".
    static func isMe(_ owner: String, myName: String) -> Bool {
        let name = myName.trimmingCharacters(in: .whitespaces)
        if owner.caseInsensitiveCompare("me") == .orderedSame { return true }
        guard !name.isEmpty else { return false }
        if owner.caseInsensitiveCompare(name) == .orderedSame { return true }
        if let first = name.split(separator: " ").first, owner.caseInsensitiveCompare(String(first)) == .orderedSame { return true }
        return false
    }

    static func matches(_ item: ActionItem, people: [String], myName: String) -> Bool {
        guard !people.isEmpty else { return true }
        return actionOwners(item).contains { owner in
            people.contains { p in
                p == me ? isMe(owner, myName: myName) : owner.caseInsensitiveCompare(p) == .orderedSame
            }
        }
    }

    static func matches(_ item: ActionItem, due: Due, now: Date = Date()) -> Bool {
        guard due != .all else { return true }
        guard let date = item.dueDate else { return false }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        switch due {
        case .all: return true
        case .overdue: return date < today
        case .today: return date < cal.date(byAdding: .day, value: 1, to: today)!
        case .thisWeek:
            let end = cal.dateInterval(of: .weekOfYear, for: today)?.end ?? today
            return date < end
        }
    }
}

extension ActionItem {
    /// The day it's due, read from the full date the app writes into due dates ("Fri, Oct 17, 2026").
    var dueDate: Date? {
        guard let due, let range = due.range(of: #"[A-Z][a-z]{2}, [A-Z][a-z]{2} \d{1,2}, \d{4}"#, options: .regularExpression) else {
            return nil
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy"
        guard let date = f.date(from: String(due[range])) else { return nil }
        // "week of Mon, Oct 13" counts as due by the end of that week.
        if due.lowercased().contains("week of") {
            return Calendar.current.date(byAdding: .day, value: 4, to: date)
        }
        return date
    }
}

/// The card at the top of the meetings page: how many action items are open, who owes them, and progress.
struct ActionBanner: View {
    @EnvironmentObject private var store: MeetingStore
    @AppStorage(BannerSettings.peopleKey) private var peopleRaw = ""
    @AppStorage(BannerSettings.dueKey) private var dueRaw = BannerSettings.Due.all.rawValue
    @AppStorage(BannerSettings.myNameKey) private var myName = ""
    var open: () -> Void

    private var due: BannerSettings.Due { BannerSettings.Due(rawValue: dueRaw) ?? .all }

    private var items: [ActionItem] {
        let people = BannerSettings.people(from: peopleRaw)
        return store.meetings.flatMap { $0.notes?.actionItems ?? [] }.filter { item in
            !item.task.isEmpty
                && BannerSettings.matches(item, people: people, myName: myName)
                && BannerSettings.matches(item, due: due)
        }
    }

    /// Whether there is anything to show at all.
    static func hasItems(_ store: MeetingStore) -> Bool {
        store.meetings.contains { !($0.notes?.actionItems ?? []).isEmpty }
    }

    var body: some View {
        let all = items
        let openItems = all.filter { !$0.done }
        let done = all.count - openItems.count
        let progress = all.isEmpty ? 1 : Double(done) / Double(all.count)
        var seen = Set<String>()
        let owners = openItems.flatMap(actionOwners).filter { seen.insert($0.lowercased()).inserted }

        Button(action: open) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 5)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(openItems.count)")
                        .font(.headline.weight(.heavy))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(openItems.isEmpty ? "All caught up"
                         : "\(openItems.count) action item\(openItems.count == 1 ? "" : "s") open")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle(done: done, total: all.count))
                        .font(.caption)
                        .opacity(0.9)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: -7) {
                    ForEach(owners.prefix(3), id: \.self) { name in
                        Text(initials(name))
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(color(name), in: Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    }
                }
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                LinearGradient(colors: [Color(red: 0.24, green: 0.35, blue: 1.0), Color(red: 0.48, green: 0.36, blue: 1.0)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color(red: 0.24, green: 0.35, blue: 1.0).opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(openItems.count) action items open. Opens the action items.")
    }

    private func subtitle(done: Int, total: Int) -> String {
        let scope: String
        switch due {
        case .all: scope = ""
        case .thisWeek: scope = " \u{00B7} due this week"
        case .today: scope = " \u{00B7} due today"
        case .overdue: scope = " \u{00B7} overdue"
        }
        if total == 0 { return "Nothing here" + scope }
        return "\(done) of \(total) done" + scope
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private func color(_ name: String) -> Color {
        let palette: [Color] = [.indigo, .orange, .blue, .teal, .pink, .purple, .green]
        return palette[abs(name.hashValue) % palette.count]
    }
}

/// Settings > Action items banner > People: everyone, you, or any mix of names.
struct BannerPeopleView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var peopleStore: PeopleStore
    @AppStorage(BannerSettings.peopleKey) private var peopleRaw = ""
    @AppStorage(BannerSettings.myNameKey) private var myName = ""

    private var chosen: [String] { BannerSettings.people(from: peopleRaw) }

    private var names: [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ name: String) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !MeetingNotes.isSpeakerLabel(clean), !BannerSettings.isMe(clean, myName: myName),
                  seen.insert(clean.lowercased()).inserted else { return }
            out.append(clean)
        }
        peopleStore.people.forEach { add($0.name) }
        for m in store.meetings { (m.notes?.actionItems ?? []).flatMap(actionOwners).forEach(add) }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func toggle(_ value: String) {
        var c = chosen
        if let i = c.firstIndex(of: value) { c.remove(at: i) } else { c.append(value) }
        peopleRaw = BannerSettings.raw(from: c)
    }

    var body: some View {
        Form {
            Section {
                row(Text("Everyone").bold(), on: chosen.isEmpty) { peopleRaw = "" }
                row(Text(myName.isEmpty ? "Me" : "Me (\(myName))"), on: chosen.contains(BannerSettings.me)) {
                    toggle(BannerSettings.me)
                }
            } footer: {
                if myName.isEmpty {
                    Text("Add your name under Action items banner in Settings so the app knows which items are yours.")
                }
            }
            if !names.isEmpty {
                Section("People") {
                    ForEach(names, id: \.self) { name in
                        row(Text(name), on: chosen.contains(name)) { toggle(name) }
                    }
                }
            }
        }
        .navigationTitle("Whose items")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: Text, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                label.foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }
}
