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
                    Text("System follows your iPhone's Light or Dark setting.")
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

                Section("Privacy") {
                    Text("Audio stays on your iPhone. It is converted to text and split by voice on the device, and the voice models are downloaded once. Only the transcript text and the names you give are sent to Anthropic to write the notes.")
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
