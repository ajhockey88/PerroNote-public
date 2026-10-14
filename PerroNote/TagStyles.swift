import SwiftUI
import UIKit

/// A tag and the colour you picked for it. Shared with the website through tags.json.
struct TagStyle: Codable, Identifiable, Hashable {
    var name: String
    /// "#RRGGBB"
    var color: String
    var id: String { name.lowercased() }
}

enum TagRegistry {
    private static let key = "tag-styles"
    /// Same colours and the same name-to-colour rule as the website, so an unchosen tag looks alike on both.
    static let palette = ["#FF7A45", "#2f74d0", "#2e9e5b", "#9b51e0", "#e5413a", "#c98a0c", "#0f9ba8", "#d94f97"]

    static var all: [TagStyle] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([TagStyle].self, from: data) else { return [] }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    private static func autoHex(_ name: String) -> String {
        var h: UInt32 = 0
        for unit in name.trimmingCharacters(in: .whitespaces).lowercased().utf16 { h = h &* 31 &+ UInt32(unit) }
        return palette[Int(h % UInt32(palette.count))]
    }

    static func hex(for name: String) -> String {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color ?? autoHex(name)
    }

    static func color(for name: String) -> Color { Color(hex: hex(for: name)) ?? .accentColor }

    static func isCustom(_ name: String) -> Bool { all.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    static func set(_ name: String, hex: String) {
        var list = all.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        list.append(TagStyle(name: name, color: hex))
        all = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func reset(_ name: String) { all = all.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame } }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// Settings > Tags: every tag in use or saved, each with a colour. Colours sync to the website.
struct TagColorsView: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var styles = TagRegistry.all
    @State private var newTag = ""

    private var names: [String] {
        var seen = Set<String>(), out: [String] = []
        for n in styles.map(\.name) + store.allTags where seen.insert(n.lowercased()).inserted { out.append(n) }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func binding(_ name: String) -> Binding<Color> {
        Binding(get: { TagRegistry.color(for: name) },
                set: { TagRegistry.set(name, hex: $0.hexString); styles = TagRegistry.all; store.scheduleSync(after: 2) })
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("New tag", text: $newTag).textInputAutocapitalization(.words).submitLabel(.done).onSubmit(add)
                    Button("Add", action: add).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Text("#\(name)").foregroundStyle(TagRegistry.color(for: name))
                        Spacer()
                        if TagRegistry.isCustom(name) {
                            Button("Reset") { TagRegistry.reset(name); styles = TagRegistry.all; store.scheduleSync(after: 2) }
                                .font(.footnote).buttonStyle(.borderless)
                        }
                        ColorPicker("", selection: binding(name), supportsOpacity: false).labelsHidden()
                    }
                }
            } footer: {
                Text("The colour you pick shows on meetings and action items here and on the website.")
            }
        }
        .navigationTitle("Tags")
    }

    private func add() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !t.isEmpty else { return }
        TagRegistry.set(t, hex: TagRegistry.hex(for: t))
        styles = TagRegistry.all
        store.scheduleSync(after: 2)
    }
}
