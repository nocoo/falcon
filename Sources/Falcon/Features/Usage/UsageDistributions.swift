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
        Surface(inset: FalconTheme.Space.section) {
            VStack(alignment: .leading, spacing: FalconTheme.Space.medium) {
                Text(title).font(FalconTheme.sectionTitle)
                Text(subtitle).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
                Chart(buckets) { bucket in
                    BarMark(x: .value("Probability band", bucket.index), y: .value("Questions", bucket.count))
                        .foregroundStyle(FalconTheme.Candy.blue.gradient).cornerRadius(3).accessibilityLabel(
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
                }.font(FalconTheme.footnote).foregroundStyle(FalconTheme.secondary)
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
        Surface(inset: FalconTheme.Space.section) {
            VStack(alignment: .leading, spacing: FalconTheme.Space.large) {
                Text("Decisions by definition").font(FalconTheme.sectionTitle)
                Text(
                    "Only identical question types and definitions share a group. Names alone never combine decisions."
                ).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
                if groups.isEmpty {
                    Text("Completed decisions will appear here.").foregroundStyle(FalconTheme.tertiary)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
                        HStack(spacing: FalconTheme.Space.regular) {
                            Text(group.questionID).font(FalconTheme.mono).lineLimit(1)
                            Pill(text: group.type.capitalized)
                            Text(String(group.fingerprint.prefix(8))).font(FalconTheme.monoSmall).foregroundStyle(
                                FalconTheme.tertiary)
                            Spacer()
                            Text("\(group.samples) questions").font(FalconTheme.detail).foregroundStyle(
                                FalconTheme.secondary)
                            Button {
                                inspect(group)
                            } label: {
                                Label("Inspect", systemImage: "arrow.up.right")
                            }.buttonStyle(FalconButtonStyle(compact: true))
                        }
                        if group.type == "choice" {
                            ForEach(group.outcomes) { outcome in
                                HStack(spacing: FalconTheme.Space.medium) {
                                    Text(outcome.name).font(FalconTheme.mono).frame(width: 150, alignment: .leading)
                                        .lineLimit(1)
                                    ProgressView(value: Double(outcome.count), total: Double(max(1, group.samples)))
                                        .tint(FalconTheme.accent)
                                    Text("\(outcome.count)").font(FalconTheme.mono).frame(
                                        width: 50, alignment: .trailing)
                                }
                            }
                        } else {
                            HStack(spacing: FalconTheme.Space.sheet) {
                                value("Mean", group.mean, probability: group.type == "noul")
                                value("Minimum", group.minimum, probability: group.type == "noul")
                                value("Maximum", group.maximum, probability: group.type == "noul")
                            }
                        }
                    }.padding(.vertical, FalconTheme.Space.regular)
                    if group.id != groups.last?.id { Divider() }
                }
                if omitted > 0 {
                    Text("\(omitted) more definitions. Narrow the time or source range to inspect them.").font(
                        FalconTheme.detail
                    ).foregroundStyle(FalconTheme.secondary)
                }
            }
        }
    }

    private func value(_ title: String, _ number: Double?, probability: Bool) -> some View {
        HStack(spacing: FalconTheme.Space.compact) {
            Text(title).foregroundStyle(FalconTheme.secondary)
            Text(
                probability
                    ? DecisionFormat.probability(number)
                    : number?.formatted(.number.precision(.fractionLength(2))) ?? "—"
            ).font(FalconTheme.mono)
        }.font(FalconTheme.detail)
    }
}
