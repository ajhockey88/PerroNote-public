import Foundation

/// Today's focus as shared with the website: the day it was set and the pinned item ids in order.
struct TodayFocus: Codable, Equatable {
    var day: String
    var ids: [String]

    private enum CodingKeys: String, CodingKey { case day, ids = "items" }

    private static let key = "focus-state"

    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func load() -> TodayFocus {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(TodayFocus.self, from: data) else { return TodayFocus(day: today, ids: []) }
        return state
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}
