import AVFoundation
import SwiftUI

/// Plays a few seconds of one voice from the recording, then stops by itself.
final class SnippetPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(key: String, url: URL, start: Double, end: Double) {
        if playing == key { stop(); return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.currentTime = max(0, start)
        guard p.play() else { return }
        player = p
        playing = key
        timer = Timer.scheduledTimer(withTimeInterval: max(1, end - start), repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playing = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}

/// After the call: who was there, and which voice is which. Everything in the meeting updates when you save.
struct WhoIsWhoView: View {
    let meetingID: UUID

    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var people: PeopleStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = SnippetPlayer()

    @State private var attendeeNames: [String] = []
    @State private var choice: [String: String] = [:]
    @State private var newName = ""
    @State private var loaded = false
    @State private var confirmReplace = false

    private var meeting: Meeting? { store.meeting(meetingID) }

    /// Everyone you can pick for a voice: this meeting's attendees first, then saved people.
    private var options: [String] {
        var result = attendeeNames
        for p in people.people where !result.contains(where: { $0.caseInsensitiveCompare(p.name) == .orderedSame }) {
            result.append(p.name)
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                attendeesSection
                if let voices = meeting?.voices, voices.count > 1 {
                    ForEach(voices) { voice in voiceSection(voice) }
                    Section {
                        Text(people.rememberVoices
                             ? "Voices are matched on this phone, nothing is uploaded. Saving also remembers each voice here, so next time the app can suggest a name. You can turn that off in Settings."
                             : "Voices are matched on this phone, nothing is uploaded. Voice memory is off in Settings, so these voices will not be remembered.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .paperScreen()
            .navigationTitle(meeting?.hasVoices == true ? "Who's who" : "Attendees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { player.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update notes") {
                        if meeting?.notesEdited == true { confirmReplace = true } else { save() }
                    }
                }
            }
            .confirmationDialog("This replaces your edits", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Update and replace my edits", role: .destructive) { save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The notes will be written again with the names. Text you typed in the notes will be lost.")
            }
            .onAppear(perform: load)
            .onDisappear { player.stop() }
        }
    }

    private var attendeesSection: some View {
        Section {
            ForEach(attendeeNames, id: \.self) { name in
                Text(name)
            }
            .onDelete { attendeeNames.remove(atOffsets: $0) }

            HStack {
                TextField("Add a name", text: $newName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            let others = people.people.filter { p in
                !attendeeNames.contains { $0.caseInsensitiveCompare(p.name) == .orderedSame }
            }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { p in
                        Button(p.name) { attendeeNames.append(p.name) }
                    }
                } label: {
                    Label("Add from people you've met", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } header: {
            Text("Who was there")
        } footer: {
            Text("The notes list these as attendees.")
        }
    }

    private func voiceSection(_ voice: DetectedVoice) -> some View {
        Section {
            HStack(spacing: 10) {
                Circle().fill(speakerColor(voice.id)).frame(width: 10, height: 10)
                Text("Speaker \(voice.id)").font(.headline)
                Spacer()
                Text("talked \(minutes(voice.talkTime))").font(.footnote).foregroundStyle(.secondary)
            }

            Button {
                if let m = meeting {
                    player.toggle(key: voice.id, url: MeetingStore.audioURL(for: m.audioFile),
                                  start: voice.snippetStart, end: voice.snippetEnd)
                }
            } label: {
                Label(player.playing == voice.id ? "Stop" : "Play a sample",
                      systemImage: player.playing == voice.id ? "stop.circle.fill" : "play.circle.fill")
            }

            if let quote = quote(for: voice) {
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.subheadline.italic())
                    .foregroundStyle(.secondary)
            }

            if let suggested = voice.suggestedName, (choice[voice.id] ?? "") != suggested {
                Button {
                    choice[voice.id] = suggested
                    if !attendeeNames.contains(where: { $0.caseInsensitiveCompare(suggested) == .orderedSame }) {
                        attendeeNames.append(suggested)
                    }
                } label: {
                    Label("Sounds like \(suggested). Use this", systemImage: "sparkles")
                }
            }

            Picker("Who is this?", selection: Binding(
                get: { choice[voice.id] ?? "" },
                set: { choice[voice.id] = $0 })) {
                Text("Not sure").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    // MARK: - Actions

    private func load() {
        guard !loaded, let m = meeting else { return }
        loaded = true
        attendeeNames = m.attendeeNames ?? []
        for v in m.voices ?? [] { choice[v.id] = v.name ?? "" }
    }

    private func addTyped() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !attendeeNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            attendeeNames.append(name)
        }
        newName = ""
    }

    private func save() {
        player.stop()
        addTyped()
        var assignments: [String: Person] = [:]
        var names = attendeeNames
        for (voiceID, name) in choice where !name.isEmpty {
            if let person = people.personNamed(name) {
                assignments[voiceID] = person
                if !names.contains(where: { $0.caseInsensitiveCompare(person.name) == .orderedSame }) {
                    names.append(person.name)
                }
            }
        }
        for name in names { _ = people.personNamed(name) }
        let id = meetingID
        let store = store
        let people = people
        dismiss()
        Task { await store.applyIdentification(id, assignments: assignments, attendeeNames: names, people: people) }
    }

    // MARK: - Helpers

    private func quote(for voice: DetectedVoice) -> String? {
        guard let lines = meeting?.lines else { return nil }
        let mine = lines.filter { $0.speaker == voice.id }
        let hit = mine.first { $0.start <= voice.snippetStart + 0.5 && $0.end >= voice.snippetStart } ?? mine.first
        guard let text = hit?.text, !text.isEmpty else { return nil }
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }

    private func minutes(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) sec" : "\(Int((seconds / 60).rounded())) min"
    }
}
