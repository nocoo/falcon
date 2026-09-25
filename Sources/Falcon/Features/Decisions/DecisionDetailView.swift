import AppKit
import FalconCore
import SwiftUI
import UniformTypeIdentifiers

struct DecisionDetailView: View {
    @Bindable var model: WorkspaceModel
    let detail: RequestDetail
    let presentation: DecisionPresentation
    @State private var rawMode = false
    @State private var rawSelection = 1
    @State private var timelineVisible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(FalconTheme.line)
            if timelineVisible {
                SourceTimelineView(model: model).frame(height: 146).padding(.horizontal, 24).padding(.vertical, 12)
            }
            if let message = detail.summary.errorMessage, model.terminalVisible {
                Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(
                    FalconTheme.warning
                ).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                    FalconTheme.warning.opacity(0.07))
            }
            if rawMode {
                rawContent
            } else if model.inputsVisible {
                GeometryReader { geometry in
                    if geometry.size.width >= 850 {
                        HSplitView {
                            statePanel.frame(
                                minWidth: 280, idealWidth: geometry.size.width * 0.39,
                                maxWidth: geometry.size.width * 0.42, maxHeight: .infinity)
                            questionsPanel.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if !model.focusReview {
                                    Button {
                                        model.focusReview = true
                                    } label: {
                                        Label(
                                            "Focus review for more reading space",
                                            systemImage: "arrow.up.left.and.arrow.down.right")
                                    }.buttonStyle(FalconButtonStyle(compact: true)).padding(20)
                                }
                                stateHeading
                                stateContent
                                Divider()
                                questionsHeading
                                questionContent
                            }
                        }.id(detail.id)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Input has not arrived yet", systemImage: "clock.arrow.circlepath",
                    description: Text("The complete input becomes visible when the request body has been received.")
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            reviewBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 12) {
                SourceAvatar(name: detail.summary.sourceName, size: 38)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(detail.summary.sourceName).font(.system(size: 21, weight: .semibold)).tracking(-0.4)
                        Pill(text: detail.summary.transport.rawValue.uppercased())
                        if let project = detail.summary.metadata["project"]
                            ?? detail.summary.metadata["X-Falcon-Project"]
                        {
                            Text("/ \(project)").font(.system(size: 13)).foregroundStyle(FalconTheme.secondary).help(
                                "Self-reported project")
                        }
                    }
                    Text(
                        detail.summary.receivedAt.formatted(
                            .dateTime.month(.abbreviated).day().hour().minute().second().secondFraction(.fractional(3)))
                    ).font(.system(size: 12, design: .monospaced)).foregroundStyle(FalconTheme.secondary).help(
                        "Received at \(detail.summary.receivedAt.ISO8601Format()) · \(TimeZone.current.identifier)")
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
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
                    Text(String(detail.id.uuidString.lowercased().prefix(8))).font(
                        .system(size: 11, design: .monospaced)
                    ).foregroundStyle(FalconTheme.tertiary).textSelection(.enabled).help(detail.id.uuidString)
                }
            }
            HStack(spacing: 0) {
                metric(
                    "UPSTREAM",
                    value: DecisionFormat.duration(model.resultsVisible ? detail.summary.timing.upstreamMS : nil),
                    help: "Network and upstream processing combined")
                metric(
                    "PROCESSING",
                    value: DecisionFormat.duration(model.terminalVisible ? detail.summary.timing.terminalMS : nil),
                    help: "Before final audit commit and local response write")
                metric(
                    "RETURNED IN",
                    value: DecisionFormat.duration(
                        model.deliveryVisible ? detail.summary.timing.deliveryFinishedMS : nil),
                    help: "Local write completion; does not prove the agent consumed the result")
                metric(
                    "TOKENS IN / OUT",
                    value:
                        "\(DecisionFormat.tokens(model.resultsVisible ? detail.summary.inputTokens : nil)) / \(DecisionFormat.tokens(model.resultsVisible ? detail.summary.outputTokens : nil))"
                )
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Eyebrow(title: "Model")
                    Text((model.resultsVisible ? detail.summary.resolvedModel : nil) ?? detail.summary.requestedModel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).help(
                            "Requested: \(detail.summary.requestedModel)\nConnection: \(detail.summary.profileName), revision \(detail.summary.profileRevision)"
                        )
                }
            }
            HStack(spacing: 7) {
                Button {
                    rawMode.toggle()
                } label: {
                    Label(
                        rawMode ? "Overview" : "Raw JSON", systemImage: rawMode ? "rectangle.split.2x1" : "curlybraces")
                }
                Button {
                    timelineVisible.toggle()
                } label: {
                    Label("Timeline", systemImage: "chart.bar.xaxis")
                }
                Menu {
                    Button("Replay this decision") { Task { await model.startReplay(range: false) } }
                    Button("Replay filtered range") { Task { await model.startReplay(range: true) } }
                    if model.timeline != nil { Button("Show final result") { model.stopReplay() } }
                } label: {
                    Label("Replay", systemImage: "play.circle")
                }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 7)
                Spacer()
                Button {
                    copyRaw()
                } label: {
                    Image(systemName: "doc.on.doc")
                }.help("Copy selected JSON").accessibilityLabel("Copy decision JSON")
                Button {
                    Task { await exportJSON() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }.disabled(model.timeline != nil).help("Show the final result to export the complete evidence.")
            }.buttonStyle(FalconButtonStyle(compact: true))
        }.padding(.horizontal, 26).padding(.top, 23).padding(.bottom, 18)
    }

    private func metric(_ title: String, value: String, help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(title: title)
            Text(value).font(.system(size: 14, weight: .medium, design: .monospaced)).monospacedDigit()
        }.padding(.trailing, 28).help(help)
    }

    private var statePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateHeading
            ScrollView { stateContent }.id(detail.id)
        }.background(FalconTheme.surface.opacity(0.55))
    }

    private var stateHeading: some View {
        HStack {
            Label("State", systemImage: "text.alignleft").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("INPUT CONTEXT").font(.system(size: 11, weight: .medium)).tracking(1).foregroundStyle(
                FalconTheme.tertiary)
        }.padding(.horizontal, 22).padding(.top, 21).padding(.bottom, 19)
    }

    private var stateContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let state = presentation.state {
                StateTree(value: state)
            } else {
                Text("No complete state was recorded.").foregroundStyle(FalconTheme.secondary)
            }
            if let define = presentation.define {
                Divider()
                Eyebrow(title: "define · original field")
                Text(define.displayText).font(FalconTheme.mono).textSelection(.enabled)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow(title: "Request evidence")
                Text("\(detail.summary.questionCount) questions in one request")
                Text(detail.summary.baseURL).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("Source identity comes from its local key. Labels are self-reported.").font(.system(size: 11))
                    .lineSpacing(3).foregroundStyle(FalconTheme.secondary)
            }
        }.padding(.horizontal, 22).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var questionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionsHeading
            ScrollView { questionContent }.id(detail.id)
        }
    }

    private var questionsHeading: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Questions & decisions", systemImage: "arrow.triangle.branch").font(
                    .system(size: 14, weight: .semibold))
                Spacer()
                Text("\(presentation.questions.count) QUESTIONS").font(.system(size: 11, weight: .medium)).tracking(0.8)
                    .foregroundStyle(FalconTheme.tertiary)
            }.padding(.horizontal, 22).padding(.top, 21).padding(.bottom, 19)
            if !model.resultsVisible {
                Label("Results have not returned at this playback time", systemImage: "clock").font(.system(size: 12))
                    .foregroundStyle(FalconTheme.secondary).padding(.horizontal, 22).padding(.bottom, 14)
            }
        }
    }

    private var questionContent: some View {
        LazyVStack(spacing: 14) {
            ForEach(presentation.questions) { question in
                QuestionCard(question: question, showResult: model.resultsVisible)
            }
        }.padding(.horizontal, 20).padding(.bottom, 24)
    }

    private var rawContent: some View {
        VStack(spacing: 0) {
            Picker("Raw evidence", selection: $rawSelection) {
                Text("Received request").tag(0)
                Text("Sent to Jev").tag(1)
                Text("Upstream response").tag(2)
            }.pickerStyle(.segmented).padding(16).frame(maxWidth: 650)
            if (rawSelection == 2 && !model.resultsVisible) || (rawSelection != 2 && !model.inputsVisible) {
                ContentUnavailableView(
                    "Not yet available", systemImage: "clock",
                    description: Text("Advance the playback cursor to the recorded event.")
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JSONTextView(text: selectedRaw).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedRaw: String {
        let data =
            rawSelection == 0
            ? detail.receivedRequest : rawSelection == 1 ? detail.effectiveRequest : detail.upstreamResponse
        guard let data else { return "No data recorded for this stage." }
        return String(data: data, encoding: .utf8)
            ?? "This body is not valid UTF-8. Original bytes (Base64):\n\n\(data.base64EncodedString())"
    }

    private var reviewBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.reviewState == .flagged ? "flag" : "checkmark.circle").foregroundStyle(
                FalconTheme.secondary)
            Picker(
                "Review",
                selection: Binding(
                    get: { model.reviewState },
                    set: { value in
                        model.editReview(value)
                        Task { await model.saveReview() }
                    })
            ) {
                Text("Unreviewed").tag(ReviewState.unreviewed)
                Text("Reviewed").tag(ReviewState.reviewed)
                Text("Needs attention").tag(ReviewState.flagged)
            }.labelsHidden().frame(width: 140)
            Divider().frame(height: 18).padding(.horizontal, 3)
            TextField("Add a review note…", text: Binding(get: { model.note }, set: model.editNote)).textFieldStyle(
                .plain
            ).font(.system(size: 12)).onSubmit { Task { await model.saveReview() } }
            if model.noteIsDirty {
                Button("Save") { Task { await model.saveReview() } }.buttonStyle(FalconButtonStyle(compact: true))
            }
        }.padding(.horizontal, 23).frame(height: 53).background(FalconTheme.surface).overlay(alignment: .top) {
            Rectangle().fill(FalconTheme.line).frame(height: 0.75)
        }
    }

    private func copyRaw() {
        model.validateExpiry()
        guard model.detail?.id == detail.id, model.isActive,
            rawSelection == 2 ? model.resultsVisible : model.inputsVisible
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedRaw, forType: .string)
    }

    private func exportJSON() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "falcon-\(detail.id.uuidString.lowercased()).json"
        panel.message = "Exported files are outside Falcon’s automatic seven-day retention."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { try await model.exportJSON().write(to: url, options: .atomic) } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct StateTree: View {
    let value: JSONValue
    private var keys: [String] {
        let priority = ["task", "proposed_action", "facts", "constraints"]
        return (value.objectValue?.keys.sorted() ?? []).sorted {
            let left = priority.firstIndex(of: $0) ?? 100
            let right = priority.firstIndex(of: $1) ?? 100
            return left == right ? $0 < $1 : left < right
        }
    }
    var body: some View {
        if let object = value.objectValue {
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(title: key.replacingOccurrences(of: "_", with: " "))
                    StateValue(value: object[key] ?? .null)
                }
            }
        } else {
            StateValue(value: value)
        }
    }
}

private struct StateValue: View {
    let value: JSONValue
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let array = value.arrayValue {
                ForEach(Array(array.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(FalconTheme.tertiary.opacity(0.5)).frame(width: 3, height: 3).padding(.top, 7)
                        Text(item.displayText).lineSpacing(4).textSelection(.enabled).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(value.displayText).lineSpacing(5).textSelection(.enabled).lineLimit(expanded ? nil : 12).fixedSize(
                    horizontal: false, vertical: true)
                if value.displayText.count > 600 {
                    Button(expanded ? "Show less" : "Show full text") { expanded.toggle() }.buttonStyle(.plain)
                        .foregroundStyle(FalconTheme.accent)
                }
            }
        }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JSONTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindPanel = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 20, height: 18)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Original JSON evidence")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.textColor = NSColor(FalconTheme.ink)
        view.backgroundColor = NSColor(FalconTheme.surface)
    }
}
