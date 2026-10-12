import Foundation

/// A place meeting notes can be sent to: a label you choose and the email address behind it.
struct OutlookAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var email = ""

    var isValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard let at = e.firstIndex(of: "@") else { return false }
        return at != e.startIndex && e[e.index(after: at)...].contains(".") && !e.contains(" ")
    }
}

enum OutlookSettings {
    private static let accountsKey = "outlook-accounts"

    static var accounts: [OutlookAccount] {
        get {
            guard let data = UserDefaults.standard.data(forKey: accountsKey),
                  let list = try? JSONDecoder().decode([OutlookAccount].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: accountsKey)
        }
    }
}
