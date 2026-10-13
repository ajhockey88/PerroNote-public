import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct ActionItemsEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has shared its action items (or when the App Group is missing).
    let snapshot: WidgetSnapshot?
}

struct ActionItemsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActionItemsEntry {
        WidgetStore.log("placeholder \(context.family)")
        return ActionItemsEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (ActionItemsEntry) -> Void) {
        let saved = WidgetStore.readSnapshot()
        WidgetStore.log("snapshot \(context.family) preview=\(context.isPreview) items=\(saved?.items.count ?? -1)")
        completion(ActionItemsEntry(date: Date(), snapshot: context.isPreview && (saved?.open.isEmpty ?? true) ? WidgetSnapshot.sample : saved))
    }

    /// Redrawn at midnight so items move from Tomorrow to Today to Overdue on their own.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ActionItemsEntry>) -> Void) {
        let now = Date()
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let snapshot = WidgetStore.readSnapshot()
        WidgetStore.log("timeline \(context.family) items=\(snapshot?.items.count ?? -1)")
        completion(Timeline(entries: [ActionItemsEntry(date: now, snapshot: snapshot),
                                      ActionItemsEntry(date: midnight, snapshot: snapshot)],
                            policy: .after(midnight)))
    }
}

extension WidgetSnapshot {
    static var sample: WidgetSnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
        return WidgetSnapshot(items: [
            WidgetItem(id: "1", task: "Send revised SOW to Amy", due: day(-2)),
            WidgetItem(id: "2", task: "Confirm Brightline pricing", due: day(0)),
            WidgetItem(id: "3", task: "Book follow-up with Charles", due: day(0)),
            WidgetItem(id: "4", task: "Share deck with Morgan", due: day(1)),
            WidgetItem(id: "5", task: "Draft Q4 rollout plan", due: day(4)),
        ])
    }
}

/// The Large Home Screen widget plus the Lock Screen count, next item and inline line.
struct ActionItemsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.actionsKind, provider: ActionItemsProvider()) { entry in
            ActionItemsWidgetView(entry: entry)
        }
        .configurationDisplayName("Action Items")
        .description("Your open action items. Tick them off right on the widget.")
        .supportedFamilies([.systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ActionItemsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ActionItemsEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: OpenCountCircle(entry: entry)
            case .accessoryRectangular: NextDueCard(entry: entry)
            case .accessoryInline: InlineCount(entry: entry)
            default: LargeActionItems(entry: entry)
            }
        }
        .widgetURL(URL(string: "perronote://actions"))
        .containerBackground(for: .widget) {
            if family == .systemLarge { Color(.systemBackground) } else { Color.clear }
        }
    }
}

// MARK: - Large

enum DueGroup: CaseIterable {
    case overdue, today, tomorrow, later

    var title: String {
        switch self {
        case .overdue: return "OVERDUE"
        case .today: return "TODAY"
        case .tomorrow: return "TOMORROW"
        case .later: return "LATER"
        }
    }

    var color: Color {
        switch self {
        case .overdue: return .red
        case .today: return .orange
        case .tomorrow: return .blue
        case .later: return .secondary
        }
    }

    static func of(_ item: WidgetItem, now: Date) -> DueGroup {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let due = item.due else { return .later }
        let day = cal.startOfDay(for: due)
        if day < today { return .overdue }
        if day == today { return .today }
        if day == cal.date(byAdding: .day, value: 1, to: today) { return .tomorrow }
        return .later
    }
}

struct LargeActionItems: View {
    let entry: ActionItemsEntry

    struct Section: Identifiable {
        let group: DueGroup
        let items: [WidgetItem]
        var id: String { group.title }
    }
    /// Room for this many lines (headings and rows) between the header and the Record button.
    private let lineBudget = 9

    var body: some View {
        let _ = WidgetStore.log("draw large items=\(entry.snapshot?.items.count ?? -1)")
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)
            if let snapshot = entry.snapshot {
                if snapshot.items.isEmpty {
                    message("All caught up", "No open action items.")
                } else {
                    groups(snapshot)
                }
            } else {
                message("Open PerroNote", "Your action items show up here after you open the app.")
                Text(WidgetStore.groupStatus)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
            }
            Spacer(minLength: 6)
            Link(destination: URL(string: "perronote://record")!) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                    Text("Record a meeting")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(hex: 0xE5413A)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0xFF7A45)))
            Text("My action items")
                .font(.headline)
            Spacer()
            if let snapshot = entry.snapshot {
                Text("\(snapshot.open.count) open")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func groups(_ snapshot: WidgetSnapshot) -> some View {
        let shown = layout(snapshot)
        let _ = WidgetStore.log("rows \(shown.map { "\($0.id)=\($0.items.count)" }.joined(separator: ","))")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { section in
                Text(section.group.title)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(section.group.color)
                    .padding(.top, section.id == shown.first?.id ? 0 : 4)
                ForEach(section.items) { item in row(item, group: section.group) }
            }
            let hidden = snapshot.items.count - shown.reduce(0) { $0 + $1.items.count }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    /// Fills the groups in order until the lines run out.
    private func layout(_ snapshot: WidgetSnapshot) -> [Section] {
        var lines = lineBudget
        var out: [Section] = []
        for group in DueGroup.allCases {
            let items = snapshot.items.filter { DueGroup.of($0, now: entry.date) == group }
            guard !items.isEmpty, lines >= 2 else { continue }
            let take = Array(items.prefix(lines - 1))
            out.append(Section(group: group, items: take))
            lines -= take.count + 1
        }
        return out
    }

    private func row(_ item: WidgetItem, group: DueGroup) -> some View {
        Button(intent: ToggleActionItemIntent(id: item.id)) {
            HStack(spacing: 8) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundColor(group == .later ? .gray : group.color)
                Text(item.task)
                    .font(.subheadline)
                    .strikethrough(item.done)
                    .foregroundColor(item.done ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let due = item.due, group == .overdue || group == .later {
                    Text(shortDue(due))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Fri" within a week either way, otherwise "Oct 20".
    private func shortDue(_ date: Date) -> String {
        let days = abs(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date),
                                                       to: Calendar.current.startOfDay(for: date)).day ?? 99)
        let style: Date.FormatStyle = days < 7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day()
        return date.formatted(style)
    }
}

// MARK: - Lock Screen

struct OpenCountCircle: View {
    let entry: ActionItemsEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                Text(entry.snapshot.map { "\($0.open.count)" } ?? "\u{2013}")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
            }
        }
        .widgetAccentable()
    }
}

struct NextDueCard: View {
    let entry: ActionItemsEntry

    var body: some View {
        let open = entry.snapshot?.open ?? []
        VStack(alignment: .leading, spacing: 1) {
            Label("Action items", systemImage: "checklist")
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            if let next = open.first {
                Text(next.task)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail(next, more: open.count - 1))
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Text(entry.snapshot == nil ? "Open PerroNote" : "All caught up")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ item: WidgetItem, more: Int) -> String {
        var parts: [String] = []
        if let due = item.due {
            let cal = Calendar.current
            let today = cal.startOfDay(for: entry.date)
            let day = cal.startOfDay(for: due)
            if day < today { parts.append("Overdue") }
            else if day == today { parts.append("Due today") }
            else if day == cal.date(byAdding: .day, value: 1, to: today) { parts.append("Due tomorrow") }
            else { parts.append("Due " + due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        }
        if more > 0 { parts.append("\(more) more open") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

struct InlineCount: View {
    let entry: ActionItemsEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            let overdue = snapshot.overdue(now: entry.date).count
            Label(overdue > 0 ? "\(snapshot.open.count) open \u{00B7} \(overdue) overdue" : "\(snapshot.open.count) open",
                  systemImage: "checklist")
        } else {
            Label("PerroNote", systemImage: "checklist")
        }
    }
}

/// A round Lock Screen button that opens PerroNote and starts recording.
struct RecordCircleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.recordKind, provider: RecordProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
            .widgetAccentable()
            .widgetURL(URL(string: "perronote://record"))
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Record")
        .description("Start recording a meeting.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct RecordProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .never))
    }
}
