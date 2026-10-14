import CryptoKit
import Foundation

/// Copies each meeting's notes (never audio or transcripts) to a private GitHub repo, and brings back edits made on the web.
/// Each meeting is one file, meetings/<id>.json; action items you added yourself are action-items.json.
enum WebSync {
    static let enabledKey = "web-sync"
    static let repoKey = "web-sync-repo"
    static let tokenKey = "web-sync-token"
    private static let oldStateKey = "web-sync-state"
    /// Kept per repo, so pointing the app at a different repo never looks like every meeting was deleted.
    private static var stateKey: String { "web-sync-state:" + repo.lowercased() }
    static let defaultRepo = "ajhockey88/perronote-data"
    static let siteURL = URL(string: "https://ajhockey88.github.io/PerroNote-public/")!

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var repo: String {
        let r = (UserDefaults.standard.string(forKey: repoKey) ?? "").trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? defaultRepo : r
    }
    static var token: String { Keychain.get(tokenKey) ?? "" }

    /// The part of a meeting that goes to the web.
    struct Record: Codable {
        var id: UUID
        var title: String
        var date: Date
        var duration: TimeInterval
        var tags: [String]?
        var notes: MeetingNotes?
        var attendeeNames: [String]?
        var updated: Date
    }

    /// What each file looked like at the last sync, on the phone and on GitHub, as git blob hashes.
    private struct Seen: Codable { var local: String; var remote: String }

    private static var state: [String: Seen] {
        get {
            guard let data = UserDefaults.standard.data(forKey: stateKey)
                    ?? (repo == defaultRepo ? UserDefaults.standard.data(forKey: oldStateKey) : nil) else { return [:] }
            return (try? JSONDecoder().decode([String: Seen].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: stateKey) }
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: stateKey) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            if let date = f.date(from: text) { return date }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return d
    }()

    /// Git's hash for file contents, so the phone can tell whether a file on GitHub matches without downloading it.
    static func blobSHA(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum SyncError: LocalizedError {
        case noToken, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noToken: return "Add a GitHub token in Settings > Web sync."
            case .http(401, _): return "GitHub didn't accept the token. Check it in Settings > Web sync."
            case .http(403, _): return "The token can't write to that repo. Give it Contents: Read and write."
            case .http(404, _): return "GitHub couldn't find that repo. Check its name and that the token can see it."
            case .http(let code, let body): return "GitHub answered \(code). \(body.prefix(140))"
            }
        }
    }

    // MARK: GitHub

    private static func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Data, Int) {
        guard !token.isEmpty else { throw SyncError.noToken }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func check(_ result: (Data, Int), allow: Set<Int> = []) throws -> Data {
        let (data, code) = result
        guard (200..<300).contains(code) || allow.contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw SyncError.http(code, message ?? "")
        }
        return data
    }

    /// Every file on GitHub and its blob hash. Empty for a brand new repo.
    private static func remoteFiles() async throws -> (branch: String?, files: [String: String]) {
        let info = try check(await request("GET", ""))
        let branch = (try? JSONSerialization.jsonObject(with: info) as? [String: Any])?["default_branch"] as? String
        let result = try await request("GET", "/git/trees/\(branch ?? "main")?recursive=1")
        if result.1 == 404 || result.1 == 409 { return (branch, [:]) }
        let data = try check(result)
        let tree = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tree"] as? [[String: Any]] ?? []
        var files: [String: String] = [:]
        for entry in tree where entry["type"] as? String == "blob" {
            if let path = entry["path"] as? String, let sha = entry["sha"] as? String { files[path] = sha }
        }
        return (branch, files)
    }

    private static func download(_ sha: String) async throws -> Data {
        let data = try check(await request("GET", "/git/blobs/\(sha)"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (json?["content"] as? String ?? "").replacingOccurrences(of: "\n", with: "")
        return Data(base64Encoded: content) ?? Data()
    }

    /// Writes a file and returns its new blob hash.
    private static func upload(_ path: String, _ data: Data, replacing sha: String?, branch: String?, message: String) async throws -> String {
        var body: [String: Any] = ["message": message, "content": data.base64EncodedString()]
        if let sha { body["sha"] = sha }
        if let branch { body["branch"] = branch }
        let result = try check(await request("PUT", "/contents/\(path)", body: body))
        let json = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        return (json?["content"] as? [String: Any])?["sha"] as? String ?? blobSHA(data)
    }

    private static func remove(_ path: String, sha: String, branch: String?) async throws {
        var body: [String: Any] = ["message": "Remove \(path)", "sha": sha]
        if let branch { body["branch"] = branch }
        _ = try check(await request("DELETE", "/contents/\(path)", body: body), allow: [404])
    }

    // MARK: Sync

    struct Outcome { var sent = 0; var received = 0 }

    /// One round: files changed on the phone go up, files changed on the web come down.
    /// When both changed since the last round, the phone's version wins.
    @MainActor
    static func sync(_ store: MeetingStore) async throws -> Outcome {
        var outcome = Outcome()
        let (branch, remote) = try await remoteFiles()
        var seen = state
        defer { state = seen }

        // Local files as they would be written now.
        var local: [String: Data] = [:]
        for m in store.meetings where !m.isBusy {
            let record = Record(id: m.id, title: m.title, date: m.date, duration: m.duration,
                                tags: m.tags, notes: m.notes, attendeeNames: m.attendeeNames, updated: Date(timeIntervalSince1970: 0))
            local["meetings/\(m.id.uuidString).json"] = try encoder.encode(record)
        }
        local["action-items.json"] = try encoder.encode(store.looseItems)

        // Recipients are shared both ways. The first time, whatever either side has is kept.
        if let sha = remote["recipients.json"], seen["recipients.json"] == nil,
           let theirs = try? decoder.decode([OutlookAccount].self, from: try await download(sha)) {
            var merged = OutlookSettings.accounts
            for a in theirs where !merged.contains(where: { $0.email.caseInsensitiveCompare(a.email) == .orderedSame }) { merged.append(a) }
            OutlookSettings.accounts = merged
        }
        local["recipients.json"] = try recipientData()
        local["people.json"] = try peopleData(store)
        if let sha = remote["tags.json"], seen["tags.json"] == nil,
           let theirs = try? decoder.decode([TagStyle].self, from: try await download(sha)) {
            // First time: keep what each side already has, the phone's choice winning a clash.
            for t in theirs where !TagRegistry.isCustom(t.name) { TagRegistry.set(t.name, hex: t.color) }
        }
        local["tags.json"] = try encoder.encode(TagRegistry.all)

        // A meeting file that was synced before and is gone from GitHub was deleted on the web.
        // If GitHub has no meetings at all (a new or emptied repo), nothing is deleted; everything is sent again.
        let remoteHasMeetings = remote.keys.contains { $0.hasPrefix("meetings/") }
        var deletedOnWeb: [UUID] = []

        for (path, data) in local {
            let localSHA = blobSHA(data)
            let remoteSHA = remote[path]
            let last = seen[path]
            if remoteSHA == nil, last != nil, remoteHasMeetings, path.hasPrefix("meetings/"),
               let uuid = UUID(uuidString: String(path.dropFirst("meetings/".count).dropLast(".json".count))) {
                deletedOnWeb.append(uuid)
                seen[path] = nil
                continue
            }
            let upload: Bool
            if let last, remoteSHA != nil {
                if last.local != localSHA { upload = true }          // edited on the phone
                else if last.remote != remoteSHA { upload = false }  // edited on the web
                else { continue }                                    // nothing new
            } else {
                upload = true                                        // new, or first round for this file
            }

            if upload {
                var body = data
                if path.hasPrefix("meetings/"), var record = try? decoder.decode(Record.self, from: data) {
                    record.updated = Date()
                    body = try encoder.encode(record)
                }
                let newRemote = try await Self.upload(path, body, replacing: remoteSHA, branch: branch,
                                                      message: "Update \(path)")
                seen[path] = Seen(local: localSHA, remote: newRemote)
                outcome.sent += 1
            } else if let remoteSHA {
                // Edited on the web: bring it into the app.
                let incoming = try await download(remoteSHA)
                if path == "tags.json" {
                    TagRegistry.all = try decoder.decode([TagStyle].self, from: incoming)
                } else if path == "people.json" {
                    // Names only go one way, to the website; nothing to bring in.
                } else if path == "recipients.json" {
                    OutlookSettings.accounts = try decoder.decode([OutlookAccount].self, from: incoming)
                } else if path == "action-items.json" {
                    let items = try decoder.decode([ActionItem].self, from: incoming)
                    store.replaceLooseItems(items)
                } else {
                    let record = try decoder.decode(Record.self, from: incoming)
                    store.applyWebEdit(record)
                }
                let refreshed = localData(for: path, store: store) ?? data
                seen[path] = Seen(local: blobSHA(refreshed), remote: remoteSHA)
                outcome.received += 1
            }
        }

        for id in deletedOnWeb { store.delete(id) }
        outcome.received += deletedOnWeb.count

        // Meetings deleted on the phone come off the web too.
        for (path, sha) in remote where path.hasPrefix("meetings/") && local[path] == nil {
            guard seen[path] != nil else { continue }
            let id = path.dropFirst("meetings/".count).dropLast(".json".count)
            if let uuid = UUID(uuidString: String(id)), store.meeting(uuid)?.isBusy == true { continue }
            try await remove(path, sha: sha, branch: branch)
            seen[path] = nil
        }

        await sendOutbox(remote: remote, branch: branch, store: store)
        return outcome
    }

    private struct PersonName: Codable { var name: String; var aliases: [String]? }

    /// The saved people by name only; voice prints never leave the phone.
    @MainActor
    private static func peopleData(_ store: MeetingStore) throws -> Data {
        let list = (store.people?.people ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return try encoder.encode(list.map { PersonName(name: $0.name, aliases: $0.aliases) })
    }

    private static func recipientData() throws -> Data {
        let list = OutlookSettings.accounts.map { Mail(id: $0.id, name: $0.name, email: $0.email) }
        return try encoder.encode(list)
    }

    private struct Mail: Codable { var id: UUID; var name: String; var email: String }

    /// A request to email a meeting, left in the repo by the website. The phone sends it the same way as the Send button.
    private struct OutboxRequest: Codable { var meetingId: UUID; var email: String; var name: String? }

    @MainActor
    private static func sendOutbox(remote: [String: String], branch: String?, store: MeetingStore) async {
        let credentials = GmailMailer.Credentials(address: MailSettings.address, appPassword: MailSettings.appPassword)
        guard !credentials.address.isEmpty, !credentials.appPassword.isEmpty else { return }
        for (path, sha) in remote where path.hasPrefix("outbox/") && path.hasSuffix(".json") {
            guard let data = try? await download(sha),
                  let req = try? JSONDecoder().decode(OutboxRequest.self, from: data) else {
                try? await remove(path, sha: sha, branch: branch)
                continue
            }
            guard let meeting = store.meeting(req.meetingId), let notes = meeting.notes else {
                try? await remove(path, sha: sha, branch: branch)
                continue
            }
            let account = OutlookAccount(name: req.name ?? req.email, email: req.email)
            guard account.isValid else { try? await remove(path, sha: sha, branch: branch); continue }
            let attachment = GmailMailer.Attachment(
                name: MeetingDocx.fileName(for: meeting), mimeType: MeetingDocx.mimeType,
                data: MeetingDocx.data(for: meeting, notes: notes))
            do {
                try await GmailMailer.send(from: credentials, to: account, subject: MeetingExport.subject(meeting),
                                           html: MeetingExport.html(for: meeting, notes: notes),
                                           plain: MeetingExport.plainText(for: meeting, notes: notes), attachment: attachment)
                try? await remove(path, sha: sha, branch: branch)
            } catch {
                continue // stays in the outbox and is tried again next round
            }
        }
    }

    @MainActor
    private static func localData(for path: String, store: MeetingStore) -> Data? {
        if path == "action-items.json" { return try? encoder.encode(store.looseItems) }
        if path == "recipients.json" { return try? recipientData() }
        if path == "people.json" { return try? peopleData(store) }
        if path == "tags.json" { return try? encoder.encode(TagRegistry.all) }
        let id = path.dropFirst("meetings/".count).dropLast(".json".count)
        guard let uuid = UUID(uuidString: String(id)), let m = store.meeting(uuid) else { return nil }
        let record = Record(id: m.id, title: m.title, date: m.date, duration: m.duration,
                            tags: m.tags, notes: m.notes, attendeeNames: m.attendeeNames, updated: Date(timeIntervalSince1970: 0))
        return try? encoder.encode(record)
    }
}
