import Charts
import FalconCore
import SwiftUI

struct ProbabilityDistribution: View {
    let title: String
    let subtitle: String
    let buckets: [ProbabilityBucket]
    let missing: Int
    let inspect: (Int) -> Void
    @State private var selectedBand: Int?

    var body: some View {
        Surface(inset: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary)
                Chart(buckets) { bucket in
                    BarMark(x: .value("Probability band", bucket.index), y: .value("Questions", bucket.count))
                        .foregroundStyle(FalconTheme.accent.gradient).cornerRadius(3).accessibilityLabel(
                            "\(Int(bucket.lowerBound * 100)) to \(Int(bucket.upperBound * 100)) percent"
                        ).accessibilityValue("\(bucket.count) questions")
                }.chartXScale(domain: -1...10).chartXSelection(value: $selectedBand).chartXAxis {
                    AxisMarks(values: [0, 2, 4, 6, 8, 9]) { value in
                        AxisValueLabel { if let index = value.as(Int.self) { Text("\(index * 10)%") } }
                    }
                }.frame(height: 145)
                HStack {
                    Text("\(buckets.reduce(0) { $0 + $1.count }) questions · \(missing) unknown")
                    Spacer()
                    Menu("Inspect range") {
                        ForEach(buckets) { bucket in
                            Button(
                                "\(Int(bucket.lowerBound * 100))–\(Int(bucket.upperBound * 100))% · \(bucket.count) questions"
                            ) { inspect(bucket.index) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }.font(.system(size: 11)).foregroundStyle(FalconTheme.secondary)
            }
        }.onChange(of: selectedBand) { _, index in
            if let index, (0...9).contains(index) {
                inspect(index)
                selectedBand = nil
            }
        }
    }
}

struct DecisionGroupsView: View {
    let groups: [DecisionGroup]
    let omitted: Int
    let inspect: (DecisionGroup) -> Void

    var body: some View {
        Surface(inset: 24) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Decisions by definition").font(.system(size: 15, weight: .semibold))
                Text(
                    "Only identical question types and definitions share a group. Names alone never combine decisions."
                ).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary)
                if groups.isEmpty {
                    Text("Completed decisions will appear here.").foregroundStyle(FalconTheme.tertiary)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Text(group.questionID).font(FalconTheme.mono).lineLimit(1)
                            Pill(text: group.type.capitalized)
                            Text(String(group.fingerprint.prefix(8))).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(FalconTheme.tertiary)
                            Spacer()
                            Text("\(group.samples) questions").font(.system(size: 12)).foregroundStyle(
                                FalconTheme.secondary)
                            Button {
                                inspect(group)
                            } label: {
                                Label("Inspect", systemImage: "arrow.up.right")
                            }.buttonStyle(FalconButtonStyle(compact: true))
                        }
                        if group.type == "choice" {
                            ForEach(group.outcomes) { outcome in
                                HStack(spacing: 14) {
                                    Text(outcome.name).font(.system(size: 12, design: .monospaced)).frame(
                                        width: 150, alignment: .leading
                                    ).lineLimit(1)
                                    ProgressView(value: Double(outcome.count), total: Double(max(1, group.samples)))
                                        .tint(FalconTheme.accent)
                                    Text("\(outcome.count)").font(FalconTheme.mono).frame(
                                        width: 50, alignment: .trailing)
                                }
                            }
                        } else {
                            HStack(spacing: 28) {
                                value("Mean", group.mean, probability: group.type == "noul")
                                value("Minimum", group.minimum, probability: group.type == "noul")
                                value("Maximum", group.maximum, probability: group.type == "noul")
                            }
                        }
                    }.padding(.vertical, 10)
                    if group.id != groups.last?.id { Divider() }
                }
                if omitted > 0 {
                    Text("\(omitted) more definitions. Narrow the time or source range to inspect them.").font(
                        .system(size: 12)
                    ).foregroundStyle(FalconTheme.secondary)
                }
            }
        }
    }

    private func value(_ title: String, _ number: Double?, probability: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(FalconTheme.secondary)
            Text(
                probability
                    ? DecisionFormat.probability(number)
                    : number?.formatted(.number.precision(.fractionLength(2))) ?? "—"
            ).font(FalconTheme.mono)
        }.font(.system(size: 12))
    }
}
