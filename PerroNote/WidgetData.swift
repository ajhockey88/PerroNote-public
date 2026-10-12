import AppIntents
import Foundation
import WidgetKit

/// One open action item as the widgets see it.
struct WidgetItem: Codable, Identifiable, Hashable {
    var id: String
    var task: String
    var due: Date?
    var done = false
}

/// What the app hands the widgets: the open action items the banner counts, soonest due first.
struct WidgetSnapshot: Codable, Equatable {
    var items: [WidgetItem]

    var open: [WidgetItem] { items.filter { !$0.done } }

    func overdue(now: Date = Date()) -> [WidgetItem] {
        let today = Calendar.current.startOfDay(for: now)
        return open.filter { ($0.due ?? .distantFuture) < today }
    }
}

/// The shared folder the app and the widgets both read. Needs the App Group on both; nil without it.
enum WidgetStore {
    static let group = "group.com.ajhockey88.perronote"
    static let actionsKind = "com.ajhockey88.perronote.actions"
    static let recordKind = "com.ajhockey88.perronote.record-circle"

    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    private static var snapshotURL: URL? { folder?.appendingPathComponent("widget-items.json") }
    /// Items ticked or unticked on the widget that the app hasn't picked up yet: id to done.
    private static var ticksURL: URL? { folder?.appendingPathComponent("widget-ticks.json") }

    static func readSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot and refreshes the widgets, only when something changed.
    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotURL, snapshot != readSnapshot(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func readTicks() -> [String: Bool] {
        guard let url = ticksURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }

    static func clearTicks() {
        guard let url = ticksURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Ticks or unticks an item from the widget. The app copies it into the notes next time it opens.
    static func toggle(_ id: String) {
        guard var snapshot = readSnapshot(), let i = snapshot.items.firstIndex(where: { $0.id == id }) else { return }
        snapshot.items[i].done.toggle()
        var ticks = readTicks()
        ticks[id] = snapshot.items[i].done
        if let url = ticksURL, let data = try? JSONEncoder().encode(ticks) { try? data.write(to: url, options: .atomic) }
        if let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}

/// The checkbox on the Large widget.
struct ToggleActionItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick Action Item"
    static var isDiscoverable = false

    @Parameter(title: "Item") var itemID: String

    init() {}
    init(id: String) { itemID = id }

    func perform() async throws -> some IntentResult {
        WidgetStore.toggle(itemID)
        return .result()
    }
}
