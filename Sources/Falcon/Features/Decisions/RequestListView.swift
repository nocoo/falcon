import FalconCore
import SwiftUI

struct RequestListView: View {
    @Bindable var model: WorkspaceModel
    @FocusState private var searchFocused: Bool
    @State private var showRange = false
    @State private var rangeStart = Date().addingTimeInterval(-3600)
    @State private var rangeEnd = Date()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
                HStack {
                    Text("Activity").font(FalconTheme.sectionTitle).tracking(FalconTheme.titleTracking)
                    Spacer()
                    Menu {
                        Button("Replay this range") { Task { await model.startReplay(range: true) } }
                        Button("Refresh") { Task { await model.refresh(reset: true) } }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 20, height: 20)
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                HStack(spacing: FalconTheme.Space.compact) {
                    Image(systemName: "magnifyingglass").foregroundStyle(FalconTheme.tertiary)
                    TextField("Search decisions", text: $model.search).textFieldStyle(.plain).font(FalconTheme.detail)
                        .focused($searchFocused)
                    if !model.search.isEmpty {
                        Button {
                            model.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(FalconTheme.Space.compact).background(
                    FalconTheme.inset, in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control))
                HStack(spacing: FalconTheme.Space.regular) {
                    Menu {
                        Picker("Time range", selection: $model.hours) {
                            Text("Past hour").tag(1)
                            Text("Past 24 hours").tag(24)
                            Text("Past 7 days").tag(168)
                        }
                        Button("Custom range…") { showRange = true }
                    } label: {
                        Label(
                            model.timeRange != nil
                                ? "Custom range"
                                : model.hours == 168
                                    ? "Past 7 days" : model.hours == 24 ? "Past 24 hours" : "Past hour",
                            systemImage: "clock")
                    }
                    Spacer(minLength: 0)
                    Menu {
                        SourceFilterOptions(model: model)
                        Divider()
                        Picker("Status", selection: $model.statusFilter) {
                            Text("All statuses").tag(nil as RequestStatus?)
                            ForEach(RequestStatus.allCases, id: \.self) { status in
                                Text(status.title).tag(Optional(status))
                            }
                        }
                        Divider()
                        Picker("Review", selection: $model.reviewFilter) {
                            Text("All reviews").tag(nil as ReviewState?)
                            ForEach(ReviewState.allCases, id: \.self) { state in
                                Text(state.rawValue.capitalized).tag(Optional(state))
                            }
                        }
                    } label: {
                        Image(
                            systemName: model.sourceFilters.isEmpty && model.statusFilter == nil
                                && model.reviewFilter == nil
                                ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    }.accessibilityLabel("Filter sources, status and review")
                }.font(FalconTheme.caption).foregroundStyle(FalconTheme.secondary).menuStyle(.borderlessButton)
            }.padding(FalconTheme.Space.large)
            Divider().overlay(FalconTheme.line)
            if model.newArrivalCount > 0 {
                Button {
                    Task { await model.showLatest() }
                } label: {
                    Label(
                        "\(model.newArrivalCount)\(model.newArrivalCount == 100 ? "+" : "") new decisions",
                        systemImage: "arrow.up"
                    ).frame(maxWidth: .infinity)
                }.buttonStyle(FalconButtonStyle(compact: true)).padding(FalconTheme.Space.compact)
            }
            if !model.sourceFilters.isEmpty || model.hasEvidenceFilter {
                HStack {
                    Pill(text: sourceFilterTitle).lineLimit(1).help(sourceFilterTitle)
                    Spacer()
                    Button {
                        model.sourceFilters = []
                        model.clearEvidenceFilters()
                        Task { await model.refresh(reset: true) }
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain).accessibilityLabel("Clear evidence filters")
                }.padding(.horizontal, FalconTheme.Space.large).padding(.vertical, FalconTheme.Space.compact)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: FalconTheme.Space.small) {
                        ForEach(model.requests) { request in
                            Button {
                                Task { await model.select(request.id) }
                            } label: {
                                RequestRow(record: request, selected: model.selectedID == request.id)
                            }.buttonStyle(.plain).id(request.id)
                        }
                        if model.hasMore {
                            Button("Load earlier decisions") { Task { await model.loadMore() } }.buttonStyle(
                                FalconButtonStyle()
                            ).padding(FalconTheme.Space.medium).disabled(model.isLoading)
                        }
                    }.padding(.horizontal, FalconTheme.Space.compact).padding(.vertical, FalconTheme.Space.compact)
                }.onChange(of: model.selectedID) { _, id in
                    if model.followArrivals, let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            HStack {
                Text("\(model.requests.count.formatted()) decisions")
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("Local", systemImage: "internaldrive")
                }
            }.font(FalconTheme.footnote).foregroundStyle(FalconTheme.tertiary).padding(
                .horizontal, FalconTheme.Space.large
            ).padding(.vertical, FalconTheme.Space.regular)
        }.background(FalconTheme.surface).background {
            Button("Search") { searchFocused = true }.keyboardShortcut("f").hidden()
        }.sheet(isPresented: $showRange) {
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
            }.padding(FalconTheme.Space.sheet).frame(width: 420)
        }
    }

    private var sourceFilterTitle: String {
        if model.sourceFilters.count == 1,
            let source = model.sources.first(where: { model.sourceFilters.contains($0.id) })
        {
            return source.name
        }
        return model.sourceFilters.isEmpty ? "Selected evidence" : "\(model.sourceFilters.count) sources"
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

private struct RequestRow: View {
    let record: RequestSummary
    let selected: Bool
    @State private var hovered = false
    var body: some View {
        HStack(alignment: .top, spacing: FalconTheme.Space.compact) {
            SourceAvatar(name: record.sourceName).padding(.top, FalconTheme.Space.micro)
            VStack(alignment: .leading, spacing: FalconTheme.Space.tight) {
                HStack {
                    Text(record.sourceName).font(FalconTheme.label).lineLimit(1)
                    Spacer(minLength: FalconTheme.Space.micro)
                    Text(record.receivedAt, format: .dateTime.hour().minute().second()).font(FalconTheme.monoSmall)
                        .foregroundStyle(FalconTheme.secondary)
                }
                HStack(spacing: FalconTheme.Space.tight) {
                    Image(
                        systemName: record.status == .succeeded
                            ? "arrow.turn.down.right"
                            : record.status.isFailure ? "exclamationmark.circle" : "circle.dotted"
                    ).font(FalconTheme.footnote).foregroundStyle(
                        record.status.isFailure ? FalconTheme.warning : FalconTheme.accent)
                    Text(record.preview.isEmpty ? record.status.title : record.preview).font(FalconTheme.detail)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if record.reviewState == .flagged {
                        Image(systemName: "flag.fill").font(FalconTheme.footnote).foregroundStyle(FalconTheme.warning)
                    }
                }
                HStack(spacing: FalconTheme.Space.tight) {
                    Text("\(record.questionCount) questions · preview")
                    Spacer(minLength: 0)
                    Text(DecisionFormat.duration(record.timing.terminalMS)).monospacedDigit()
                }.font(FalconTheme.footnote).foregroundStyle(FalconTheme.tertiary)
            }
        }.padding(.horizontal, FalconTheme.Space.regular).padding(.vertical, FalconTheme.Space.regular).background(
            selected ? FalconTheme.accentWash : hovered ? FalconTheme.inset : .clear,
            in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
        ).overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: FalconTheme.Radius.small).fill(FalconTheme.accent).frame(
                    width: 2, height: 32
                ).padding(.leading, 1)
            }
        }.contentShape(Rectangle()).onHover { hovered = $0 }.accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
