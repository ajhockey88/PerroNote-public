import Foundation

/// Someone you meet with, and (if you allow it) what their voice sounds like.
/// The voice print is a list of numbers kept on this phone only.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var voice: [Float]?
    var voiceSamples = 0
    /// Other ways this person gets called, like a last name or initials.
    var aliases: [String]?
}

/// Looks up the full name behind a nickname, last name or other alias. Kept in step by PeopleStore.
enum AliasBook {
    static var map: [String: String] = [:]

    static func canonical(_ name: String) -> String {
        map[name.trimmingCharacters(in: .whitespaces).lowercased()] ?? name
    }
}

enum VoiceMath {
    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let d = (na * nb).squareRoot()
        return d > 0 ? dot / d : 0
    }
}

@MainActor
final class PeopleStore: ObservableObject {
    @Published private(set) var people: [Person] = []

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("people.json")
    }
    private static let rememberKey = "remember-voices"

    /// Whether to keep voice prints so future meetings can suggest names. On by default.
    var rememberVoices: Bool {
        get { UserDefaults.standard.object(forKey: Self.rememberKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.rememberKey); objectWillChange.send() }
    }

    init() { load(); rebuildAliases() }

    private func rebuildAliases() {
        var map: [String: String] = [:]
        for p in people { for a in p.aliases ?? [] { map[a.trimmingCharacters(in: .whitespaces).lowercased()] = p.name } }
        AliasBook.map = map
    }

    func setAliases(_ id: UUID, _ aliases: [String]) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<String>()
        let clean = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(people[i].name) != .orderedSame && seen.insert($0.lowercased()).inserted }
        people[i].aliases = clean.isEmpty ? nil : clean
        save()
    }

    /// Remembers an old name as another way to say this person, e.g. after a rename.
    func addAlias(_ alias: String, to name: String) {
        guard let p = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        setAliases(p.id, (p.aliases ?? []) + [alias])
    }

    func person(_ id: UUID?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    /// Finds a person by name (ignoring case) or adds them.
    @discardableResult
    func personNamed(_ name: String) -> Person? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let existing = people.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            return existing
        }
        let person = Person(name: clean)
        people.append(person)
        people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
        return person
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = people.firstIndex(where: { $0.id == id }) else { return }
        people[i].name = clean
        save()
    }

    func delete(_ id: UUID) {
        people.removeAll { $0.id == id }
        save()
    }

    func forgetAllVoices() {
        for i in people.indices {
            people[i].voice = nil
            people[i].voiceSamples = 0
        }
        save()
    }

    func forgetVoice(_ id: UUID) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        people[i].voice = nil
        people[i].voiceSamples = 0
        save()
    }

    /// Blends a newly heard voice print into the saved one for this person.
    func remember(embedding: [Float], for id: UUID) {
        guard rememberVoices, !embedding.isEmpty, let i = people.firstIndex(where: { $0.id == id }) else { return }
        let new = VoiceMath.normalized(embedding)
        if let old = people[i].voice, old.count == new.count {
            let weight = Float(min(people[i].voiceSamples, 8))
            var mixed = [Float](repeating: 0, count: new.count)
            for k in 0..<new.count { mixed[k] = old[k] * weight + new[k] }
            people[i].voice = VoiceMath.normalized(mixed)
        } else {
            people[i].voice = new
        }
        people[i].voiceSamples += 1
        save()
    }

    /// Who this voice most likely is. Only suggests when one person clearly stands out.
    func suggest(for embedding: [Float]) -> Person? {
        guard rememberVoices, !embedding.isEmpty else { return nil }
        let scored = people.compactMap { p -> (Person, Float)? in
            guard let v = p.voice else { return nil }
            return (p, VoiceMath.cosine(VoiceMath.normalized(embedding), v))
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.5 else { return nil }
        if scored.count > 1, best.1 - scored[1].1 < 0.05 { return nil }
        return best.0
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let decoded = try? JSONDecoder().decode([Person].self, from: data) else { return }
        people = decoded
    }

    private func save() {
        rebuildAliases()
        guard let data = try? JSONEncoder().encode(people) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
