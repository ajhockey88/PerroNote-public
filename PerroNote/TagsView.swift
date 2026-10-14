import SwiftUI

/// Pick which tags a meeting has, or make a new one. Tags work like folders a meeting can be in more than one of.
struct TagsView: View {
    let meetingID: UUID
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    private var tags: [String] { store.meeting(meetingID)?.tags ?? [] }

    private func has(_ tag: String) -> Bool { tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }

    private func toggle(_ tag: String) {
        store.update(meetingID) { m in
            var t = m.tags ?? []
            if let i = t.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                t.remove(at: i)
            } else {
                t.append(tag)
            }
            m.tags = t.isEmpty ? nil : t
        }
    }

    private func addTyped() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !tag.isEmpty, !has(tag) else { return }
        // Reuse the spelling of a tag that already exists on another meeting.
        toggle(store.allTags.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("New tag, like a project or client", text: $newTag)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(addTyped)
                        Button("Add", action: addTyped)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                let all = store.allTags
                if !all.isEmpty {
                    Section {
                        ForEach(all, id: \.self) { tag in
                            Button { toggle(tag) } label: {
                                HStack {
                                    Label { Text(tag) } icon: { Image(systemName: "tag").foregroundStyle(TagRegistry.color(for: tag)) }
                                    Spacer()
                                    if has(tag) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("Tags")
                    } footer: {
                        Text("Filter the meetings list and the action items by tag.")
                    }
                }
            }
            .paperScreen()
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
