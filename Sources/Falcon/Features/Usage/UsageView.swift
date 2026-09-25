import AppKit
import Charts
import FalconCore
import SwiftUI
import UniformTypeIdentifiers

struct UsageView: View {
    @Bindable var model: WorkspaceModel
    @State private var selectedDate: Date?
    private var usage: UsageSnapshot { model.usage }
    private var latencyBuckets: [LatencyBucket] {
        model.usageShowsReturn ? usage.returnLatencies : usage.processingLatencies
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                PageHeading(title: "Decision activity", subtitle: "Understand how your agents use Jev over time.") {
                    HStack(spacing: FalconTheme.Space.compact) {
                        Picker("Time range", selection: $model.hours) {
                            Text("1 hour").tag(1)
                            Text("24 hours").tag(24)
                            Text("7 days").tag(168)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: FalconTheme.Layout.rangeSwitchWidth)
                        Button {
                            Task { await exportCSV() }
                        } label: {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }.buttonStyle(FalconButtonStyle())
                    }
                }
                HStack(spacing: FalconTheme.Space.medium) {
                    usageMetric(
                        "Requests", value: usage.requests.formatted(),
                        caption: "\(usage.questions.formatted()) questions")
                    usageMetric(
                        "Upstream success",
                        value: usage.forwardedTerminal == 0
                            ? "—"
                            : DecisionFormat.probability(Double(usage.succeeded) / Double(usage.forwardedTerminal)),
                        caption: "\(usage.succeeded) of \(usage.forwardedTerminal) forwarded & finished")
                    usageMetric(
                        "Processing p95", value: DecisionFormat.duration(usage.p95MS),
                        caption: "\(usage.latencySamples) samples · \(usage.missingLatency) unknown")
                    usageMetric(
                        "Tokens", value: DecisionFormat.tokens(usage.totalTokens),
                        caption: "\(usage.unknownUsage) requests with unknown usage")
                }.fixedSize(horizontal: false, vertical: true).id("overview")
                Surface(inset: FalconTheme.Space.section) {
                    VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                        HStack {
                            Text(model.usageShowsTokens ? "Tokens over time" : "Requests over time").font(
                                FalconTheme.sectionTitle)
                            Spacer()
                            Picker("Activity metric", selection: $model.usageShowsTokens) {
                                Text("Requests").tag(false)
                                Text("Tokens").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 175)
                        }.font(FalconTheme.footnote)
                        if usage.buckets.isEmpty {
                            ContentUnavailableView("No requests in this range", systemImage: "chart.xyaxis.line").frame(
                                height: 220)
                        } else {
                            Chart(usage.buckets) { bucket in
                                if model.usageShowsTokens {
                                    if let tokens = bucket.inputTokens {
                                        BarMark(x: .value("Time", bucket.date), y: .value("Tokens", tokens))
                                            .foregroundStyle(by: .value("Kind", "Input")).position(
                                                by: .value("Kind", "Input"))
                                    }
                                    if let tokens = bucket.outputTokens {
                                        BarMark(x: .value("Time", bucket.date), y: .value("Tokens", tokens))
                                            .foregroundStyle(by: .value("Kind", "Output")).position(
                                                by: .value("Kind", "Output"))
                                    }
                                } else {
                                    BarMark(
                                        x: .value("Time", bucket.date),
                                        y: .value("Requests", bucket.requests - bucket.failures)
                                    ).foregroundStyle(by: .value("Kind", "Completed or in progress"))
                                    BarMark(x: .value("Time", bucket.date), y: .value("Requests", bucket.failures))
                                        .foregroundStyle(by: .value("Kind", "Failed"))
                                }
                            }.chartForegroundStyleScale(range: [FalconTheme.accent, FalconTheme.warning])
                                .chartXSelection(value: $selectedDate).chartXAxis {
                                    AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                                        AxisGridLine()
                                        AxisValueLabel(
                                            format: model.hours == 168
                                                ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute())
                                    }
                                }.chartXScale(range: .plotDimension(padding: 16)).chartYAxis {
                                    AxisMarks(position: .leading)
                                }.frame(height: 236)
                            Text("Select a bar to inspect its decisions.").font(FalconTheme.footnote).foregroundStyle(
                                FalconTheme.secondary)
                            if usage.totalTokens == nil {
                                Text("Token totals exceed the supported numeric range. Unavailable values are omitted.")
                                    .font(FalconTheme.footnote).foregroundStyle(FalconTheme.warning)
                            }
                        }
                    }
                }.id("activity")
                HStack(alignment: .top, spacing: FalconTheme.Space.large) {
                    Surface(inset: FalconTheme.Space.section) {
                        VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                            HStack {
                                Text("By source").font(FalconTheme.sectionTitle)
                                Spacer()
                                Eyebrow(title: "Requests")
                            }
                            ForEach(usage.sources.sorted { $0.requests > $1.requests }) { source in
                                Button {
                                    model.sourceFilters = [source.id]
                                    model.page = .decisions
                                } label: {
                                    HStack(spacing: FalconTheme.Space.regular) {
                                        SourceAvatar(name: source.name)
                                        VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
                                            HStack {
                                                Text(source.name).font(FalconTheme.body)
                                                Spacer()
                                                Text(source.requests.formatted()).font(FalconTheme.mono)
                                            }
                                            GeometryReader { geometry in
                                                Capsule().fill(FalconTheme.inset)
                                                Capsule().fill(FalconTheme.accent).frame(
                                                    width: geometry.size.width * Double(source.requests)
                                                        / Double(max(1, usage.requests)))
                                            }.frame(height: 5)
                                        }
                                        Image(systemName: "arrow.up.right").font(FalconTheme.footnote).foregroundStyle(
                                            FalconTheme.tertiary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel(
                                    "\(source.name), \(source.requests) requests. View decisions.")
                            }
                            if usage.sources.isEmpty {
                                Text("Sources appear after their first request.").foregroundStyle(FalconTheme.secondary)
                            }
                        }
                    }
                    Surface(inset: FalconTheme.Space.section) {
                        VStack(alignment: .leading, spacing: FalconTheme.Space.large) {
                            Text("Quality & timing").font(FalconTheme.sectionTitle)
                            summaryRow("Median processing", DecisionFormat.duration(usage.p50MS))
                            summaryRow("p95 processing", DecisionFormat.duration(usage.p95MS))
                            summaryRow("Median returned", DecisionFormat.duration(usage.returnP50MS))
                            summaryRow("p95 returned", DecisionFormat.duration(usage.returnP95MS))
                            Text(
                                "Return: \(usage.returnLatencySamples) written · \(usage.missingReturnLatency) unknown"
                            ).font(FalconTheme.footnote).foregroundStyle(FalconTheme.secondary)
                            Divider()
                            summaryRow("Failed / finished", "\(usage.failures) / \(usage.terminal)")
                            summaryRow("Still in progress", (usage.requests - usage.terminal).formatted())
                            Divider()
                            summaryRow("Input tokens", DecisionFormat.tokens(usage.inputTokens))
                            summaryRow("Output tokens", DecisionFormat.tokens(usage.outputTokens))
                            Text(
                                "Processing includes local preparation and upstream time. "
                                    + "Missing timings and token counts remain unknown."
                            ).font(FalconTheme.footnote).foregroundStyle(FalconTheme.secondary).lineSpacing(
                                FalconTheme.Space.small)
                        }
                    }.frame(maxWidth: 380)
                }.id("sources")
                HStack(alignment: .top, spacing: FalconTheme.Space.large) {
                    Surface(inset: FalconTheme.Space.section) {
                        VStack(alignment: .leading, spacing: FalconTheme.Space.large) {
                            HStack {
                                Text("Latency distribution").font(FalconTheme.sectionTitle)
                                Spacer()
                                Picker("Latency", selection: $model.usageShowsReturn) {
                                    Text("Processing").tag(false)
                                    Text("Returned").tag(true)
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 195)
                            }
                            Chart(latencyBuckets) { bucket in
                                BarMark(x: .value("Time", bucket.label), y: .value("Requests", bucket.count))
                                    .foregroundStyle(FalconTheme.accent.gradient).cornerRadius(3)
                            }.frame(height: 160)
                            Text(
                                "\(model.usageShowsReturn ? usage.returnLatencySamples : usage.latencySamples) measured requests · \(model.usageShowsReturn ? usage.missingReturnLatency : usage.missingLatency) without a known duration"
                            ).font(FalconTheme.footnote).foregroundStyle(FalconTheme.secondary)
                        }
                    }
                    Surface(inset: FalconTheme.Space.section) {
                        VStack(alignment: .leading, spacing: FalconTheme.Space.medium) {
                            Text("Models & question types").font(FalconTheme.sectionTitle)
                            ForEach(usage.models) { item in summaryRow(item.name, "\(item.count) requests") }
                            Divider()
                            ForEach(usage.questionTypes) { item in
                                summaryRow(item.name.capitalized, "\(item.count) questions")
                            }
                            summaryRow("Completed questions", "\(usage.completedQuestions) / \(usage.questions)")
                        }
                    }.frame(maxWidth: 380)
                }.id("latency")
                HStack(alignment: .top, spacing: FalconTheme.Space.large) {
                    ProbabilityDistribution(
                        title: "Confidence", subtitle: "Choice & Score · concentration, not accuracy",
                        buckets: usage.confidence, missing: usage.missingConfidence
                    ) { band in
                        model.confidenceFilter = band
                        model.noulFilter = nil
                        model.page = .decisions
                    }
                    ProbabilityDistribution(
                        title: "Noul yes probability", subtitle: "Probability of yes · no decision threshold",
                        buckets: usage.noul, missing: usage.missingNoul
                    ) { band in
                        model.noulFilter = band
                        model.confidenceFilter = nil
                        model.page = .decisions
                    }
                }.id("probability")
                DecisionGroupsView(groups: usage.decisionGroups, omitted: usage.omittedDecisionGroups) { group in
                    model.fingerprintFilter = group.fingerprint
                    model.page = .decisions
                }.id("definitions")
                Text("Rolling seven-day history · UTC time buckets, displayed in \(TimeZone.current.identifier)").font(
                    FalconTheme.footnote
                ).foregroundStyle(FalconTheme.tertiary)
            }.scrollTargetLayout().padding(FalconTheme.Space.page).frame(
                maxWidth: FalconTheme.Layout.pageWidth, alignment: .leading
            ).frame(maxWidth: .infinity, alignment: .topLeading)
        }.scrollPosition(id: $model.usageScrollID, anchor: .top).onChange(of: selectedDate) { _, date in
            guard let date,
                let bucket = usage.buckets.min(by: {
                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                })
            else { return }
            model.inspectBucket(bucket)
            selectedDate = nil
        }
    }

    private func usageMetric(_ title: String, value: String, caption: String) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
                Text(title).font(FalconTheme.label).foregroundStyle(FalconTheme.secondary)
                Text(value).font(FalconTheme.metric).tracking(FalconTheme.titleTracking)
                Text(caption).font(FalconTheme.footnote).foregroundStyle(FalconTheme.tertiary)
            }.frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(FalconTheme.secondary)
            Spacer()
            Text(value).font(FalconTheme.mono)
        }
    }
    private func exportCSV() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "falcon-decisions.csv"
        panel.message = "Exported files are outside automatic seven-day retention."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { try await model.exportCSV().write(to: url, atomically: true, encoding: .utf8) } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
