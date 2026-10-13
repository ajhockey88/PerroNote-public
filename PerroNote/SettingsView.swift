import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var people: PeopleStore
    @State private var confirmForget = false
    @State private var senderAddress = MailSettings.address
    @State private var appPassword = MailSettings.appPassword
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SpeakerDiarizer.sensitivityKey) private var voiceSensitivity = 1
    @AppStorage(Transcriber.engineKey) private var engine = 0
    @State private var testing = false
    @State private var testResult: String?
    @State private var apiKey = Keychain.get(NotesGenerator.apiKeyName) ?? ""
    @State private var model = UserDefaults.standard.string(forKey: NotesGenerator.modelDefaultsKey) ?? ""
    @State private var accounts = OutlookSettings.accounts
    @AppStorage(Vocabulary.key) private var vocabulary = ""
    @AppStorage(BannerSettings.showKey) private var showBanner = true
    @AppStorage(BannerSettings.dueKey) private var bannerDue = BannerSettings.Due.all.rawValue
    @AppStorage(BannerSettings.peopleKey) private var bannerPeople = ""
    @AppStorage(BannerSettings.myNameKey) private var myName = ""
    @AppStorage(DueAlerts.enabledKey) private var dueAlerts = false
    @AppStorage(DueAlerts.timeKey) private var dueAlertMinutes = 8 * 60
    @EnvironmentObject private var store: MeetingStore
    @State private var alertsDenied = false
    @AppStorage(WebSync.enabledKey) private var webSync = false
    @AppStorage(WebSync.repoKey) private var webRepo = ""
    @State private var webToken = WebSync.token
    @State private var webSyncing = false

    private var bannerPeopleSummary: String {
        let chosen = BannerSettings.people(from: bannerPeople)
        if chosen.isEmpty { return "Everyone" }
        let names = chosen.map { $0 == BannerSettings.me ? "Me" : $0 }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names[0]) + \(names.count - 1) more"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your iPhone's Light or Dark setting. Paper puts every screen except Settings on a yellow legal pad.")
                }
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Used to draft notes from the transcript. It is stored in the iPhone Keychain and sent only to api.anthropic.com. Get one at console.anthropic.com.")
                }

                Section {
                    TextField(NotesGenerator.defaultModel, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Model")
                } footer: {
                    Text("Leave blank to use \(NotesGenerator.defaultModel).")
                }

                Section {
                    Toggle("Show on the meetings page", isOn: $showBanner)
                    TextField("Your name, like Anthony Perrone", text: $myName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    NavigationLink {
                        BannerPeopleView()
                    } label: {
                        LabeledContent("Whose items", value: bannerPeopleSummary)
                    }
                    Picker("Due", selection: $bannerDue) {
                        ForEach(BannerSettings.Due.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } header: {
                    Text("Action items banner")
                } footer: {
                    Text("The card at the top of the meetings page. Choose whose action items it counts (pick as many as you like) and which due dates. Your name lets it find items assigned to you.")
                }

                Section {
                    Toggle("Due date alerts", isOn: Binding(get: { dueAlerts }, set: { on in
                        if on {
                            Task {
                                if await DueAlerts.requestPermission() {
                                    dueAlerts = true
                                    store.refreshAlerts()
                                } else {
                                    alertsDenied = true
                                }
                            }
                        } else {
                            dueAlerts = false
                            store.refreshAlerts()
                        }
                    }))
                    if dueAlerts {
                        DatePicker("Each morning at", selection: Binding(
                            get: { Calendar.current.date(byAdding: .minute, value: dueAlertMinutes, to: Calendar.current.startOfDay(for: Date())) ?? Date() },
                            set: { d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                dueAlertMinutes = (c.hour ?? 8) * 60 + (c.minute ?? 0)
                                store.refreshAlerts()
                            }), displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("One alert a day when action items are overdue, due today or due tomorrow. It counts the same people as the banner. Worked out on this phone; nothing is sent anywhere.")
                }
                .alert("Notifications are off", isPresented: $alertsDenied) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Turn on notifications for PerroNote in the iPhone Settings app, then try again.")
                }

                Section {
                    Toggle("Sync notes to the web", isOn: $webSync)
                    if webSync {
                        TextField(WebSync.defaultRepo, text: $webRepo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("GitHub token", text: $webToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: webToken) { value in
                                Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: WebSync.tokenKey)
                            }
                        Button {
                            webSyncing = true
                            Task {
                                await store.syncNow()
                                webSyncing = false
                            }
                        } label: {
                            if webSyncing { ProgressView() } else { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                        }
                        .disabled(webToken.isEmpty || webSyncing)
                        if !store.syncStatus.isEmpty {
                            Text(store.syncStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Link(destination: WebSync.siteURL) {
                            Label("Open PerroNote on the web", systemImage: "safari")
                        }
                    }
                } header: {
                    Text("Web sync")
                } footer: {
                    Text("Sends each meeting's notes and your action items to a private GitHub repo, so you can read and edit them at ajhockey88.github.io/PerroNote-public. Edits made there come back to the app. Audio and transcripts stay on this phone. The token is kept in the iPhone Keychain.")
                }
                .onChange(of: webSync) { on in if on { store.scheduleSync(after: 0.5) } }

                Section {
                    TextField("Morgan, Kubernetes, Q3 OKRs", text: $vocabulary, axis: .vertical)
                        .lineLimit(3...8)
                        .autocorrectionDisabled()
                } header: {
                    Text("Custom vocabulary")
                } footer: {
                    Text("Names, acronyms and product words that come up in your meetings, one per line or separated by commas. Speech recognition listens for them and the notes use these spellings.")
                }

                Section {
                    ForEach($accounts) { $account in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Name (for example Work)", text: $account.name)
                                .font(.body.weight(.semibold))
                            TextField("name@example.com", text: $account.email)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(.secondary)
                            if !account.email.isEmpty && !account.isValid {
                                Text("Enter a full email address.")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { accounts.remove(atOffsets: $0) }
                    Button { accounts.append(OutlookAccount()) } label: {
                        Label("Add account", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Send to Outlook: who to send to")
                } footer: {
                    Text("Send to Outlook lists these by name. Tap a name and the notes are emailed straight away to that address, with the Word document attached.")
                }

                Section {
                    TextField("you@gmail.com", text: $senderAddress)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Google app password", text: $appPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        testing = true
                        let credentials = GmailMailer.Credentials(
                            address: senderAddress.trimmingCharacters(in: .whitespaces),
                            appPassword: appPassword.filter { !$0.isWhitespace })
                        let target = OutlookAccount(name: "Me", email: credentials.address)
                        Task {
                            do {
                                try await GmailMailer.send(
                                    from: credentials, to: target, subject: "PerroNote test email",
                                    html: "<p>This is a test from PerroNote. Sending is set up.</p>",
                                    plain: "This is a test from PerroNote. Sending is set up.", attachment: nil)
                                testResult = "A test email was sent to \(credentials.address)."
                            } catch {
                                testResult = error.localizedDescription
                            }
                            testing = false
                        }
                    } label: {
                        if testing { ProgressView() } else { Label("Send a test email to myself", systemImage: "paperplane") }
                    }
                    .disabled(senderAddress.isEmpty || appPassword.isEmpty || testing)
                    NavigationLink("How to get a Google app password") { GmailSetupView() }
                } header: {
                    Text("Send to Outlook: sent from")
                } footer: {
                    Text("Emails go out from this Gmail account. The app password is kept in the iPhone Keychain, and you can delete it any time at myaccount.google.com/apppasswords.")
                }
                .alert("Test email", isPresented: Binding(get: { testResult != nil }, set: { if !$0 { testResult = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(testResult ?? "")
                }

                Section {
                    Toggle("Remember voices", isOn: Binding(
                        get: { people.rememberVoices },
                        set: { people.rememberVoices = $0 }))
                    ForEach(people.people) { person in
                        HStack {
                            Text(person.name)
                            Spacer()
                            if person.voice != nil {
                                Label("voice saved", systemImage: "waveform")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { people.people[$0].id }.forEach(people.delete) }
                    if people.people.contains(where: { $0.voice != nil }) {
                        Button("Forget all saved voices", role: .destructive) { confirmForget = true }
                    }
                } header: {
                    Text("People and voices")
                } footer: {
                    Text("When you say who is who after a meeting, the app can keep a voice print of that person on this phone so it can suggest their name next time. Voice prints never leave the phone. Swipe a person to delete them.")
                }
                .confirmationDialog("Forget every saved voice?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Forget voices", role: .destructive) { people.forgetAllVoices() }
                    Button("Cancel", role: .cancel) {}
                }

                Section {
                    Picker("Speech to text", selection: $engine) {
                        Text("Best accuracy").tag(0)
                        Text("Apple's built-in").tag(1)
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Best accuracy uses a larger speech model that copes better with rooms and several people. It downloads once (about half a gigabyte, use Wi-Fi) and then works offline. If it cannot run, Apple's built-in recognizer is used. Audio never leaves the phone either way.")
                }

                Section {
                    Picker("Telling voices apart", selection: $voiceSensitivity) {
                        Text("Fewer voices").tag(0)
                        Text("Balanced").tag(1)
                        Text("More voices").tag(2)
                        Text("Even more").tag(3)
                    }
                } header: {
                    Text("Voice separation")
                } footer: {
                    Text("If different people end up as one voice, choose More voices. If one person is split into several, choose Fewer voices. Then open the meeting's \u{22EF} menu and tap Re-transcribe and find voices.")
                }

                Section {
                    Text(WidgetStore.groupStatus)
                        .font(.footnote)
                        .textSelection(.enabled)
                    Text(WidgetStore.signingReport())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    let widgetLog = WidgetStore.readLog()
                    Text(widgetLog.isEmpty ? "The widget hasn't reported anything yet." : widgetLog.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("The Home Screen and Lock Screen widgets read your action items from a folder the app shares with them.")
                }

                Section("Privacy") {
                    Text("Audio stays on your iPhone. It is converted to text and split by voice on the device, and the voice models are downloaded once. Only the transcript text and the names you give are sent to Anthropic to write the notes. With Web sync on, the finished notes and action items are also copied to your private GitHub repo.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
        }
        // Whose items count, or your name, may have changed: redo the due date alerts to match.
        .onDisappear { store.refreshAlerts() }
    }

    private func save() {
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: NotesGenerator.apiKeyName)
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: NotesGenerator.modelDefaultsKey)
        MailSettings.address = senderAddress
        MailSettings.appPassword = appPassword
        OutlookSettings.accounts = accounts.compactMap { a in
            var a = a
            a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            a.email = a.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard a.isValid else { return nil }
            if a.name.isEmpty { a.name = a.email }
            return a
        }
    }
}


/// Step by step: make a Google app password so PerroNote can send mail from your Gmail.
struct GmailSetupView: View {
    var body: some View {
        List {
            Section {
                Text("An app password is a 16-letter password Google makes just for one app. It lets PerroNote send email from your Gmail without your normal password, and you can delete it any time.")
                    .font(.subheadline)
            }
            Section("Steps") {
                step(1, "Open myaccount.google.com and sign in. Choose Security.")
                step(2, "Turn on 2-Step Verification if it is not already on. Google requires it for app passwords.")
                step(3, "Search for App passwords, or go to myaccount.google.com/apppasswords.")
                step(4, "Name it PerroNote and choose Create. Google shows a 16-letter password once.")
                step(5, "Copy it, come back here, and paste it into Google app password. Enter your Gmail address too.")
                step(6, "Tap Send a test email to myself. If it arrives in your Gmail, sending is ready.")
            }
            Section {
                Text("Treat the app password like a password. It can send mail as you, so don't share it. If you ever lose track of it, delete it on the same Google page and make a new one.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Google changes its pages now and then, so a button may be named a little differently. App passwords are not offered on some work or school accounts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Google app password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
