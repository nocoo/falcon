import FalconCore
import SwiftUI

struct DecisionHeader: View {
    @Bindable var model: WorkspaceModel
    let detail: RequestDetail
    @Binding var rawMode: Bool
    @Binding var timelineVisible: Bool
    let copyJSON: () -> Void
    let exportJSON: () -> Void
    @State private var pendingUnstar: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
            identity
            controls
            metrics
        }.padding(.horizontal, FalconTheme.Space.section).padding(.vertical, FalconTheme.Space.medium).background(
            FalconTheme.reader
        ).confirmationDialog(
            "Remove this saved decision?",
            isPresented: Binding(get: { pendingUnstar != nil }, set: { if !$0 { pendingUnstar = nil } }),
            titleVisibility: .visible, presenting: pendingUnstar
        ) { id in
            Button("Remove star and delete", role: .destructive) { Task { await model.toggleStar(id: id) } }
        } message: { _ in
            Text("This decision is older than seven days. Removing its star also removes its saved evidence.")
        }
    }

    private var identity: some View {
        HStack(spacing: FalconTheme.Space.regular) {
            SourceAvatar(
                iconID: model.sources.first { $0.id == detail.summary.sourceID }?.iconID,
                size: FalconTheme.Layout.detailAvatar)
            VStack(alignment: .leading, spacing: FalconTheme.Space.small) {
                HStack(spacing: FalconTheme.Space.compact) {
                    Text(detail.summary.sourceName).font(FalconTheme.title).tracking(FalconTheme.titleTracking)
                        .lineLimit(1).help(detail.summary.sourceName).accessibilityAddTraits(.isHeader)
                    Pill(text: detail.summary.transport.rawValue.uppercased())
                    if let project = detail.summary.metadata["project"] ?? detail.summary.metadata["X-Falcon-Project"] {
                        Text("/ " + project).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary).lineLimit(
                            1
                        ).help("Self-reported project: " + project)
                    }
                }
                Text(
                    detail.summary.receivedAt.formatted(
                        .dateTime.month(.abbreviated).day().hour().minute().second().secondFraction(.fractional(3)))
                ).font(FalconTheme.monoSmall).foregroundStyle(FalconTheme.secondary).help(
                    "Received at \(detail.summary.receivedAt.ISO8601Format()) · \(TimeZone.current.identifier)")
            }
            Spacer(minLength: FalconTheme.Space.compact)
            VStack(alignment: .trailing, spacing: FalconTheme.Space.small) {
                Pill(
                    text: model.visibleStatus,
                    color: !model.terminalVisible
                        ? FalconTheme.secondary
                        : detail.summary.status.isFailure ? FalconTheme.warning : FalconTheme.success,
                    symbol: !model.terminalVisible
                        ? "circle.dotted"
                        : detail.summary.status == .succeeded
                            ? "checkmark.circle.fill"
                            : detail.summary.status.isFailure ? "exclamationmark.circle" : "circle.dotted")
                Text(String(detail.id.uuidString.lowercased().prefix(8))).font(FalconTheme.monoSmall).foregroundStyle(
                    FalconTheme.tertiary
                ).textSelection(.enabled).help(detail.id.uuidString)
            }.fixedSize()
        }
    }

    private var controls: some View {
        HStack(spacing: FalconTheme.Space.compact) {
            Picker("Evidence view", selection: $rawMode) {
                Text("Overview").tag(false)
                Text("Raw JSON").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: FalconTheme.Layout.modeSwitchWidth)
            Button {
                timelineVisible.toggle()
            } label: {
                Label("Timeline", systemImage: "chart.bar.xaxis")
            }.buttonStyle(FalconButtonStyle(compact: true, selected: timelineVisible)).accessibilityAddTraits(
                timelineVisible ? .isSelected : [])
            Menu {
                Button("Replay this decision") { Task { await model.startReplay(range: false) } }
                Button("Replay filtered range") { Task { await model.startReplay(range: true) } }
                if model.timeline != nil { Button("Show final result") { model.stopReplay() } }
            } label: {
                Label("Replay", systemImage: "play.circle")
            }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, FalconTheme.Space.compact)
            Spacer(minLength: 0)
            Button {
                if detail.summary.isStarred, detail.summary.expiresAt <= Date() {
                    pendingUnstar = detail.id
                } else {
                    Task { await model.toggleStar(id: detail.id) }
                }
            } label: {
                Image(systemName: detail.summary.isStarred ? "star.fill" : "star").foregroundStyle(
                    detail.summary.isStarred ? FalconTheme.warning : FalconTheme.secondary)
            }.disabled(model.isUpdatingStar || model.isTriaging).keyboardShortcut("s", modifiers: [.command, .shift])
                .help(
                    detail.summary.isStarred
                        ? "Remove star · return to seven-day retention" : "Star · keep indefinitely"
                ).accessibilityLabel(detail.summary.isStarred ? "Remove star" : "Star decision").accessibilityValue(
                    detail.summary.isStarred ? "Kept indefinitely" : "Not starred")
            Button {
                copyJSON()
            } label: {
                Image(systemName: "doc.on.doc")
            }.help("Copy selected JSON").accessibilityLabel("Copy decision JSON")
            Button {
                exportJSON()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }.disabled(model.timeline != nil).help("Show the final result to export the complete evidence.")
        }.buttonStyle(FalconButtonStyle(compact: true))
    }

    private var metrics: some View {
        HStack(spacing: FalconTheme.Space.medium) {
            metric(
                "Upstream",
                value: DecisionFormat.duration(model.resultsVisible ? detail.summary.timing.upstreamMS : nil),
                help: "Network and upstream processing combined")
            metric(
                "Processing",
                value: DecisionFormat.duration(model.terminalVisible ? detail.summary.timing.terminalMS : nil),
                help: "Before final audit commit and local response write")
            metric(
                "Returned in",
                value: DecisionFormat.duration(model.deliveryVisible ? detail.summary.timing.deliveryFinishedMS : nil),
                help: "Local write completion; does not prove the agent consumed the result")
            metric(
                "Tokens in / out",
                value: "\(DecisionFormat.tokens(model.resultsVisible ? detail.summary.inputTokens : nil)) / "
                    + "\(DecisionFormat.tokens(model.resultsVisible ? detail.summary.outputTokens : nil))")
            metric(
                "Model",
                value: (model.resultsVisible ? detail.summary.resolvedModel : nil) ?? detail.summary.requestedModel,
                alignment: .trailing,
                help: "Requested: \(detail.summary.requestedModel)\n"
                    + "Connection: \(detail.summary.profileName), revision \(detail.summary.profileRevision)")
        }
    }

    private func metric(_ title: String, value: String, alignment: HorizontalAlignment = .leading, help: String = "")
        -> some View
    {
        VStack(alignment: alignment, spacing: FalconTheme.Space.small) {
            Text(title).font(FalconTheme.caption).foregroundStyle(FalconTheme.secondary)
            Text(value).font(FalconTheme.monoValue).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing).help(help)
    }
}
