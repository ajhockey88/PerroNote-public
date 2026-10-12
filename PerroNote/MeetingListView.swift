import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MeetingListView: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var showRecorder = false
    @State private var showSettings = false
    @State private var showDatePicker = false
    @State private var query = ""
    @State private var filter: DateFilter = .all
    @FocusState private var searchFocused: Bool
    @State private var showingActions = false
    @State private var askingAll = false
    @State private var importing = false
    @State private var importBusy = false
    @State private var importError: String?
    @State private var tagFilter: String?
    @State private var path = NavigationPath()
    @State private var tagging: TagTarget?
    /// Where the scrolling chip rows are; a sideways drag that starts on one scrolls the chips, never the page.
    @State private var noSwipeZones: [CGRect] = []
    @AppStorage(BannerSettings.showKey) private var showBanner = true
    @ObservedObject private var recordRequest = RecordRequest.shared
    @GestureState(resetTransaction: Transaction(animation: MeetingListView.pageSpring)) private var swipe = PageSwipe()
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @PaperPitch private var pitch

    private var paper: Bool { appearance == AppAppearance.paper.rawValue }
    private var ground: Color { paper ? Paper.canary : Color(.systemGroupedBackground) }

    private var openActionItems: Int {
        store.meetings.reduce(0) { $0 + ($1.notes?.actionItems.filter { !$0.done && !$0.task.isEmpty }.count ?? 0) }
    }

    private var visible: [Meeting] {
        store.meetings.filter { m in
            filter.contains(m.date) && m.matches(query)
                && (tagFilter.map { t in (m.tags ?? []).contains { $0.caseInsensitiveCompare(t) == .orderedSame } } ?? true)
        }
    }

    private var todayCount: Int { store.meetings.filter { Calendar.current.isDateInToday($0.date) }.count }

    /// Visible meetings split by calendar day, newest first.
    private var groups: [(day: Date, meetings: [Meeting])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: visible) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            (day, byDay[day]!.sorted { $0.date > $1.date })
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var subtitle: String {
        if !query.isEmpty {
            return "\(visible.count) match\(visible.count == 1 ? "" : "es") for \u{201C}\(query)\u{201D}"
        }
        if store.meetings.isEmpty { return "Nothing recorded yet" }
        return "\(todayCount) today \u{00B7} \(openActionItems) open item\(openActionItems == 1 ? "" : "s")"
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ActionItemsView { showPage(actions: false) }
                        .frame(width: geo.size.width)
                        .allowsHitTesting(showingActions)
                        .accessibilityHidden(!showingActions)
                    mainPage
                        .frame(width: geo.size.width)
                        .allowsHitTesting(!showingActions)
                        .accessibilityHidden(showingActions)
                }
                .frame(width: geo.size.width, alignment: .leading)
                .offset(x: (showingActions ? 0 : -geo.size.width) + swipe.x)
                .contentShape(Rectangle())
                .simultaneousGesture(pageSwipe(width: geo.size.width))
            }
            .coordinateSpace(name: PageSwipeZones.space)
            .onPreferenceChange(PageSwipeZones.self) { noSwipeZones = $0 }
            .navigationDestination(for: UUID.self) { MeetingDetailView(id: $0) }
            .navigationDestination(for: PeopleRoute.self) { _ in PeopleView() }
            .navigationDestination(for: PersonRoute.self) { PersonView(name: $0.name) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(isPresented: $showRecorder) { RecordingView() }
        .sheet(isPresented: $askingAll) { AskMeetingView(meeting: nil) }
        .sheet(item: $tagging) { TagsView(meetingID: $0.id) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .audiovisualContent]) { result in
            guard case .success(let url) = result else { return }
            importBusy = true
            Task {
                do {
                    store.addImported(try await AudioImport.bringIn(url))
                } catch {
                    importError = error.localizedDescription
                }
                importBusy = false
            }
        }
        .alert("Import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .onAppear(perform: takeRecordRequest)
        .onChange(of: recordRequest.pending) { _ in takeRecordRequest() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showDatePicker) { DateFilterSheet(filter: $filter) }
    }

    /// Control Center, Siri or Shortcuts asked to record: open the recorder on the meetings page.
    private func takeRecordRequest() {
        guard recordRequest.pending else { return }
        recordRequest.pending = false
        showPage(actions: false)
        showRecorder = true
    }

    private func showPage(actions: Bool) {
        searchFocused = false
        withAnimation(Self.pageSpring) { showingActions = actions }
    }

    private static let pageSpring = Animation.spring(response: 0.35, dampingFraction: 0.9)

    /// Swiping right on the meetings shows the action items to their left; swiping left there comes back.
    /// Only a mostly sideways drag in the open direction counts, so scrolling and swipe-to-delete still work.
    private func pageSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .named(PageSwipeZones.space))
            .updating($swipe) { value, state, _ in
                if state.counts == nil {
                    state.counts = swipeCounts(value.translation) && !onChips(value.startLocation)
                }
                guard state.counts == true else { return }
                let dx = value.translation.width
                state.x = showingActions ? min(0, dx) : max(0, dx)
            }
            .onEnded { value in
                guard swipeCounts(value.translation), !onChips(value.startLocation) else { return }
                let dx = value.translation.width
                let flung = value.predictedEndTranslation.width
                let go = showingActions ? (dx < -width / 3 || flung < -width / 2)
                                        : (dx > width / 3 || flung > width / 2)
                if go { showPage(actions: !showingActions) }
            }
    }

    private func onChips(_ point: CGPoint) -> Bool {
        noSwipeZones.contains { $0.insetBy(dx: 0, dy: -6).contains(point) }
    }

    private func swipeCounts(_ t: CGSize) -> Bool {
        let rightway = showingActions ? t.width < 0 : t.width > 0
        return rightway && abs(t.width) > abs(t.height) * 1.5
    }

    private var mainPage: some View {
        VStack(spacing: 0) {
            if paper { paperHeader } else { header }
            if showBanner && ActionBanner.hasItems(store) {
                ActionBanner { showPage(actions: true) }
                    .padding(.leading, paper ? Paper.textX - 8 : 16)
                    .padding(.trailing, 16)
                    .padding(.bottom, paper ? 12 : 10)
            }
            if !store.meetings.isEmpty {
                if paper {
                    paperSearch
                } else {
                    searchBar
                    filterChips
                    tagChips
                }
            }
            if paper && !visible.isEmpty { paperList } else { content }
        }
        .background {
            // Reaches under the status bar and the home indicator, so no white bands show in Light.
            if paper { PaperBackground() } else { Color(.systemGroupedBackground).ignoresSafeArea() }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                if !store.meetings.isEmpty {
                    Button { askingAll = true } label: {
                        Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(paper ? Color.white.opacity(0.6) : Color(.secondarySystemGroupedBackground), in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask all meetings")
                }
                Button { showRecorder = true } label: {
                    Label("Record", systemImage: "mic.fill")
                        .font(.headline)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(Color(red: 0.90, green: 0.28, blue: 0.24), in: Capsule())
                        .shadow(color: Color(red: 0.90, green: 0.28, blue: 0.24).opacity(0.45), radius: 10, y: 5)
                }
            }
            .padding(.bottom, 10)
            .padding(.top, 30)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [ground.opacity(0), ground],
                               startPoint: .top, endPoint: .center)
                    .allowsHitTesting(false))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("BrandIcon")
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            nameBlock
            Spacer(minLength: 8)
            headerButtons
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// On paper the icon sits in the left margin and the name starts where the writing does.
    private var paperHeader: some View {
        HStack(spacing: 0) {
            Image("BrandIcon")
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                .frame(width: Paper.marginX)
                .accessibilityHidden(true)
            nameBlock
                .padding(.leading, Paper.textX - Paper.marginX)
            Spacer(minLength: 8)
            headerButtons
        }
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("PerroNote")
                .font(.custom(CassetteView.markerFont, size: 28))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 14) {
            Button { importing = true } label: {
                if importBusy { ProgressView() } else { Image(systemName: "square.and.arrow.down") }
            }
            .disabled(importBusy)
            .accessibilityLabel("Import a recording")

            NavigationLink(value: PeopleRoute()) { Image(systemName: "person.2") }
                .accessibilityLabel("People")

            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
        .font(.title3)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search meetings and notes", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty || searchFocused {
                Button {
                    query = ""
                    searchFocused = false
                } label: { Text("Cancel").font(.subheadline.weight(.semibold)) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var filterChips: some View {
        let options: [DateFilter] = [.all, .today, .yesterday, .thisWeek, .lastWeek, .thisMonth]
        let custom = !options.contains(filter)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.title) { option in
                    chip(option == .all ? "All" : option.title, selected: filter == option) { filter = option }
                }
                if custom { chip(filter.title, selected: true) { filter = .all } }
                Button { showDatePicker = true } label: {
                    Label("Pick", systemImage: "calendar")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(chipFill, in: Capsule())
                }
            }
            .padding(.leading, paper ? Paper.textX - 4 : 16)
            .padding(.trailing, 16)
        }
        .noPageSwipe()
        .padding(.bottom, 6)
    }

    /// One chip per tag, on its own row under the dates. Only shown once some meeting has a tag.
    @ViewBuilder private var tagChips: some View {
        let tags = store.allTags
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "tag").font(.footnote).foregroundStyle(.secondary)
                    chip("All tags", selected: tagFilter == nil) { tagFilter = nil }
                    ForEach(tags, id: \.self) { tag in
                        chip(tag, selected: tagFilter == tag) { tagFilter = tagFilter == tag ? nil : tag }
                    }
                }
                .padding(.leading, paper ? Paper.textX - 4 : 16)
                .padding(.trailing, 16)
            }
            .noPageSwipe()
            .padding(.bottom, 6)
        }
    }

    private var chipFill: Color { paper ? Color.white.opacity(0.5) : Color(.secondarySystemGroupedBackground) }

    /// The search field and date chips written on the first lines of the pad.
    private var paperSearch: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: Paper.marginX - 10, alignment: .trailing)
                    .padding(.trailing, Paper.textX - Paper.marginX + 10)
                TextField("Search meetings and notes", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty || searchFocused {
                    Button {
                        query = ""
                        searchFocused = false
                    } label: { Text("Cancel").font(.subheadline.weight(.semibold)) }
                }
            }
            .padding(.trailing, 16)
            .frame(height: pitch, alignment: .bottom)
            .padding(.bottom, 3)
            .overlay(alignment: .top) { Paper.topRule.frame(height: 1.5) }
            .overlay(alignment: .bottom) { paperRule }
            filterChips
                .padding(.top, 6)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { paperRule }
            if !store.allTags.isEmpty {
                tagChips
                    .padding(.top, 6)
                    .overlay(alignment: .bottom) { paperRule }
            }
        }
    }

    private var paperRule: some View { Color(uiColor: Paper.rule).frame(height: 1) }

    /// Each meeting is its own sticky note, with its day and time in the margin and the pad's rules running behind.
    private var paperList: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.day) { group in
                        Text(dayTitle(group.day))
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: Paper.marginX - 8, alignment: .trailing)
                            .onRules(.caption2, pitch: pitch)
                        ForEach(group.meetings) { meeting in
                            openable(MeetingRow(meeting: meeting, pitch: pitch), meeting.id)
                                .padding(.bottom, pitch)
                        }
                    }
                    Color.clear.frame(height: pitch * 3)
                }
                .padding(.top, pitch + Paper.lead(pitch))
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                .background(alignment: .top) { PaperRules(pitch: pitch) }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : chipFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if store.meetings.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image("BrandIcon")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                Text("Your first meeting starts here").font(.title3.weight(.semibold)).padding(.top, 8)
                Text("Tap Record. When you stop, PerroNote writes the text and drafts the notes, with action items and dates.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if visible.isEmpty {
            placeholder(icon: "magnifyingglass", title: "No matches",
                        text: "Nothing fits the current search, date and tag filter.")
        } else {
            List {
                ForEach(groups, id: \.day) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            openable(MeetingRow(meeting: meeting), meeting.id)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        .onDelete { offsets in
                            offsets.map { group.meetings[$0].id }.forEach(store.delete)
                        }
                    } header: {
                        Text(dayTitle(group.day))
                            .font(.caption.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                    }
                }
                Color.clear.frame(height: 70).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// Tap opens the meeting; holding a finger on it opens its tags.
    private func openable(_ row: some View, _ id: UUID) -> some View {
        row
            .contentShape(Rectangle())
            .onTapGesture { path.append(id) }
            .onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                tagging = TagTarget(id: id)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Tags") { tagging = TagTarget(id: id) }
    }

    private func placeholder(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 64)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The frames of the chip rows, in the pager's coordinates.
struct PageSwipeZones: PreferenceKey {
    static let space = "pager"
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// Marks a sideways-scrolling row so swiping on it doesn't flip between meetings and action items.
    func noPageSwipe() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: PageSwipeZones.self, value: [g.frame(in: .named(PageSwipeZones.space))])
        })
    }
}

/// The meeting whose tags sheet is open.
private struct TagTarget: Identifiable {
    let id: UUID
}

/// A sideways drag between the meetings and the action items. `counts` is decided once, at the start of the drag.
private struct PageSwipe {
    var counts: Bool?
    var x: CGFloat = 0
}

private struct DateFilterSheet: View {
    @Binding var filter: DateFilter
    @Environment(\.dismiss) private var dismiss
    @State private var scope = 0
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $scope) {
                    Text("Day").tag(0)
                    Text("Week").tag(1)
                }
                .pickerStyle(.segmented)
                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Text(scope == 0 ? "Show meetings from this day." : "Show meetings from the whole week of this day.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Choose a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") {
                        filter = scope == 0 ? .day(date) : .week(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    /// Set on paper: the row becomes a sticky note that fills whole rules.
    var pitch: CGFloat? = nil

    private var people: [String] { meeting.attendeeNames ?? meeting.notes?.attendees ?? [] }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private func color(_ name: String) -> Color {
        let palette: [Color] = [.indigo, .orange, .blue, .teal, .pink, .purple, .green]
        return palette[abs(name.hashValue) % palette.count]
    }

    var body: some View {
        if let pitch { note(pitch) } else { card }
    }

    private func note(_ pitch: CGFloat) -> some View {
        let style = StickyStyle(meeting.id)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(meeting.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Paper.marginX - 8, alignment: .trailing)
                .padding(.trailing, 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(meeting.title).font(.headline).lineLimit(1)
                    .onRules(.headline, pitch: pitch)
                if meeting.status == .done, let n = meeting.notes {
                    if !n.summary.isEmpty {
                        Text(n.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            .onRules(.subheadline, pitch: pitch)
                    }
                    HStack(spacing: 8) {
                        if !people.isEmpty { avatars(ring: style.color) }
                        Text(formatDuration(meeting.duration)).font(.caption).foregroundStyle(.secondary)
                        tagText
                        Spacer(minLength: 0)
                        openBadge(n)
                            .padding(.trailing, style.fold == .bottomTrailing ? 12 : 0)
                    }
                    .frame(height: pitch)
                } else {
                    statusLabel.frame(height: pitch)
                    Text(formatDuration(meeting.duration)).font(.caption).foregroundStyle(.secondary)
                        .frame(height: pitch)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .snapToRules(pitch)
            .background(StickyNote(style: style).padding(.vertical, -4))
            .rotationEffect(.degrees(style.tilt))
            .padding(.trailing, 12)
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(meeting.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.headline).lineLimit(2)
                if meeting.status == .done, let n = meeting.notes {
                    if !n.summary.isEmpty {
                        Text(n.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if !people.isEmpty { avatars(ring: Color(.secondarySystemGroupedBackground)) }
                        Text(formatDuration(meeting.duration)).font(.caption).foregroundStyle(.secondary)
                        tagText
                        Spacer(minLength: 0)
                        openBadge(n)
                    }
                    .padding(.top, 2)
                } else {
                    statusLabel
                    Text(formatDuration(meeting.duration)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func avatars(ring: Color) -> some View {
        HStack(spacing: -5) {
            ForEach(Array(people.prefix(3).enumerated()), id: \.offset) { _, name in
                Text(initials(name))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(color(name), in: Circle())
                    .overlay(Circle().stroke(ring, lineWidth: 1.5))
            }
        }
    }

    @ViewBuilder private var tagText: some View {
        if let tags = meeting.tags, !tags.isEmpty {
            Text(tags.map { "#\($0)" }.joined(separator: " "))
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
        }
    }

    @ViewBuilder private func openBadge(_ n: MeetingNotes) -> some View {
        let open = n.actionItems.filter { !$0.done && !$0.task.isEmpty }.count
        if open > 0 {
            Text("\(open) open")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red.opacity(0.14), in: Capsule())
        } else if !n.actionItems.isEmpty {
            Text("\u{2713} all done")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.green.opacity(0.16), in: Capsule())
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch meeting.status {
        case .transcribing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Converting to text…") }
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case .diarizing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Finding who spoke…") }
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case .generating:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Drafting notes…") }
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case .failed:
            Label("Needs attention", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        case .recorded:
            Label("Recorded", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
        case .done:
            EmptyView()
        }
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
