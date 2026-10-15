import SwiftUI

/// Today's focus: the items you pinned for the day, shown at the top of the action items page.
struct FocusCard: View {
    @EnvironmentObject private var store: MeetingStore
    @AppStorage(BannerSettings.myNameKey) private var myName = ""
    @State private var tag: String?
    @State private var editing: UUID?
    @State private var addingToday = false
    @State private var newTask = ""

    private var allTags: [String] {
        var seen = Set<String>(), out: [String] = []
        for item in store.allActionItems { for t in store.tags(for: item) where seen.insert(t.lowercased()).inserted { out.append(t) } }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func has(_ item: ActionItem, _ tag: String?) -> Bool {
        guard let tag else { return true }
        return store.tags(for: item).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func isMine(_ item: ActionItem) -> Bool {
        let name = myName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return true }
        return actionOwners(item).contains { isEveryoneOwner($0) || BannerSettings.isMe($0, myName: name) }
    }

    private var rows: [ActionItem] { store.focusItems.filter { has($0, tag) } }

    /// Overdue or due today, yours, and not pinned yet.
    private var ideas: [ActionItem] {
        let pinned = Set(store.focusItems.map(\.id))
        let today = Calendar.current.startOfDay(for: Date())
        return store.allActionItems.filter { item in
            guard !item.done, !item.task.isEmpty, !pinned.contains(item.id), isMine(item), has(item, tag),
                  let due = item.dueDate else { return false }
            return Calendar.current.startOfDay(for: due) <= today
        }
        .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        .prefix(4).map { $0 }
    }

    var body: some View {
        let all = store.focusItems
        let done = all.filter(\.done).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "scope").font(.title3).foregroundStyle(Color.accentColor)
                Text("Today\u{2019}s focus").font(.headline).foregroundStyle(Color.accentColor)
                Spacer()
                if !all.isEmpty { Text("\(done) of \(all.count) done").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                if done > 0 {
                    Button("Clear done") { store.setFocus(all.filter { !$0.done }.map { $0.id.uuidString }) }
                        .font(.caption)
                }
            }
            if !all.isEmpty {
                ProgressView(value: Double(done), total: Double(all.count)).tint(Color.accentColor)
            }
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tagChip("All", on: tag == nil, color: nil) { tag = nil }
                        ForEach(allTags, id: \.self) { t in
                            tagChip("#\(t)", on: tag?.lowercased() == t.lowercased(), color: TagRegistry.color(for: t)) {
                                tag = tag?.lowercased() == t.lowercased() ? nil : t
                            }
                        }
                    }
                }
            }
            if rows.isEmpty {
                Text(tag == nil ? "Pin items with the star to plan your day." : "Nothing pinned with #\(tag ?? "").")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(rows) { item in focusRow(item) }

            let due = ideas
            if !due.isEmpty {
                Text("Due now").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(due) { item in
                        Button { store.togglePin(item.id) } label: {
                            Text("+ \(item.task)").font(.caption).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if addingToday {
                HStack {
                    TextField("Task for today", text: $newTask).submitLabel(.done).onSubmit(addToday)
                    Button("Add", action: addToday).disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button { addingToday = true } label: { Label("Add a task just for today", systemImage: "plus") }
                    .font(.subheadline)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
        .sheet(item: Binding(get: { editing.map { EditID(id: $0) } }, set: { editing = $0?.id })) { ActionItemEditor(itemID: $0.id) }
    }

    private func tagChip(_ text: String, on: Bool, color: Color?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : (color ?? Color.primary))
                .background(on ? (color ?? Color.accentColor) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func focusRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { store.updateActionItem(item.id) { $0.done.toggle() } } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            Button { editing = item.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task.isEmpty ? "(empty)" : item.task)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    TagPills(item: item)
                    if let due = item.due, !due.isEmpty { Text("due \(due)").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { store.togglePin(item.id) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove from Today\u{2019}s focus")
        }
        .opacity(item.done ? 0.7 : 1)
    }

    private func addToday() {
        let t = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        newTask = ""
        addingToday = false
        guard !t.isEmpty else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy"
        let me = myName.trimmingCharacters(in: .whitespaces)
        let item = ActionItem(task: t, owner: me.isEmpty ? "Me" : me, due: f.string(from: Date()), created: Date())
        store.addLooseItem(item)
        store.togglePin(item.id)
    }
}

struct EditID: Identifiable { let id: UUID }

/// The item's tags as small colored pills.
struct TagPills: View {
    let item: ActionItem
    @EnvironmentObject private var store: MeetingStore
    var body: some View {
        let tags = store.tags(for: item)
        if !tags.isEmpty {
            FlowLayout(spacing: 4, rowSpacing: 4) {
                ForEach(tags, id: \.self) { t in
                    Text("#\(t)").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(TagRegistry.color(for: t))
                        .background(TagRegistry.color(for: t).opacity(0.16), in: Capsule())
                }
            }
        }
    }
}

/// Edit an action item: its text, owner, due date, tags and note, and pin it to Today's focus. Works for any item.
struct ActionItemEditor: View {
    let itemID: UUID
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var task = ""
    @State private var owner = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var tags: [String] = []
    @State private var note = ""
    @State private var newTag = ""
    @State private var confirmDelete = false

    private var knownTags: [String] {
        var seen = Set(tags.map { $0.lowercased() }), out: [String] = []
        for item in store.allActionItems { for t in item.tags ?? [] where seen.insert(t.lowercased()).inserted { out.append(t) } }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Tags it gets from its meeting. Change those on the meeting.
    private var fromMeeting: [String] {
        store.meetingTags(for: itemID).filter { m in !tags.contains { $0.caseInsensitiveCompare(m) == .orderedSame } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Action item") {
                    TextField("Task", text: $task, axis: .vertical).lineLimit(1...5)
                    TextField("Who owns it", text: $owner).textInputAutocapitalization(.words)
                }
                Section("Due") {
                    Toggle("Has a due date", isOn: $hasDue)
                    if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
                }
                Section {
                    if !fromMeeting.isEmpty {
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(fromMeeting, id: \.self) { t in
                                Text("#\(t)").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .foregroundStyle(TagRegistry.color(for: t))
                                    .background(TagRegistry.color(for: t).opacity(0.10), in: Capsule())
                            }
                        }
                    }
                    if !tags.isEmpty {
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(tags, id: \.self) { t in
                                Button { tags.removeAll { $0 == t } } label: {
                                    HStack(spacing: 4) { Text("#\(t)"); Image(systemName: "xmark").font(.caption2) }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .foregroundStyle(TagRegistry.color(for: t))
                                        .background(TagRegistry.color(for: t).opacity(0.16), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack {
                        TextField("Add a tag", text: $newTag).textInputAutocapitalization(.words).submitLabel(.done).onSubmit(addTag)
                        Button("Add", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !knownTags.isEmpty {
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(knownTags, id: \.self) { t in
                                Button { tags.append(t) } label: {
                                    Text("+ #\(t)").font(.caption)
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    if !fromMeeting.isEmpty { Text("Faded tags come from the meeting.") }
                }
                Section("Note") {
                    TextEditor(text: $note).frame(minHeight: 110)
                }
                Section {
                    Button { store.togglePin(itemID) } label: {
                        Label(store.isPinned(itemID) ? "In Today\u{2019}s focus (tap to remove)" : "Pin to Today\u{2019}s focus",
                              systemImage: store.isPinned(itemID) ? "star.fill" : "star")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete action item", systemImage: "trash") }
                }
            }
            .navigationTitle("Edit action item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(task.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .confirmationDialog("Delete this action item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.deleteActionItem(itemID); dismiss() }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d, yyyy"
        return f
    }()

    private func load() {
        guard !loaded, let item = store.actionItem(itemID) else { return }
        loaded = true
        task = item.task
        owner = item.owner ?? ""
        tags = item.tags ?? []
        note = item.note ?? ""
        if let d = item.dueDate { hasDue = true; due = d }
    }

    private func addTag() {
        var t = newTag.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: " ")
        newTag = ""
        guard !t.isEmpty else { return }
        t = knownTags.first { $0.caseInsensitiveCompare(t) == .orderedSame } ?? t
        if !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }),
           !store.meetingTags(for: itemID).contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { tags.append(t) }
    }

    private func save() {
        let original = store.actionItem(itemID)
        store.updateActionItem(itemID) { item in
            item.task = task.trimmingCharacters(in: .whitespacesAndNewlines)
            let o = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            item.owner = o.isEmpty ? nil : o
            // Keep the original wording of a due date that wasn't touched ("week of Mon, Oct 13").
            if hasDue {
                if original?.dueDate.map({ Calendar.current.isDate($0, inSameDayAs: due) }) != true { item.due = Self.format.string(from: due) }
            } else { item.due = nil }
            item.tags = tags.isEmpty ? nil : tags
            let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
            item.note = n.isEmpty ? nil : n
        }
        store.scheduleSync(after: 2)
        dismiss()
    }
}
