import SwiftUI

/// Every action item from every meeting in one place. Tick one here, and it is ticked in the meeting too.
/// It sits to the left of the meetings list; `onBack` slides back to the meetings.
struct ActionItemsView: View {
    var onBack: () -> Void
    @EnvironmentObject private var store: MeetingStore
    @State private var showDone = false
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    private var paper: Bool { appearance == AppAppearance.paper.rawValue }

    private var groups: [(meeting: Meeting, items: [ActionItem])] {
        store.meetings.compactMap { meeting in
            let items = (meeting.notes?.actionItems ?? []).filter { showDone || !$0.done }
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
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if groups.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
                        Text(showDone ? "No action items yet" : "Nothing open")
                            .font(.headline)
                        Text("Action items from your meetings show up here.")
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
