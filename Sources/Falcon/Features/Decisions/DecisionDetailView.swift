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
            DecisionHeader(
                model: model, detail: detail, rawMode: $rawMode, timelineVisible: $timelineVisible, copyJSON: copyRaw,
                exportJSON: { Task { await exportJSON() } })
            Divider().overlay(FalconTheme.line)
            if timelineVisible {
                SourceTimelineView(model: model).frame(height: 146).padding(.horizontal, FalconTheme.Space.section)
                    .padding(.vertical, FalconTheme.Space.regular)
            }
            if let message = detail.summary.errorMessage, model.terminalVisible {
                Label(message, systemImage: "exclamationmark.circle").font(FalconTheme.detail).foregroundStyle(
                    FalconTheme.danger
                ).padding(FalconTheme.Space.regular).frame(maxWidth: .infinity, alignment: .leading).background(
                    FalconTheme.danger.opacity(0.07))
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
                                    }.buttonStyle(FalconButtonStyle(compact: true)).padding(FalconTheme.Space.large)
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
            DecisionReviewBar(model: model, record: detail.summary)
        }
    }

    private var statePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateHeading
            ScrollView { stateContent }.id(detail.id)
        }.background(FalconTheme.reader)
    }

    private var stateHeading: some View {
        HStack {
            Label("State", systemImage: "text.alignleft").font(FalconTheme.sectionTitle)
            Spacer()
            Text("INPUT CONTEXT").font(FalconTheme.caption).tracking(FalconTheme.labelTracking).foregroundStyle(
                FalconTheme.tertiary)
        }.padding(.horizontal, FalconTheme.Space.section).padding(.top, FalconTheme.Space.section).padding(
            .bottom, FalconTheme.Space.large)
    }

    private var stateContent: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
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
            VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
                Eyebrow(title: "Request evidence")
                Text("\(detail.summary.questionCount) questions in one request")
                Text(detail.summary.baseURL).font(FalconTheme.monoSmall).textSelection(.enabled)
                Text("Source identity comes from its local key. Labels are self-reported.").font(FalconTheme.footnote)
                    .lineSpacing(FalconTheme.Space.small).foregroundStyle(FalconTheme.secondary)
            }
        }.padding(.horizontal, FalconTheme.Space.section).padding(.bottom, FalconTheme.Space.section).frame(
            maxWidth: .infinity, alignment: .leading)
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
                Label("Questions & decisions", systemImage: "arrow.triangle.branch").font(FalconTheme.sectionTitle)
                Spacer()
                Text("\(presentation.questions.count) QUESTIONS").font(FalconTheme.caption).tracking(
                    FalconTheme.labelTracking
                ).foregroundStyle(FalconTheme.tertiary)
            }.padding(.horizontal, FalconTheme.Space.section).padding(.top, FalconTheme.Space.section).padding(
                .bottom, FalconTheme.Space.large)
            if !model.resultsVisible {
                Label("Results have not returned at this playback time", systemImage: "clock").font(FalconTheme.detail)
                    .foregroundStyle(FalconTheme.secondary).padding(.horizontal, FalconTheme.Space.section).padding(
                        .bottom, FalconTheme.Space.medium)
            }
        }
    }

    private var questionContent: some View {
        LazyVStack(spacing: FalconTheme.Space.medium) {
            ForEach(presentation.questions) { question in
                QuestionCard(question: question, showResult: model.resultsVisible)
            }
        }.padding(.horizontal, FalconTheme.Space.large).padding(.bottom, FalconTheme.Space.section)
    }

    private var rawContent: some View {
        VStack(spacing: 0) {
            Picker("Raw evidence", selection: $rawSelection) {
                Text("Received request").tag(0)
                Text("Sent to Jev").tag(1)
                Text("Upstream response").tag(2)
            }.pickerStyle(.segmented).padding(FalconTheme.Space.medium).frame(maxWidth: 650)
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

    private func copyRaw() {
        model.validateExpiry()
        guard model.detail?.id == detail.id, model.selectedID == detail.id, model.isActive,
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
                VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
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
        VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
            if let array = value.arrayValue {
                ForEach(Array(array.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: FalconTheme.Space.compact) {
                        Circle().fill(FalconTheme.tertiary.opacity(0.5)).frame(width: 3, height: 3).padding(
                            .top, FalconTheme.Space.compact)
                        Text(item.displayText).lineSpacing(FalconTheme.Space.small).textSelection(.enabled).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(value.displayText).lineSpacing(FalconTheme.Space.small).textSelection(.enabled).lineLimit(
                    expanded ? nil : 12
                ).fixedSize(horizontal: false, vertical: true)
                if value.displayText.count > 600 {
                    Button(expanded ? "Show less" : "Show full text") { expanded.toggle() }.buttonStyle(.plain)
                        .foregroundStyle(FalconTheme.accent)
                }
            }
        }.font(FalconTheme.body).frame(maxWidth: .infinity, alignment: .leading)
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
        view.font = .monospacedSystemFont(ofSize: FalconTheme.codePointSize, weight: .regular)
        view.textContainerInset = NSSize(width: FalconTheme.Space.section, height: FalconTheme.Space.medium)
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
