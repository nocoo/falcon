import Charts
import FalconCore
import SwiftUI

struct ReplayBar: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(model.selectedEvents) { event in
                    Button {
                        model.seekEvent(event)
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(event.date <= model.playbackDate ? FalconTheme.accent : FalconTheme.line)
                                .frame(width: 5, height: 5)
                            Text(event.stage.title)
                        }.font(.system(size: 11)).foregroundStyle(
                            event.date <= model.playbackDate ? FalconTheme.ink : FalconTheme.secondary)
                    }.buttonStyle(.plain).help(event.date.ISO8601Format())
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Pill(text: "Historical replay", symbol: "clock.arrow.circlepath")
                Button {
                    model.step(forward: false)
                } label: {
                    Image(systemName: "backward.end")
                }.help("Previous event").accessibilityLabel("Previous event")
                Button {
                    if model.isPlaying { model.pauseReplay() } else { model.play() }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }.help(model.isPlaying ? "Pause replay" : "Play replay").accessibilityLabel(
                    model.isPlaying ? "Pause replay" : "Play replay")
                Button {
                    model.step(forward: true)
                } label: {
                    Image(systemName: "forward.end")
                }.help("Next event").accessibilityLabel("Next event")
                Slider(value: Binding(get: { model.replayProgress }, set: model.seek), in: 0...1).tint(
                    FalconTheme.accent
                ).accessibilityLabel("Historical playback position")
                Text(model.playbackDate.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit().frame(width: 126)
                Picker("Playback speed", selection: $model.playbackSpeed) {
                    ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { speed in Text("\(speed.formatted())×").tag(speed) }
                }.labelsHidden().frame(width: 65)
                Menu {
                    Toggle("Skip verified idle gaps", isOn: $model.skipIdle)
                    Toggle("Follow arrivals", isOn: $model.followArrivals)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }.menuStyle(.borderlessButton).fixedSize()
                Button("Show final result") { model.stopReplay() }
            }.buttonStyle(FalconButtonStyle(compact: true))
            if model.skippedSeconds > 0 {
                Text(
                    "Skipped \(model.skippedSeconds.formatted(.number.precision(.fractionLength(1)))) s of verified idle time"
                ).font(.system(size: 11)).foregroundStyle(FalconTheme.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 13).background(FalconTheme.surface).overlay(alignment: .top) {
            Rectangle().fill(FalconTheme.line).frame(height: 0.75)
        }
    }
}

struct SourceTimelineView: View {
    @Bindable var model: WorkspaceModel
    private var records: [RequestSummary] { model.timeline?.records ?? model.requests }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(title: model.timeline == nil ? "Loaded activity by source" : "Replay range by source")
                Spacer()
                Text("Overlapping requests stay concurrent").font(.system(size: 11)).foregroundStyle(
                    FalconTheme.secondary)
            }
            Chart {
                ForEach(records) { record in
                    RuleMark(
                        xStart: .value("Received", record.receivedAt),
                        xEnd: .value(
                            "Last known event", record.receivedAt.addingTimeInterval(record.timing.lastKnownMS / 1000)),
                        y: .value("Source", sourceLabel(record))
                    ).lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round)).foregroundStyle(
                        record.status.isFailure
                            ? FalconTheme.warning : FalconTheme.accent.opacity(record.id == model.selectedID ? 1 : 0.5))
                    if record.timing.terminalMS == nil {
                        PointMark(
                            x: .value(
                                "Unknown end", record.receivedAt.addingTimeInterval(record.timing.lastKnownMS / 1000)),
                            y: .value("Source", sourceLabel(record))
                        ).symbol(.diamond).foregroundStyle(FalconTheme.warning).annotation {
                            Text("?").font(.system(size: 11))
                        }
                    }
                }
                if model.timeline != nil {
                    RuleMark(x: .value("Playback", model.playbackDate)).foregroundStyle(FalconTheme.ink).lineStyle(
                        StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }.chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                    AxisGridLine()
                }
            }.chartYAxis { AxisMarks { _ in AxisValueLabel() } }.chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { point in
                        guard let frame = proxy.plotFrame,
                            let date: Date = proxy.value(atX: point.x - geometry[frame].minX),
                            let source: String = proxy.value(atY: point.y - geometry[frame].minY)
                        else { return }
                        if let closest = records.filter({ sourceLabel($0) == source }).min(by: {
                            abs($0.receivedAt.timeIntervalSince(date)) < abs($1.receivedAt.timeIntervalSince(date))
                        }) {
                            Task { await model.select(closest.id) }
                        }
                    }
                }
            }.accessibilityLabel(
                "Decision activity by source. Select a decision from the activity list for full details.")
        }
    }

    private func sourceLabel(_ record: RequestSummary) -> String {
        "\(record.sourceName) · \(record.sourceID.uuidString.prefix(6).lowercased())"
    }
}
