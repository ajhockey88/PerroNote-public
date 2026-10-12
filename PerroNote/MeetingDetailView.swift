import SwiftUI
import UIKit

struct MeetingDetailView: View {
    let id: UUID
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayer()
    @State private var editing = false
    @State private var showPlayer = false
    @State private var showTranscript = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var pickingAccount = false
    @State private var noAccounts = false
    @State private var showSettings = false
    @State private var share: ShareItems?
    @State private var showWhoIsWho = false
    @State private var sendError: String?
    @State private var sending = false
    @State private var toast: String?
    @State private var pendingRegenerate: Bool?
    @State private var asking = false
    @State private var playingKey: String?
    @State private var showUsage = false
    @State private var askingVoices = false
    @State private var editingTags = false
    @State private var customAddress = false
    @State private var customEmail = ""
    @State private var voiceCount = 0
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @PaperPitch private var pitch
    @State private var headerHeight: CGFloat = 0
    @State private var viewHeight: CGFloat = 0

    private var paper: Bool { appearance == AppAppearance.paper.rawValue }
    /// The rule spacing on paper, and 0 otherwise, which leaves text and rows as they are.
    private var rp: CGFloat { paper ? pitch : 0 }

    var body: some View {
        Group {
            if let meeting = store.meeting(id) {
                content(meeting)
            } else {
                Text("Meeting deleted").foregroundStyle(.secondary)
            }
        }
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
            if paper {
                paperPage(meeting, minHeight: viewHeight)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock(meeting)
                    if showPlayer && !editing { playerBar(meeting) }
                    speakersCard(meeting)
                    if meeting.isBusy {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(busyText(meeting.status))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = meeting.errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            Button("Try again") { Task { await store.process(id) } }
                                .buttonStyle(.bordered)
                        }
                    }
                    notesBody(meeting)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .padding(.bottom, meeting.notes != nil ? 90 : 0)
            }
        }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { viewHeight = g.size.height }
                    .onChange(of: g.size.height) { viewHeight = $0 }
            }
        }
        .background {
            if paper { PaperBackground() }
        }
        .overlay(alignment: .bottom) {
            if meeting.notes != nil { bottomBar(meeting) }
        }
        .navigationDestination(isPresented: $showTranscript) { TranscriptScreen(id: id) }
        .overlay {
            if showUsage {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { showUsage = false }
                    UsageBubble(usage: meeting.usage ?? []) { showUsage = false }
                        .padding(.horizontal, 20)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $asking) { AskMeetingView(meeting: meeting) }
        .sheet(isPresented: $askingVoices) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How many people spoke?")
                        .font(.title3.weight(.bold))
                    Text("If you know, say so and the voices are grouped into exactly that many. Choose Auto to let the app decide.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker("People", selection: $voiceCount) {
                        Text("Auto").tag(0)
                        ForEach(2...12, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    Button {
                        askingVoices = false
                        startRegenerate(meeting, transcript: true)
                    } label: {
                        Text("Re-transcribe").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel) { askingVoices = false }
                        .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("Send these notes to", isPresented: $pickingAccount, titleVisibility: .visible) {
            ForEach(OutlookSettings.accounts) { account in
                Button(account.name) { send(meeting, to: account) }
            }
            Button("Custom\u{2026}") { customEmail = ""; customAddress = true }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Send to an email address", isPresented: $customAddress) {
            TextField("name@example.com", text: $customEmail)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send") {
                let email = customEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = OutlookAccount(name: email, email: email)
                if target.isValid { send(meeting, to: target) } else { sendError = "\u{201C}\(email)\u{201D} isn't a full email address." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The notes and the Word document go to this address once. It isn't saved.")
        }
        .alert("Set up sending first", isPresented: $noAccounts) {
            Button("Open Settings") { showSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(setupMessage)
        }
        .alert("Could not send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
        .confirmationDialog("This replaces your edits", isPresented: Binding(
            get: { pendingRegenerate != nil }, set: { if !$0 { pendingRegenerate = nil } }),
            titleVisibility: .visible) {
            Button("Redraft and replace my edits", role: .destructive) {
                let regenerate = pendingRegenerate ?? false
                pendingRegenerate = nil
                Task { await store.process(id, regenerateTranscript: regenerate, voiceCount: voiceCount > 1 ? voiceCount : nil) }
            }
            Button("Cancel", role: .cancel) { pendingRegenerate = nil }
        } message: {
            Text("The notes will be written again from the transcript. Text you typed will be lost.")
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .overlay {
            if sending {
                ProgressView("Sending…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.items).ignoresSafeArea() }
        .sheet(isPresented: $showWhoIsWho) { WhoIsWhoView(meetingID: id) }
        .sheet(isPresented: $editingTags) { TagsView(meetingID: id) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if meeting.notes != nil {
                    Button(editing ? "Done" : "Edit") {
                        if editing { store.flush() }
                        editing.toggle()
                    }
                    .fontWeight(editing ? .bold : .regular)
                }
                Menu {
                    if let notes = meeting.notes {
                        ShareLink(item: notes.markdown(title: meeting.title, date: meeting.date)) {
                            Label("Share notes", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = notes.markdown(title: meeting.title, date: meeting.date)
                        } label: { Label("Copy notes", systemImage: "doc.on.doc") }
                    }
                    if meeting.notes != nil {
                        Button { shareWord(meeting) } label: {
                            Label("Share Word document", systemImage: "doc.richtext")
                        }
                    }
                    if let transcript = meeting.transcript, !transcript.isEmpty {
                        ShareLink(item: transcript) {
                            Label("Share transcript", systemImage: "text.alignleft")
                        }
                    }
                    Button { newTitle = meeting.title; renaming = true } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button { editingTags = true } label: {
                        Label("Tags…", systemImage: "tag")
                    }
                    Button { showWhoIsWho = true } label: {
                        Label(meeting.hasVoices ? "Who's who…" : "Attendees…", systemImage: "person.2")
                    }
                    .disabled(meeting.isBusy)
                    Button { regenerate(meeting, transcript: false) } label: {
                        Label("Redraft notes", systemImage: "sparkles")
                    }
                    .disabled(meeting.isBusy)
                    Button { regenerate(meeting, transcript: true) } label: {
                        Label("Re-transcribe and find voices", systemImage: "arrow.clockwise")
                    }
                    .disabled(meeting.isBusy)
                    Button { showUsage = true } label: {
                        Label("Token usage", systemImage: "clock")
                    }
                    Button(role: .destructive) {
                        store.delete(id)
                        dismiss()
                    } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { store.update(id) { $0.title = t; $0.titleEdited = true } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Writes the Word document to a temporary file so it can be shared with its proper name.
    private func wordFile(_ meeting: Meeting) -> URL? {
        guard let notes = meeting.notes else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(MeetingDocx.fileName(for: meeting))
        do {
            try MeetingDocx.data(for: meeting, notes: notes).write(to: url, options: .atomic)
            return url
        } catch {
            sendError = "The Word document could not be created."
            return nil
        }
    }

    /// Opens the share sheet with the recording, named after the meeting, so it can be saved to Files.
    private func shareAudio(_ meeting: Meeting) {
        let source = MeetingStore.audioURL(for: meeting.audioFile)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(exportFileName(meeting.title, fallback: "Recording", ext: "m4a"))
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            share = ShareItems(items: [copy])
        } catch {
            sendError = "The recording could not be prepared for download."
        }
    }

    private func shareWord(_ meeting: Meeting) {
        if let url = wordFile(meeting) { share = ShareItems(items: [url]) }
    }

    private var setupMessage: String {
        "Add your Gmail address and app password under Send to Outlook in Settings, so the app can send as you."
    }

    private func regenerate(_ meeting: Meeting, transcript: Bool) {
        if transcript { voiceCount = meeting.voices?.count ?? 0; askingVoices = true; return }
        startRegenerate(meeting, transcript: false)
    }

    private func startRegenerate(_ meeting: Meeting, transcript: Bool) {
        if meeting.notesEdited == true { pendingRegenerate = transcript } else {
            Task { await store.process(id, regenerateTranscript: transcript, voiceCount: voiceCount > 1 ? voiceCount : nil) }
        }
    }

    /// Sends the notes as they are on screen, edits included, with the Word document attached.
    private func send(_ meeting: Meeting, to account: OutlookAccount) {
        guard let notes = store.meeting(id)?.notes else { return }
        let current = store.meeting(id) ?? meeting
        let subject = MeetingExport.subject(current)
        let html = MeetingExport.html(for: current, notes: notes)
        let plain = MeetingExport.plainText(for: current, notes: notes)
        let attachment = GmailMailer.Attachment(
            name: MeetingDocx.fileName(for: current), mimeType: MeetingDocx.mimeType,
            data: MeetingDocx.data(for: current, notes: notes))
        let credentials = GmailMailer.Credentials(address: MailSettings.address, appPassword: MailSettings.appPassword)

        sending = true
        Task {
            do {
                try await GmailMailer.send(from: credentials, to: account, subject: subject,
                                           html: html, plain: plain, attachment: attachment)
                withAnimation { toast = "Sent to \(account.name)" }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { toast = nil }
            } catch {
                sendError = error.localizedDescription
            }
            sending = false
        }
    }

    @ViewBuilder
    private func speakersCard(_ meeting: Meeting) -> some View {
        if meeting.status == .done || meeting.status == .failed {
            if meeting.voicesNeedIdentifying {
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(meeting.voices?.count ?? 0) voices found", systemImage: "person.2.wave.2")
                        .font(.headline)
                    Text("Say who is who and the notes will update with real names.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Who's who?") { showWhoIsWho = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            } else if meeting.hasVoices, let voices = meeting.voices {
                HStack(spacing: 8) {
                    ForEach(voices) { voice in
                        HStack(spacing: 5) {
                            Circle().fill(speakerColor(voice.id)).frame(width: 8, height: 8)
                            Text(voice.label).font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Button("Edit") { showWhoIsWho = true }.font(.footnote)
                }
            }
            if let note = meeting.voiceNote {
                Text(note).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func busyText(_ status: MeetingStatus) -> String {
        switch status {
        case .transcribing: return "Converting audio to text… (the first time, a speech model downloads once, about half a gigabyte)"
        case .diarizing: return "Finding who spoke… (the first time, voice models download once)"
        default: return "Drafting notes…"
        }
    }

    /// The meeting on a legal pad: title, date and buttons in the open header, the notes on the rules below.
    private func paperPage(_ meeting: Meeting, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            paperTitle(meeting)
                .padding(.leading, Paper.textX)
                .padding(.trailing, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { headerHeight = g.size.height }
                        .onChange(of: g.size.height) { headerHeight = $0 }
                })
            VStack(alignment: .leading, spacing: 0) {
                if showPlayer && !editing { playerBar(meeting).snapToRules(pitch) }
                speakersCard(meeting).snapToRules(pitch)
                if meeting.isBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(busyText(meeting.status))
                            .foregroundStyle(.secondary)
                            .onRules(.body, pitch: pitch)
                    }
                    .snapToRules(pitch)
                }
                if let error = meeting.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Try again") { Task { await store.process(id) } }
                            .buttonStyle(.bordered)
                    }
                    .snapToRules(pitch)
                }
                notesBody(meeting)
            }
            .padding(.leading, Paper.textX)
            .padding(.trailing, 16)
            .padding(.top, Paper.lead(pitch))
            .padding(.bottom, meeting.notes != nil ? 90 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(alignment: .top) { PaperRules(pitch: pitch, from: headerHeight, topLine: true) }
    }

    private func paperTitle(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                newTitle = meeting.title
                renaming = true
            } label: {
                Text(meeting.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(typeSize >= .accessibility1 ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(dateLine(meeting))
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                titleButtons(meeting)
            }
        }
    }

    private func dateLine(_ meeting: Meeting) -> String {
        let line = "\(meeting.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) \u{00B7} \(meeting.date.formatted(date: .omitted, time: .shortened)) \u{00B7} \(formatDuration(meeting.duration))"
        guard let tags = meeting.tags, !tags.isEmpty else { return line }
        return line + " \u{00B7} " + tags.map { "#\($0)" }.joined(separator: " ")
    }

    private var buttonFill: Color { paper ? Color.white.opacity(0.5) : Color(.secondarySystemGroupedBackground) }

    private func titleBlock(_ meeting: Meeting) -> some View {
        let name = Button {
            newTitle = meeting.title
            renaming = true
        } label: {
            Text(meeting.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.leading)
                .lineLimit(typeSize >= .accessibility1 ? 3 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        let date = Text(dateLine(meeting))
            .font(.footnote).foregroundStyle(.secondary)
            .lineLimit(typeSize >= .accessibility1 ? 2 : 1)
        return Group {
            if typeSize >= .accessibility1 {
                VStack(alignment: .leading, spacing: 6) {
                    name
                    date
                    HStack(spacing: 8) { titleButtons(meeting) }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        name
                        date
                    }
                    HStack(spacing: 8) { titleButtons(meeting) }
                }
            }
        }
    }

    @ViewBuilder
    private func titleButtons(_ meeting: Meeting) -> some View {
        if !meeting.audioFile.isEmpty {
            Button { withAnimation { showPlayer.toggle() } } label: {
                Image(systemName: "waveform")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(showPlayer ? Color.white : Color.accentColor)
                    .background(showPlayer ? Color.accentColor : buttonFill, in: Circle())
            }
            .accessibilityLabel("Recording")
        }
        if let t = meeting.transcript, !t.isEmpty {
            Button { showTranscript = true } label: {
                Image(systemName: "doc.text")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color.accentColor)
                    .background(buttonFill, in: Circle())
            }
            .accessibilityLabel("Transcript")
        }
    }

    private func playerBar(_ meeting: Meeting) -> some View {
        let url = MeetingStore.audioURL(for: meeting.audioFile)
        return HStack(spacing: 10) {
            Button { playingKey = nil; player.toggle(url: url) } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0, url: url) }),
                   in: 0...max(player.duration, meeting.duration, 1))
            Text("\(formatDuration(player.currentTime)) / \(formatDuration(max(player.duration, meeting.duration)))")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Button { shareAudio(meeting) } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Download recording")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(buttonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bottomBar(_ meeting: Meeting) -> some View {
        Group {
            if editing {
                Text("Tap any text to change it. What you see here is what gets emailed.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 10)
            } else {
                HStack(spacing: 10) {
                    Button { asking = true } label: {
                        Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 13)
                            .background(paper ? Color.white.opacity(0.6) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button {
                        if !MailSettings.isConfigured { noAccounts = true } else { pickingAccount = true }
                    } label: {
                        Label("Send to Outlook", systemImage: "paperplane.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [(paper ? Paper.canary : Color(.systemBackground)).opacity(0),
                                    paper ? Paper.canary : Color(.systemBackground)],
                           startPoint: .top, endPoint: .center))
    }

    @ViewBuilder
    private func notesBody(_ meeting: Meeting) -> some View {
        if let notes = meeting.notes {
            section("Summary") {
                editor(Binding(get: { store.meeting(id)?.notes?.summary ?? "" },
                               set: { v in store.updateNotes(id) { $0.summary = v } }), "Summary")
            }
            editableList("Attendees", \.attendees, notes)
            if let topics = notes.topics, !topics.isEmpty {
                topicsEditor(topics)
            } else {
                editableList("Discussion", \.discussion, notes)
            }
            editableList("Decisions", \.decisions, notes, timePrefix: "d:")
            if editing || !notes.actionItems.isEmpty { section("Action items") {
                VStack(alignment: .leading, spacing: paper ? 0 : 12) {
                    ForEach(notes.actionItems) { item in actionItemEditor(item) }
                    addButton("Add action item") {
                        store.updateNotes(id) { $0.actionItems.append(ActionItem(task: "")) }
                    }
                    .snapToRules(rp)
                }
            } }
            editableList("Open questions", \.openQuestions, notes)
            editableList("Next steps", \.nextSteps, notes)
        } else if !meeting.isBusy && meeting.errorMessage == nil {
            Text("No notes yet.").foregroundStyle(.secondary).onRules(.body, pitch: rp)
        }
    }

    /// Plain text when reading; a gray field when editing.
    @ViewBuilder
    private func editor(_ text: Binding<String>, _ prompt: String, style: UIFont.TextStyle = .body) -> some View {
        if editing {
            TextField(prompt, text: text, axis: .vertical)
                .padding(8)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text(text.wrappedValue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onRules(style, pitch: rp)
        }
    }

    /// A small play button that jumps the audio to where a note was said. Shown only in the app.
    @ViewBuilder
    private func timeButton(_ key: String) -> some View {
        if !editing, let m = store.meeting(id), let t = m.notes?.times?[key], !m.audioFile.isEmpty {
            let active = playingKey == key
            let isPlayingNow = active && player.isPlaying
            Button {
                if isPlayingNow {
                    player.pause()
                } else if active {
                    player.resume()
                } else {
                    playingKey = key
                    player.play(url: MeetingStore.audioURL(for: m.audioFile), from: max(0, t - 1))
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isPlayingNow ? "pause.circle.fill" : "play.circle.fill")
                    Text(formatDuration(t)).font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, paper ? 0 : 3)
            .accessibilityLabel(isPlayingNow ? "Pause" : "Play from \(formatDuration(t))")
        }
    }

    @ViewBuilder
    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        if editing {
            Button(action: action) { Label(title, systemImage: "plus.circle") }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func removeButton(_ label: String = "Remove", top: CGFloat = 8, action: @escaping () -> Void) -> some View {
        Group {
            if editing {
                Button(action: action) { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).padding(.top, top)
                    .accessibilityLabel(label)
            }
        }
    }

    private func itemBinding(_ keyPath: WritableKeyPath<MeetingNotes, [String]>, _ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let notes = store.meeting(id)?.notes, notes[keyPath: keyPath].indices.contains(index) else { return "" }
                return notes[keyPath: keyPath][index]
            },
            set: { value in
                store.updateNotes(id) { if $0[keyPath: keyPath].indices.contains(index) { $0[keyPath: keyPath][index] = value } }
            })
    }

    @ViewBuilder
    private func editableList(_ title: String, _ keyPath: WritableKeyPath<MeetingNotes, [String]>,
                              _ notes: MeetingNotes, timePrefix: String? = nil) -> some View {
        if editing || !notes[keyPath: keyPath].filter({ !$0.isEmpty }).isEmpty {
            section(title) {
                VStack(alignment: .leading, spacing: paper ? 0 : 6) {
                    ForEach(Array(notes[keyPath: keyPath].indices), id: \.self) { index in
                        HStack(alignment: paper ? .firstTextBaseline : .top, spacing: paper ? 0 : 8) {
                            bullet("\u{2022}")
                            editor(itemBinding(keyPath, index), title)
                            if let timePrefix { timeButton("\(timePrefix)\(index)") }
                            removeButton {
                                store.updateNotes(id) {
                                    if $0[keyPath: keyPath].indices.contains(index) {
                                        $0[keyPath: keyPath].remove(at: index)
                                        if let timePrefix { $0.dropTime(prefix: timePrefix, removed: index) }
                                    }
                                }
                            }
                        }
                        .snapToRules(rp)
                    }
                    addButton("Add") { store.updateNotes(id) { $0[keyPath: keyPath].append("") } }
                        .snapToRules(rp)
                }
            }
        }
    }

    private func topicsEditor(_ topics: [DiscussionTopic]) -> some View {
        func topic(_ tid: UUID, _ change: @escaping (inout DiscussionTopic) -> Void) {
            store.updateNotes(id) { n in
                guard var list = n.topics, let i = list.firstIndex(where: { $0.id == tid }) else { return }
                change(&list[i]); n.topics = list
            }
        }
        return section("Discussion") {
            VStack(alignment: .leading, spacing: paper ? 0 : (editing ? 16 : 14)) {
                ForEach(topics) { t in
                    VStack(alignment: .leading, spacing: paper ? 0 : 6) {
                        HStack(alignment: .top) {
                            editor(Binding(
                                get: { store.meeting(id)?.notes?.topics?.first { $0.id == t.id }?.title ?? "" },
                                set: { v in topic(t.id) { $0.title = v } }), "Topic", style: .subheadline)
                                .font(.subheadline.weight(.semibold))
                            removeButton("Remove topic") {
                                store.updateNotes(id) { $0.topics?.removeAll { $0.id == t.id } }
                            }
                        }
                        .snapToRules(rp)
                        ForEach(Array(t.points.indices), id: \.self) { index in
                            VStack(alignment: .leading, spacing: paper ? 0 : 4) {
                                HStack(alignment: paper ? .firstTextBaseline : .top, spacing: paper ? 0 : 8) {
                                    bullet("\u{2022}")
                                    editor(Binding(
                                        get: {
                                            let p = store.meeting(id)?.notes?.topics?.first { $0.id == t.id }?.points ?? []
                                            return p.indices.contains(index) ? p[index] : ""
                                        },
                                        set: { v in topic(t.id) { if $0.points.indices.contains(index) { $0.points[index] = v } } }), "Point")
                                    timeButton("p:\(t.id):\(index)")
                                    removeButton {
                                        store.updateNotes(id) { n in
                                            guard var list = n.topics, let i = list.firstIndex(where: { $0.id == t.id }),
                                                  list[i].points.indices.contains(index) else { return }
                                            list[i].removePoint(at: index)
                                            n.topics = list
                                            n.dropTime(prefix: "p:\(t.id):", removed: index)
                                        }
                                    }
                                }
                                .snapToRules(rp)
                                ForEach(Array(t.subPoints(at: index).indices), id: \.self) { sIndex in
                                    HStack(alignment: paper ? .firstTextBaseline : .top, spacing: 8) {
                                        Text("\u{2013}").foregroundStyle(.secondary).padding(.top, editing && !paper ? 8 : 0)
                                        editor(Binding(
                                            get: {
                                                let s = store.meeting(id)?.notes?.topics?.first { $0.id == t.id }?.subPoints(at: index) ?? []
                                                return s.indices.contains(sIndex) ? s[sIndex] : ""
                                            },
                                            set: { v in topic(t.id) {
                                                $0.padSubs()
                                                if $0.subs?[index].indices.contains(sIndex) == true { $0.subs?[index][sIndex] = v }
                                            } }), "Sub-point", style: .subheadline)
                                            .font(.subheadline)
                                            .foregroundStyle(editing ? Color.primary : Color.secondary)
                                        removeButton("Remove sub-point") {
                                            topic(t.id) {
                                                $0.padSubs()
                                                if $0.subs?[index].indices.contains(sIndex) == true { $0.subs?[index].remove(at: sIndex) }
                                            }
                                        }
                                    }
                                    .padding(.leading, 18)
                                    .snapToRules(rp)
                                }
                                if editing {
                                    Button {
                                        topic(t.id) { $0.padSubs(); $0.subs?[index].append("") }
                                    } label: { Label("Add sub-point", systemImage: "plus.circle") }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 22)
                                        .snapToRules(rp)
                                }
                            }
                        }
                        addButton("Add point") { topic(t.id) { $0.points.append("") } }
                            .snapToRules(rp)
                    }
                }
                addButton("Add topic") {
                    store.updateNotes(id) { $0.topics = ($0.topics ?? []) + [DiscussionTopic(title: "", points: [""])] }
                }
                .snapToRules(rp)
            }
        }
    }

    private func actionItemEditor(_ item: ActionItem) -> some View {
        func field(_ keyPath: WritableKeyPath<ActionItem, String?>) -> Binding<String> {
            Binding(
                get: { store.meeting(id)?.notes?.actionItems.first { $0.id == item.id }?[keyPath: keyPath] ?? "" },
                set: { value in
                    store.updateNotes(id) { n in
                        if let i = n.actionItems.firstIndex(where: { $0.id == item.id }) {
                            n.actionItems[i][keyPath: keyPath] = value.isEmpty ? nil : value
                        }
                    }
                })
        }
        let task = Binding<String>(
            get: { store.meeting(id)?.notes?.actionItems.first { $0.id == item.id }?.task ?? "" },
            set: { value in
                store.updateNotes(id) { n in
                    if let i = n.actionItems.firstIndex(where: { $0.id == item.id }) { n.actionItems[i].task = value }
                }
            })
        let who = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        return HStack(alignment: paper ? .firstTextBaseline : .top, spacing: paper ? 0 : 10) {
            Button {
                store.update(id) { m in
                    if let i = m.notes?.actionItems.firstIndex(where: { $0.id == item.id }) { m.notes?.actionItems[i].done.toggle() }
                }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, editing && !paper ? 6 : 0)
            .fixedSize()
            .frame(width: paper ? 0 : nil, alignment: .trailing)
            .offset(x: paper ? -16 : 0)
            VStack(alignment: .leading, spacing: paper ? 0 : 4) {
                editor(task, "Action item")
                if editing {
                    HStack(spacing: 8) {
                        TextField("Owner", text: field(\.owner)).font(.caption)
                            .padding(6).background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 7))
                        TextField("Due", text: field(\.due)).font(.caption)
                            .padding(6).background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 7))
                    }
                } else {
                    HStack(spacing: 6) {
                        if !who.isEmpty { Text(who).font(.caption).foregroundStyle(.secondary).onRules(.caption1, pitch: rp) }
                        timeButton("a:\(item.id)")
                    }
                }
            }
            removeButton(top: 6) {
                store.updateNotes(id) { $0.actionItems.removeAll { $0.id == item.id } }
            }
        }
        .snapToRules(rp)
    }

    /// A list mark. On paper it hangs in the left margin, like a bullet written before the red lines.
    private func bullet(_ mark: String) -> some View {
        Text(mark)
            .foregroundStyle(.secondary)
            .padding(.top, editing && !paper ? 8 : 0)
            .fixedSize()
            .frame(width: paper ? 0 : nil, alignment: .trailing)
            .offset(x: paper ? -18 : 0)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: paper ? 0 : 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .onRules(.caption1, pitch: rp)
            body()
        }
        .snapToRules(rp)
        .padding(.bottom, rp)
    }
}

/// A steady color for each voice, so turns are easy to follow.
func speakerColor(_ id: String?) -> Color {
    let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
    guard let id, let n = Int(id) else { return .secondary }
    return palette[(n - 1 + palette.count) % palette.count]
}

/// A file name made from a meeting's title, with characters Files won't accept taken out.
func exportFileName(_ title: String, fallback: String, ext: String) -> String {
    let cleaned = title
        .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (cleaned.isEmpty ? fallback : String(cleaned.prefix(80))) + "." + ext
}

/// The full transcript, opened from the document button on a meeting.
struct TranscriptScreen: View {
    let id: UUID
    @EnvironmentObject private var store: MeetingStore
    @StateObject private var player = AudioPlayer()
    @State private var playingLine: UUID?
    @State private var share: ShareItems?
    @State private var shareError: String?
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @PaperPitch private var pitch
    @State private var headerHeight: CGFloat = 0
    @State private var viewHeight: CGFloat = 0

    private var paper: Bool { appearance == AppAppearance.paper.rawValue }
    private var rp: CGFloat { paper ? pitch : 0 }

    var body: some View {
        ScrollView {
            if let meeting = store.meeting(id) {
                if paper {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcript").font(.title2.weight(.bold))
                            Text(meeting.title).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.leading, Paper.textX)
                        .padding(.trailing, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { headerHeight = g.size.height }
                                .onChange(of: g.size.height) { headerHeight = $0 }
                        })
                        VStack(alignment: .leading, spacing: 0) {
                            content(meeting)
                        }
                        .padding(.leading, Paper.textX)
                        .padding(.trailing, 16)
                        .padding(.top, Paper.lead(pitch))
                        .padding(.bottom, pitch)
                    }
                    .frame(maxWidth: .infinity, minHeight: viewHeight, alignment: .topLeading)
                    .background(alignment: .top) { PaperRules(pitch: pitch, from: headerHeight, topLine: true) }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Transcript").font(.title2.weight(.bold))
                        Text(meeting.title).font(.footnote).foregroundStyle(.secondary)
                        content(meeting)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { viewHeight = g.size.height }
                    .onChange(of: g.size.height) { viewHeight = $0 }
            }
        }
        .background {
            if paper { PaperBackground() }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let meeting = store.meeting(id), !(meeting.transcript ?? "").isEmpty {
                    Button { shareTranscript(meeting) } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Download transcript")
                }
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.items).ignoresSafeArea() }
        .alert("Transcript", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .onDisappear { player.stop() }
    }

    /// The transcript as plain text: who spoke and when, one turn per paragraph.
    private func transcriptText(_ meeting: Meeting) -> String {
        let lines = (meeting.hasVoices ? meeting.lines : meeting.timeline) ?? []
        let header = "\(meeting.title)\n\(meeting.date.formatted(date: .long, time: .shortened))\n\n"
        guard !lines.isEmpty else { return header + (meeting.transcript ?? "") + "\n" }
        let body = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { line in
            let who = (meeting.hasVoices && line.speaker != nil) ? " \(meeting.label(for: line.speaker)):" : ""
            return "[\(formatDuration(line.start))]\(who) \(line.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n")
        return header + body + "\n"
    }

    /// Opens the share sheet with the transcript as a text file named after the meeting, so it can be saved to Files.
    private func shareTranscript(_ meeting: Meeting) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(exportFileName(meeting.title + " transcript", fallback: "Transcript", ext: "txt"))
        do {
            try transcriptText(meeting).write(to: url, atomically: true, encoding: .utf8)
            share = ShareItems(items: [url])
        } catch {
            shareError = "The transcript could not be prepared for download."
        }
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        let lines = meeting.hasVoices ? (meeting.lines ?? []) : (meeting.timeline ?? [])
        if !lines.isEmpty {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: paper ? 0 : 2) {
                    HStack {
                        if line.speaker != nil {
                            Text(meeting.label(for: line.speaker))
                                .font(.caption.weight(.bold))
                                .foregroundColor(speakerColor(line.speaker))
                        }
                        Spacer()
                        if !meeting.audioFile.isEmpty {
                            let active = playingLine == line.id
                            let now = active && player.isPlaying
                            Button {
                                if now {
                                    player.pause()
                                } else if active {
                                    player.resume()
                                } else {
                                    playingLine = line.id
                                    player.play(url: MeetingStore.audioURL(for: meeting.audioFile), from: line.start)
                                }
                            } label: {
                                Label(formatDuration(line.start), systemImage: now ? "pause.fill" : "play.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .snapToRules(rp)
                    Text(line.text).textSelection(.enabled)
                        .onRules(.body, pitch: rp)
                        .snapToRules(rp)
                }
            }
        } else if let transcript = meeting.transcript, !transcript.isEmpty {
            Text(transcript).textSelection(.enabled).onRules(.body, pitch: rp)
        } else {
            Text("No speech was found.").foregroundStyle(.secondary).onRules(.body, pitch: rp)
        }
    }
}

/// The overlay behind the Token usage menu item.
struct UsageBubble: View {
    let usage: [TokenUsage]
    let close: () -> Void

    private var total: Int { usage.reduce(0) { $0 + $1.total } }
    private var cost: Double? {
        var sum = 0.0
        for u in usage { guard let c = u.estimatedCost else { return nil }; sum += c }
        return sum
    }
    private var cacheRead: Int { usage.reduce(0) { $0 + $1.cacheRead } }

    private func costText(_ c: Double) -> String {
        c < 0.01 ? "under 1\u{00A2}" : c < 1 ? "\(Int((c * 100).rounded()))\u{00A2}" : String(format: "$%.2f", c)
    }

    private func line(_ title: String, _ items: [TokenUsage]) -> some View {
        let input = items.reduce(0) { $0 + $1.allInput }
        let output = items.reduce(0) { $0 + $1.output }
        return VStack(spacing: 2) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text((input + output).formatted()).font(.subheadline.weight(.bold).monospacedDigit())
            }
            HStack {
                Text("\(input.formatted()) in \u{00B7} \(output.formatted()) out")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Token usage").font(.headline)
                Spacer()
                Button("Done", action: close).fontWeight(.semibold)
            }
            if usage.isEmpty {
                VStack(spacing: 6) {
                    Text("No usage recorded yet").font(.subheadline.weight(.semibold))
                    Text("Usage is recorded from this version on. Redraft the notes or ask a question and it will show up here.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                Text(total.formatted())
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                Text("tokens used on this meeting").font(.footnote).foregroundStyle(.secondary)
                if let cost {
                    (Text("About \(costText(cost)) at list price ").fontWeight(.semibold)
                     + Text("(estimate)").foregroundColor(.secondary))
                        .font(.subheadline)
                        .padding(.vertical, 4)
                }
                Divider()
                let drafts = usage.filter { $0.kind == .draft }
                let redrafts = usage.filter { $0.kind == .redraft }
                let questions = usage.filter { $0.kind == .question }
                if !drafts.isEmpty { line("Notes draft", drafts); Divider() }
                if !redrafts.isEmpty { line(redrafts.count == 1 ? "Redraft" : "Redrafts \u{00B7} \(redrafts.count)", redrafts); Divider() }
                if !questions.isEmpty {
                    line("Ask This Meeting \u{00B7} \(questions.count) question\(questions.count == 1 ? "" : "s")", questions)
                }
                if cacheRead > 0 {
                    Text("Caching saved about \(cacheRead.formatted()) input tokens on follow-up questions.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                        .padding(.top, 4)
                }
                Text("Counts come from Anthropic's response to each request. Transcription and voice separation run on your phone and use none.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}
