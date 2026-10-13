import Foundation
import UIKit

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    /// Action items you added yourself, not tied to any meeting.
    @Published private(set) var looseItems: [ActionItem] = []

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var indexURL: URL { documents.appendingPathComponent("meetings.json") }
    private static var looseURL: URL { documents.appendingPathComponent("action-items.json") }

    nonisolated static func audioURL(for fileName: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio").appendingPathComponent(fileName)
    }

    init() {
        load()
        loadLoose()
        applyWidgetTicks(saving: false)
        // A run that was interrupted (app killed mid-processing) can be retried from the detail screen.
        for i in meetings.indices where meetings[i].isBusy {
            meetings[i].status = .failed
            meetings[i].errorMessage = "Processing was interrupted."
        }
        save()
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func add(fileName: String, duration: TimeInterval, date: Date = Date()) -> UUID {
        let title = "Meeting " + date.formatted(date: .abbreviated, time: .shortened)
        let meeting = Meeting(title: title, date: date, duration: duration, audioFile: fileName)
        meetings.insert(meeting, at: 0)
        save()
        return meeting.id
    }

    /// Changes a meeting. Disk writes happen at once unless `immediate` is false (used while typing).
    func update(_ id: UUID, immediate: Bool = true, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        if immediate { save() } else { scheduleSave() }
    }

    func addUsage(_ id: UUID, _ entry: TokenUsage) {
        update(id) { $0.usage = ($0.usage ?? []) + [entry] }
    }

    /// Applies a typed change to the notes. These are the words that get emailed and put in the Word file.
    /// Takes a name off the saved attendee list too, so it isn't offered again in Who's who or shown on the meeting row.
    func removeAttendeeName(_ id: UUID, _ name: String) {
        update(id, immediate: false) { m in
            m.attendeeNames = m.attendeeNames?.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        }
    }

    func updateNotes(_ id: UUID, edited: Bool = true, _ change: (inout MeetingNotes) -> Void) {
        update(id, immediate: false) { m in
            guard var notes = m.notes else { return }
            change(&notes)
            m.notes = notes
            if edited { m.notesEdited = true }
        }
    }

    /// Writes any pending changes to disk now (for example when the app goes to the background).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Every action item: from all meetings' notes, then the ones you added yourself.
    var allActionItems: [ActionItem] {
        meetings.flatMap { $0.notes?.actionItems ?? [] } + looseItems
    }

    func addLooseItem(_ item: ActionItem) {
        looseItems.insert(item, at: 0)
        saveLoose()
    }

    func toggleLooseItem(_ id: UUID) {
        guard let i = looseItems.firstIndex(where: { $0.id == id }) else { return }
        looseItems[i].done.toggle()
        saveLoose()
    }

    func deleteLooseItem(_ id: UUID) {
        looseItems.removeAll { $0.id == id }
        saveLoose()
    }

    private func saveLoose() {
        guard let data = try? JSONEncoder().encode(looseItems) else { return }
        try? data.write(to: Self.looseURL, options: .atomic)
        refreshAlerts()
    }

    /// Redoes the due date notifications for the items the banner counts (Settings > Action items banner).
    func refreshAlerts() {
        let people = BannerSettings.people(from: UserDefaults.standard.string(forKey: BannerSettings.peopleKey) ?? "")
        let myName = UserDefaults.standard.string(forKey: BannerSettings.myNameKey) ?? ""
        let mine = allActionItems.filter { BannerSettings.matches($0, people: people, myName: myName) }
        DueAlerts.reschedule(mine)
        writeWidget(mine)
        scheduleSync()
    }

    // MARK: Web sync

    /// The last web sync result, shown in Settings > Web sync.
    @Published private(set) var syncStatus = ""
    private var syncTask: Task<Void, Never>?
    private var syncing = false

    /// Syncs a few seconds after the last change, so typing doesn't send a file per keystroke.
    func scheduleSync(after seconds: Double = 4) {
        guard WebSync.enabled else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard WebSync.enabled, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let result = try await WebSync.sync(self)
            var parts = ["Synced " + Date().formatted(date: .omitted, time: .shortened)]
            if result.sent > 0 { parts.append("\(result.sent) sent") }
            if result.received > 0 { parts.append("\(result.received) brought in from the web") }
            syncStatus = parts.joined(separator: " \u{00B7} ")
        } catch {
            syncStatus = error.localizedDescription
        }
    }

    /// Finishes a sync after you leave the app, within the little time iOS allows.
    func syncInBackground() {
        guard WebSync.enabled else { return }
        syncTask?.cancel()
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "web-sync") {
            UIApplication.shared.endBackgroundTask(taskID)
        }
        Task {
            await syncNow()
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    /// Takes notes, title and tags edited on the web.
    func applyWebEdit(_ record: WebSync.Record) {
        update(record.id) { m in
            if m.title != record.title { m.title = record.title; m.titleEdited = true }
            m.tags = record.tags
            if m.notes != record.notes { m.notes = record.notes; m.notesEdited = true }
            if let names = record.attendeeNames, m.attendeeNames != names { m.attendeeNames = names }
        }
    }

    /// Takes your own action items as edited on the web.
    func replaceLooseItems(_ items: [ActionItem]) {
        looseItems = items
        saveLoose()
    }

    /// Hands the open items to the Home Screen and Lock Screen widgets, soonest due first.
    private func writeWidget(_ items: [ActionItem]) {
        let ticks = WidgetStore.readTicks()
        let shown = items.compactMap { item -> WidgetItem? in
            let key = item.id.uuidString
            let done = ticks[key] ?? item.done
            // Items ticked in the app drop off; ones ticked on the widget stay struck through until the app catches up.
            guard !item.task.isEmpty, !item.done || ticks[key] != nil else { return nil }
            return WidgetItem(id: key, task: item.task, due: item.dueDate, done: done)
        }
        let sorted = shown.enumerated().sorted { a, b in
            switch (a.element.due, b.element.due) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        WidgetStore.write(WidgetSnapshot(items: sorted))
    }

    /// Copies items ticked on the widget into the notes and your own list.
    func applyWidgetTicks(saving: Bool = true) {
        let ticks = WidgetStore.readTicks()
        guard !ticks.isEmpty else { return }
        for (key, done) in ticks {
            guard let id = UUID(uuidString: key) else { continue }
            if let i = looseItems.firstIndex(where: { $0.id == id }) { looseItems[i].done = done }
            for m in meetings.indices {
                if let i = meetings[m].notes?.actionItems.firstIndex(where: { $0.id == id }) {
                    meetings[m].notes?.actionItems[i].done = done
                }
            }
        }
        WidgetStore.clearTicks()
        if let data = try? JSONEncoder().encode(looseItems) { try? data.write(to: Self.looseURL, options: .atomic) }
        if saving { save() }
    }

    /// Every tag used on any meeting, A to Z.
    var allTags: [String] {
        var seen = Set<String>()
        return meetings.flatMap { $0.tags ?? [] }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Adds a recording brought in from Files and starts turning it into notes.
    func addImported(_ file: AudioImport.Imported) {
        let id = add(fileName: file.fileName, duration: file.duration, date: file.date)
        if !file.title.isEmpty { update(id) { $0.title = file.title } }
        Task { await process(id) }
    }

    func delete(_ id: UUID) {
        guard let m = meeting(id) else { return }
        try? FileManager.default.removeItem(at: Self.audioURL(for: m.audioFile))
        meetings.removeAll { $0.id == id }
        save()
    }

    /// The saved people, used to suggest names for voices.
    weak var people: PeopleStore?

    /// Transcribes and separates voices (unless a transcript already exists), then drafts the notes.
    func process(_ id: UUID, regenerateTranscript: Bool = false, voiceCount: Int? = nil) async {
        guard let m = meeting(id), !m.isBusy else { return }

        if (m.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || regenerateTranscript {
            update(id) { $0.status = .transcribing; $0.errorMessage = nil }
            let fileURL = Self.audioURL(for: m.audioFile)
            let transcription: TranscriptionResult
            do {
                transcription = try await Transcriber.transcribe(fileURL: fileURL)
            } catch {
                update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
                return
            }
            update(id) {
                $0.transcript = transcription.text
                $0.lines = nil
                $0.timeline = TranscriptBuilder.chunks(words: transcription.words)
                $0.voices = nil
                $0.speakersConfirmed = nil
                $0.voiceNote = nil
                if !transcription.gaps.isEmpty {
                    let spans = transcription.gaps.prefix(3)
                        .map { "\(formatDuration($0.start)) to \(formatDuration($0.end))" }.joined(separator: ", ")
                    $0.voiceNote = "Some speech may be missing from the transcript (around \(spans)). Tap \u{22EF} > Re-transcribe and find voices to try again."
                }
            }

            // Almost nothing recognized: say so instead of asking Claude to write notes from nothing.
            let spoken = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if m.duration >= 20 && spoken.count < 15 {
                update(id) {
                    $0.status = .failed
                    $0.errorMessage = "Almost no speech was recognized (\(transcription.words.count) words in a \(formatDuration(m.duration)) recording). The audio may have been too quiet or too far from the phone, or speech recognition stopped early. Tap Try again to read it a second time."
                }
                return
            }

            // Telling voices apart is a bonus: if it fails, the notes still get written.
            if !transcription.words.isEmpty {
                update(id) { $0.status = .diarizing }
                do {
                    let found = try await SpeakerDiarizer.run(fileURL: fileURL, speakers: voiceCount)
                    let suggest: ([Float]) -> Person? = { [weak self] embedding in self?.people?.suggest(for: embedding) }
                    let built = TranscriptBuilder.build(words: transcription.words, diarization: found, suggest: suggest)
                    update(id) {
                        if built.voices.count > 1 {
                            $0.lines = built.lines
                            $0.voices = built.voices
                        }
                    }
                } catch {
                    update(id) {
                        let why = "Voices could not be told apart: \(error.localizedDescription)"
                        $0.voiceNote = [$0.voiceNote, why].compactMap { $0 }.joined(separator: " ")
                    }
                }
            }
        }

        guard let current = meeting(id) else { return }
        update(id) { $0.status = .generating; $0.errorMessage = nil }
        do {
            let result = try await NotesGenerator.generate(
                transcript: current.timedTranscript,
                meetingDate: current.date,
                attendees: current.attendeeNames ?? [],
                voicesIdentified: current.hasVoices && (current.speakersConfirmed ?? false))
            update(id) {
                var notes = result.notes
                let hadNotes = $0.usage?.contains { $0.kind == .draft || $0.kind == .redraft } ?? false
                $0.usage = ($0.usage ?? []) + [TokenUsage(kind: hadNotes ? .redraft : .draft,
                                                          model: NotesGenerator.model, json: result.usage)]
                Self.carryOverTicks(from: $0.notes, into: &notes)
                if var voices = $0.voices {
                    for i in voices.indices { voices[i].mentionedName = result.speakerNames[voices[i].id] }
                    $0.voices = voices
                }
                notes.fillAttendees(voices: $0.voices)
                if !$0.titleEdited { $0.title = result.title }
                $0.notes = notes
                $0.notesEdited = nil
                $0.status = .done
            }
        } catch {
            update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
        }
    }

    /// Saves who is who, remembers the voices, and puts the real names into the notes.
    /// Notes that already exist get the names swapped in place, so no request goes to Claude.
    func applyIdentification(_ id: UUID, assignments: [String: Person], attendeeNames: [String],
                             people: PeopleStore) async {
        let oldLabels = Dictionary(uniqueKeysWithValues: (meeting(id)?.voices ?? []).map { ($0.id, $0.label) })
        let previousNames = meeting(id)?.attendeeNames ?? meeting(id)?.notes?.attendees ?? []
        update(id) { m in
            m.attendeeNames = attendeeNames
            if var voices = m.voices {
                for i in voices.indices {
                    if let person = assignments[voices[i].id] {
                        voices[i].personID = person.id
                        voices[i].name = person.name
                    } else {
                        voices[i].personID = nil
                        voices[i].name = nil
                    }
                }
                m.voices = voices
            }
            m.speakersConfirmed = true
        }
        if let voices = meeting(id)?.voices {
            for voice in voices {
                if let person = assignments[voice.id] { people.remember(embedding: voice.embedding, for: person.id) }
            }
        }
        guard let m = meeting(id), m.status == .done, m.notes != nil else {
            await process(id)
            return
        }
        var renames: [String: String] = [:]
        for voice in m.voices ?? [] {
            if let old = oldLabels[voice.id], old != voice.label { renames[old] = voice.label }
        }
        for (old, new) in renames where !MeetingNotes.isSpeakerLabel(old) { people.addAlias(old, to: new) }
        // An attendee edited in the list: pair removed and added names so the old one is replaced, not kept beside the new one.
        func isIn(_ list: [String], _ name: String) -> Bool { list.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        let removedNames = previousNames.filter { !isIn(attendeeNames, $0) && !MeetingNotes.isSpeakerLabel($0) }
        let addedNames = attendeeNames.filter { !isIn(previousNames, $0) }
        if removedNames.count == addedNames.count {
            for (old, new) in zip(removedNames, addedNames) where renames[old] == nil { renames[old] = new }
        }
        update(id) { m in
            guard var notes = m.notes else { return }
            notes.replaceNames(renames)
            notes.attendees.removeAll { name in removedNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            for name in attendeeNames where !notes.attendees.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                notes.attendees.append(name)
            }
            notes.fillAttendees(voices: m.voices)
            m.notes = notes
            if !m.titleEdited { m.title = Self.replacingNames(renames, in: m.title) }
        }
    }

    /// Swaps whole names in one pass, so "Speaker 1" never matches inside "Speaker 10" and A to B, B to C can't chain.
    nonisolated static func replacingNames(_ renames: [String: String], in text: String) -> String {
        guard !renames.isEmpty else { return text }
        let alternatives = renames.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])")
        else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let found = ns.substring(with: match.range)
            out += renames[found] ?? found
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }

    /// Keeps action items you already ticked when the notes are redrafted, even if the wording shifted a little.
    private static func carryOverTicks(from old: MeetingNotes?, into new: inout MeetingNotes) {
        guard let old else { return }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let done = old.actionItems.filter(\.done).map { words($0.task) }
        guard !done.isEmpty else { return }
        for i in new.actionItems.indices {
            let w = words(new.actionItems[i].task)
            if done.contains(where: { d in
                let overlap = Double(d.intersection(w).count)
                let total = Double(d.union(w).count)
                return total > 0 && overlap / total >= 0.5
            }) { new.actionItems[i].done = true }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([Meeting].self, from: data) else { return }
        meetings = decoded
    }

    private func loadLoose() {
        guard let data = try? Data(contentsOf: Self.looseURL),
              let decoded = try? JSONDecoder().decode([ActionItem].self, from: data) else { return }
        looseItems = decoded
    }

    private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
        refreshAlerts()
    }
}
