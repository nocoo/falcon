import FalconCore
import SwiftUI

struct RequestListView: View {
    private enum FocusRegion: Hashable { case search, list }
    @Bindable var model: WorkspaceModel
    @FocusState private var focusedRegion: FocusRegion?
    @State private var showRange = false
    @State private var rangeStart = Date().addingTimeInterval(-3600)
    @State private var rangeEnd = Date()
    @State private var scrollPosition: UUID?
    @State private var isAtTop = true
    @State private var pendingUnstar: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !filterSummary.isEmpty { activeFilters }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: FalconTheme.Space.micro, pinnedViews: [.sectionHeaders]) {
                        Color.clear.frame(height: 0).id("activity-top")
                        ForEach(days, id: \.date) { day in
                            Section {
                                ForEach(day.records) { request in
                                    Button {
                                        focusedRegion = .list
                                        Task { await model.select(request.id) }
                                    } label: {
                                        RequestRow(
                                            record: request,
                                            iconID: model.sources.first { $0.id == request.sourceID }?.iconID,
                                            preview: model.previews[request.id],
                                            selected: model.selectedID == request.id)
                                    }.buttonStyle(.plain).id(request.id).contextMenu {
                                        Button {
                                            if request.isStarred, request.expiresAt <= Date() {
                                                pendingUnstar = request.id
                                            } else {
                                                Task { await model.toggleStar(id: request.id) }
                                            }
                                        } label: {
                                            Label(
                                                request.isStarred ? "Remove star" : "Star · keep indefinitely",
                                                systemImage: request.isStarred ? "star.slash" : "star")
                                        }.disabled(model.isUpdatingStar || model.isTriaging)
                                    }
                                }
                            } header: {
                                Text(dayTitle(day.date)).font(FalconTheme.caption).foregroundStyle(
                                    FalconTheme.secondary
                                ).frame(maxWidth: .infinity, alignment: .leading).padding(
                                    .horizontal, FalconTheme.Space.regular
                                ).padding(.top, FalconTheme.Space.compact).padding(.bottom, FalconTheme.Space.small)
                                    .background(FalconTheme.surface)
                            }
                        }
                        if model.hasMore {
                            Button("Load earlier decisions") { Task { await model.loadMore() } }.buttonStyle(
                                FalconButtonStyle(compact: true)
                            ).padding(FalconTheme.Space.compact).disabled(model.isLoading)
                        }
                    }.scrollTargetLayout().padding(.horizontal, FalconTheme.Space.tight).padding(
                        .bottom, FalconTheme.Space.tight)
                }.scrollPosition(id: $scrollPosition, anchor: .top).focusable().focusEffectDisabled().focused(
                    $focusedRegion, equals: .list
                ).onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top <= 0
                } action: { _, atTop in
                    isAtTop = atTop
                }.onKeyPress(.upArrow) { navigate(forward: false) }.onKeyPress(.downArrow) { navigate(forward: true) }
                    .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }.onChange(
                        of: model.requests.first?.id
                    ) { _, current in if isAtTop, current != nil { proxy.scrollTo("activity-top", anchor: .top) } }
                    .onChange(of: model.newArrivalCount) { previous, current in
                        if previous > 0, current == 0 { proxy.scrollTo("activity-top", anchor: .top) }
                    }.overlay {
                        if model.requests.isEmpty, !model.isLoading {
                            if model.starredOnly, model.search.isEmpty, filterSummary.isEmpty {
                                ContentUnavailableView(
                                    "No starred decisions", systemImage: "star",
                                    description: Text("Star a decision to keep it beyond seven days."))
                            } else if model.search.isEmpty, filterSummary.isEmpty {
                                ContentUnavailableView(
                                    "Waiting for decisions", systemImage: "tray",
                                    description: Text("Requests appear here as they arrive."))
                            } else {
                                ContentUnavailableView.search(text: model.search)
                            }
                        }
                    }
            }
            footer
        }.background(FalconTheme.surface).background {
            Button("Search") { focusedRegion = .search }.keyboardShortcut("f").hidden()
        }.sheet(isPresented: $showRange) { rangeSheet }.confirmationDialog(
            "Remove this saved decision?",
            isPresented: Binding(get: { pendingUnstar != nil }, set: { if !$0 { pendingUnstar = nil } }),
            titleVisibility: .visible, presenting: pendingUnstar
        ) { id in
            Button("Remove star and delete", role: .destructive) { Task { await model.toggleStar(id: id) } }
        } message: { _ in
            Text("This decision is older than seven days. Removing its star also removes its saved evidence.")
        }
    }

    private var header: some View {
        VStack(spacing: FalconTheme.Space.compact) {
            HStack(spacing: FalconTheme.Space.compact) {
                Text(model.starredOnly ? "Starred" : "Activity").font(FalconTheme.sectionTitle).tracking(
                    FalconTheme.titleTracking)
                Spacer(minLength: 0)
                if model.starredOnly {
                    Text("All time").font(FalconTheme.caption).foregroundStyle(FalconTheme.secondary)
                } else {
                    Menu {
                        Picker("Time range", selection: $model.hours) {
                            Text("Past hour").tag(1)
                            Text("Past 24 hours").tag(24)
                            Text("Past 7 days").tag(168)
                        }
                        Button("Custom range…") { showRange = true }
                    } label: {
                        Text(rangeTitle).font(FalconTheme.caption).foregroundStyle(FalconTheme.secondary)
                    }.menuStyle(.borderlessButton).fixedSize().help("Time range")
                }
                Menu {
                    Button("Replay this range") { Task { await model.startReplay(range: true) } }
                    Button("Refresh") { Task { await model.refresh(reset: true) } }
                } label: {
                    Image(systemName: "ellipsis").font(FalconTheme.label).frame(
                        width: FalconTheme.Layout.menuMark, height: FalconTheme.Layout.menuMark)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Activity actions")
            }
            HStack(spacing: FalconTheme.Space.tight) {
                HStack(spacing: FalconTheme.Space.tight) {
                    Image(systemName: "magnifyingglass").font(FalconTheme.caption).foregroundStyle(FalconTheme.tertiary)
                    TextField("Search decisions", text: $model.search).textFieldStyle(.plain).font(FalconTheme.detail)
                        .focused($focusedRegion, equals: .search)
                    if !model.search.isEmpty {
                        Button {
                            model.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain).foregroundStyle(FalconTheme.secondary).accessibilityLabel("Clear search")
                    }
                }.padding(.horizontal, FalconTheme.Space.compact).frame(height: FalconTheme.Layout.compactControlHeight)
                    .background(FalconTheme.inset, in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control))
                Button {
                    model.starredOnly.toggle()
                } label: {
                    Image(systemName: model.starredOnly ? "star.fill" : "star").font(FalconTheme.label).foregroundStyle(
                        model.starredOnly ? FalconTheme.warning : FalconTheme.secondary
                    ).frame(
                        width: FalconTheme.Layout.compactControlHeight, height: FalconTheme.Layout.compactControlHeight
                    ).background(
                        model.starredOnly ? FalconTheme.Candy.yellow.opacity(0.2) : FalconTheme.inset,
                        in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control))
                }.buttonStyle(.plain).help(model.starredOnly ? "Show recent decisions" : "Show all starred decisions")
                    .accessibilityLabel("Starred decisions").accessibilityValue(model.starredOnly ? "On" : "Off")
                filterMenu
            }
        }.padding(FalconTheme.Space.regular).padding(.bottom, FalconTheme.Space.micro)
    }

    private var filterMenu: some View {
        Menu {
            SourceFilterOptions(model: model)
            Divider()
            Picker("Status", selection: $model.statusFilter) {
                Text("All statuses").tag(nil as RequestStatus?)
                ForEach(RequestStatus.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Divider()
            Picker("Review", selection: $model.reviewFilter) {
                Text("All reviews").tag(nil as ReviewState?)
                ForEach(ReviewState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").font(FalconTheme.label).foregroundStyle(
                filterSummary.isEmpty ? FalconTheme.secondary : FalconTheme.accent
            ).frame(width: FalconTheme.Layout.compactControlHeight, height: FalconTheme.Layout.compactControlHeight)
                .background(
                    filterSummary.isEmpty ? FalconTheme.inset : FalconTheme.accentWash,
                    in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(
            "Filter sources, status and review")
    }

    private var activeFilters: some View {
        HStack(spacing: FalconTheme.Space.tight) {
            Text(filterSummary).font(FalconTheme.caption).lineLimit(1).help(filterSummary)
            Spacer(minLength: 0)
            Button {
                model.sourceFilters = []
                model.statusFilter = nil
                model.reviewFilter = nil
                model.clearEvidenceFilters()
                Task { await model.refresh(reset: true) }
            } label: {
                Image(systemName: "xmark").font(FalconTheme.caption)
            }.buttonStyle(.plain).accessibilityLabel("Clear filters")
        }.foregroundStyle(FalconTheme.accent).padding(.horizontal, FalconTheme.Space.regular).padding(
            .bottom, FalconTheme.Space.compact)
    }

    private var footer: some View {
        HStack(spacing: FalconTheme.Space.compact) {
            Text("\(model.requests.count.formatted()) decisions").monospacedDigit()
            Spacer(minLength: 0)
            if model.newArrivalCount > 0 {
                Button {
                    Task { await model.showLatest() }
                } label: {
                    Label(
                        "\(model.newArrivalCount)\(model.newArrivalCount == 100 ? "+" : "") new",
                        systemImage: "arrow.up")
                }.buttonStyle(.plain).foregroundStyle(FalconTheme.accent).help("Show latest decisions")
            } else if model.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Label("Local", systemImage: "internaldrive")
            }
        }.font(FalconTheme.footnote).foregroundStyle(FalconTheme.secondary).padding(
            .horizontal, FalconTheme.Space.regular
        ).frame(height: FalconTheme.Layout.controlHeight)
    }

    private var rangeSheet: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.large) {
            Text("Review a time range").font(FalconTheme.title)
            DatePicker("From", selection: $rangeStart, displayedComponents: [.date, .hourAndMinute])
            DatePicker("Until", selection: $rangeEnd, displayedComponents: [.date, .hourAndMinute])
            HStack {
                Button("Cancel", role: .cancel) { showRange = false }
                Spacer()
                Button("Show decisions") {
                    model.timeRange = DateInterval(start: rangeStart, end: rangeEnd)
                    showRange = false
                    Task { await model.refresh(reset: true) }
                }.keyboardShortcut(.defaultAction).disabled(rangeStart >= rangeEnd)
            }
        }.padding(FalconTheme.Space.sheet).frame(width: FalconTheme.Layout.sheetWidth)
    }

    private var rangeTitle: String {
        model.timeRange != nil ? "Custom" : model.hours == 168 ? "7 days" : model.hours == 24 ? "24 hours" : "1 hour"
    }

    private var filterSummary: String {
        var parts: [String] = []
        if model.sourceFilters.count == 1,
            let source = model.sources.first(where: { model.sourceFilters.contains($0.id) })
        {
            parts.append(source.name)
        } else if !model.sourceFilters.isEmpty {
            parts.append("\(model.sourceFilters.count) sources")
        }
        if let status = model.statusFilter { parts.append(status.title) }
        if let review = model.reviewFilter { parts.append(review.rawValue.capitalized) }
        if model.hasEvidenceFilter { parts.append("Selected evidence") }
        return parts.joined(separator: " · ")
    }

    private var days: [(date: Date, records: [RequestSummary])] {
        Dictionary(grouping: model.requests) { Calendar.current.startOfDay(for: $0.receivedAt) }.map {
            (date: $0.key, records: $0.value)
        }.sorted { $0.date > $1.date }
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func navigate(forward: Bool) -> KeyPress.Result {
        guard focusedRegion == .list else { return .ignored }
        Task { await model.selectAdjacent(forward: forward) }
        return .handled
    }
}

struct SourceFilterOptions: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        Button("All sources") { model.sourceFilters = [] }
        ForEach(model.sources) { source in
            Toggle(
                "\(source.name) · \(source.id.uuidString.prefix(6).lowercased())",
                isOn: Binding(
                    get: { model.sourceFilters.contains(source.id) },
                    set: { included in
                        if included {
                            model.sourceFilters.insert(source.id)
                        } else {
                            model.sourceFilters.remove(source.id)
                        }
                    }))
        }
    }
}
