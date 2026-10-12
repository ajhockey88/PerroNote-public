import Foundation
import UserNotifications

/// Morning notifications about action items that are overdue, due today or due tomorrow.
/// They are worked out on the phone for the next week and redone whenever action items change.
enum DueAlerts {
    static let enabledKey = "due-alerts"
    /// Minutes after midnight for the daily alert. 8:00 by default.
    static let timeKey = "due-alerts-time"
    private static let idPrefix = "due-alert-"
    private static let daysAhead = 7

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var minutes: Int { UserDefaults.standard.object(forKey: timeKey) as? Int ?? 8 * 60 }

    /// Asks for permission to notify. Returns false if you said no.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces the scheduled alerts with ones for these items (already narrowed to whose items count).
    static func reschedule(_ items: [ActionItem]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard enabled else { return }

            let open = items.filter { !$0.done && !$0.task.isEmpty }
            let dated = open.compactMap { item in item.dueDate.map { (item, Calendar.current.startOfDay(for: $0)) } }
            guard !dated.isEmpty else { return }

            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            for offset in 0..<daysAhead {
                guard let day = cal.date(byAdding: .day, value: offset, to: today),
                      let tomorrow = cal.date(byAdding: .day, value: 1, to: day),
                      let fire = cal.date(byAdding: .minute, value: minutes, to: day),
                      fire > Date() else { continue }
                let overdue = dated.filter { $0.1 < day }.map(\.0)
                let dueToday = dated.filter { $0.1 == day }.map(\.0)
                let dueTomorrow = dated.filter { $0.1 == tomorrow }.map(\.0)
                guard !(overdue.isEmpty && dueToday.isEmpty && dueTomorrow.isEmpty) else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Action items"
                var counts: [String] = []
                if !overdue.isEmpty { counts.append("\(overdue.count) overdue") }
                if !dueToday.isEmpty { counts.append("\(dueToday.count) due today") }
                if !dueTomorrow.isEmpty { counts.append("\(dueTomorrow.count) due tomorrow") }
                content.subtitle = counts.joined(separator: " \u{00B7} ")
                let first = (overdue + dueToday + dueTomorrow).prefix(3).map { "\u{2022} \($0.task)" }
                content.body = first.joined(separator: "\n")
                content.sound = .default
                content.userInfo = ["open": "action-items"]

                let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let request = UNNotificationRequest(identifier: idPrefix + String(offset),
                                                    content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                center.add(request)
            }
        }
    }
}
