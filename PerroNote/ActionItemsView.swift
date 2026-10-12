import SwiftUI

/// Every action item from every meeting in one place. Tick one here, and it is ticked in the meeting too.
/// It sits to the left of the meetings list; `onBack` slides back to the meetings.
struct ActionItemsView: View {
    var onBack: () -> Void
    @EnvironmentObject private var store: MeetingStore
    @State private var showDone = false
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    private var paper: Bool { appearance == AppAppearance.paper.rawValue }

    /// The person whose items are shown, or nil for everyone.
    @State private var person: String?
    @State private var dateFilter: DateFilter = .all
    @State private var tagFilter: String?
    @State private var pickingDay = false
    @State private var pickedDay = Date()

    private var filtering: Bool { person != nil || dateFilter != .all || tagFilter != nil }

    /// Everyone who owns at least one action item, A to Z.
    private var people: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for meeting in store.meetings {
            for item in meeting.notes?.actionItems ?? [] where !item.task.isEmpty {
                for name in actionOwners(item) where seen.insert(name.lowercased()).inserted { out.append(name) }
            }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var groups: [(meeting: Meeting, items: [ActionItem])] {
        store.meetings.compactMap { meeting in
            guard dateFilter.contains(meeting.date),
                  tagFilter.map({ t in (meeting.tags ?? []).contains { $0.caseInsensitiveCompare(t) == .orderedSame } }) ?? true
            else { return nil }
            let items = (meeting.notes?.actionItems ?? []).filter { item in
                (showDone || !item.done)
                    && (person.map { p in actionOwners(item).contains { $0.caseInsensitiveCompare(p) == .orderedSame } } ?? true)
            }
            return items.isEmpty ? nil : (meeting, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .background(paper ? Color.clear : Color(.systemGroupedBackground))
        .paperScreen()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Action items")
                .font(.custom(CassetteView.markerFont, size: 28))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.leading, paper ? Paper.textX - 16 : 0)
            Spacer(minLength: 8)
            Button(action: onBack) {
                Image(systemName: "chevron.right").font(.title3)
            }
            .accessibilityLabel("Meetings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var list: some View {
        List {
            Section {
                Picker("Show", selection: $showDone) {
                    Text("Open").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                filters
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)

            if groups.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
                        Text(filtering ? "Nothing matches" : showDone ? "No action items yet" : "Nothing open")
                            .font(.headline)
                        Text(filtering ? "No action items fit the filters you picked."
                                       : "Action items from your meetings show up here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                .listRowBackground(Color.clear)
            }

            ForEach(groups, id: \.meeting.id) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item, in: group.meeting)
                    }
                } header: {
                    Text("\(group.meeting.title) · \(group.meeting.date.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $pickingDay) { dayPicker }
    }

    private var chipFill: Color { paper ? Color.white.opacity(0.5) : Color(.secondarySystemGroupedBackground) }

    /// Who and when: a person menu, a date menu, and a way to clear both.
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) { filterChips }
            .padding(.top, 8)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            Menu {
                Button { person = nil } label: { pickLabel("Everyone", on: person == nil) }
                if !people.isEmpty { Divider() }
                ForEach(people, id: \.self) { name in
                    Button { person = name } label: { pickLabel(name, on: person == name) }
                }
            } label: {
                chip(person ?? "Everyone", icon: "person", on: person != nil)
            }
            Menu {
                ForEach([DateFilter.all, .today, .yesterday, .thisWeek, .lastWeek, .thisMonth], id: \.title) { option in
                    Button { dateFilter = option } label: { pickLabel(option.title, on: dateFilter == option) }
                }
                Divider()
                Button { pickingDay = true } label: { Label("Pick a day\u{2026}", systemImage: "calendar") }
            } label: {
                chip(dateFilter.title, icon: "calendar", on: dateFilter != .all)
            }
            let tags = store.allTags
            if !tags.isEmpty {
                Menu {
                    Button { tagFilter = nil } label: { pickLabel("All tags", on: tagFilter == nil) }
                    Divider()
                    ForEach(tags, id: \.self) { tag in
                        Button { tagFilter = tag } label: { pickLabel(tag, on: tagFilter == tag) }
                    }
                } label: {
                    chip(tagFilter ?? "Tag", icon: "tag", on: tagFilter != nil)
                }
            }
            if filtering {
                Button("Clear") { person = nil; dateFilter = .all; tagFilter = nil }
                    .font(.footnote.weight(.semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func pickLabel(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func chip(_ title: String, icon: String, on: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Color.accentColor : chipFill, in: Capsule())
    }

    private var dayPicker: some View {
        NavigationStack {
            DatePicker("", selection: $pickedDay, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Action items from")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingDay = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show") { dateFilter = .day(pickedDay); pickingDay = false }
                    }
                }
        }
        .presentationDetents([.large])
    }

    private func row(_ item: ActionItem, in meeting: Meeting) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.update(meeting.id) { m in
                    if let i = m.notes?.actionItems.firstIndex(where: { $0.id == item.id }) {
                        m.notes?.actionItems[i].done.toggle()
                    }
                }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)

            NavigationLink(value: meeting.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task.isEmpty ? "(empty)" : item.task)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                    let meta = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
