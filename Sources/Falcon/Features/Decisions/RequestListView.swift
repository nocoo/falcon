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
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Activity").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                    Spacer()
                    Menu {
                        Button("Replay this range") { Task { await model.startReplay(range: true) } }
                        Button("Refresh") { Task { await model.refresh(reset: true) } }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 20, height: 20)
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(FalconTheme.tertiary)
                    TextField("Search decisions", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                        .focused($searchFocused)
                    if !model.search.isEmpty {
                        Button {
                            model.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(8).background(FalconTheme.inset, in: RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 10) {
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
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(FalconTheme.secondary).menuStyle(
                    .borderlessButton)
            }.padding(18)
            Divider().overlay(FalconTheme.line)
            if model.newArrivalCount > 0 {
                Button {
                    Task { await model.showLatest() }
                } label: {
                    Label(
                        "\(model.newArrivalCount)\(model.newArrivalCount == 100 ? "+" : "") new decisions",
                        systemImage: "arrow.up"
                    ).frame(maxWidth: .infinity)
                }.buttonStyle(FalconButtonStyle(compact: true)).padding(8)
            }
            if !model.sourceFilters.isEmpty || model.hasEvidenceFilter {
                HStack {
                    Pill(
                        text: model.sourceFilters.isEmpty ? "Selected evidence" : "\(model.sourceFilters.count) sources"
                    )
                    Spacer()
                    Button {
                        model.sourceFilters = []
                        model.clearEvidenceFilters()
                        Task { await model.refresh(reset: true) }
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain).accessibilityLabel("Clear evidence filters")
                }.padding(.horizontal, 18).padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
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
                            ).padding(14).disabled(model.isLoading)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 9)
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
            }.font(.system(size: 11)).foregroundStyle(FalconTheme.tertiary).padding(.horizontal, 18).padding(
                .vertical, 12)
        }.background(FalconTheme.surface).background {
            Button("Search") { searchFocused = true }.keyboardShortcut("f").hidden()
        }.sheet(isPresented: $showRange) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Review a time range").font(.title2)
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
            }.padding(28).frame(width: 420)
        }
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
        HStack(alignment: .top, spacing: 9) {
            SourceAvatar(name: record.sourceName, size: 27).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(record.sourceName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(record.receivedAt, format: .dateTime.hour().minute().second()).font(
                        .system(size: 11, design: .monospaced)
                    ).foregroundStyle(FalconTheme.secondary)
                }
                HStack(spacing: 5) {
                    Image(
                        systemName: record.status == .succeeded
                            ? "arrow.turn.down.right"
                            : record.status.isFailure ? "exclamationmark.circle" : "circle.dotted"
                    ).font(.system(size: 11)).foregroundStyle(
                        record.status.isFailure ? FalconTheme.warning : FalconTheme.accent)
                    Text(record.preview.isEmpty ? record.status.title : record.preview).font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if record.reviewState == .flagged {
                        Image(systemName: "flag.fill").font(.system(size: 11)).foregroundStyle(FalconTheme.warning)
                    }
                }
                HStack(spacing: 5) {
                    Text("\(record.questionCount) questions · preview")
                    Spacer(minLength: 0)
                    Text(DecisionFormat.duration(record.timing.terminalMS)).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(FalconTheme.tertiary)
            }
        }.padding(.horizontal, 10).padding(.vertical, 11).background(
            selected ? FalconTheme.accentWash : hovered ? FalconTheme.inset : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        ).overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(FalconTheme.accent).frame(width: 2, height: 32).padding(
                    .leading, 1)
            }
        }.contentShape(Rectangle()).onHover { hovered = $0 }.accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
