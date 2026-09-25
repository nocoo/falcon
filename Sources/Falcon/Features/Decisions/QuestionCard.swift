import FalconCore
import SwiftUI

struct QuestionCard: View {
    let question: DecisionQuestion
    let showResult: Bool
    @State private var showAll = false
    @State private var sortByProbability = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var options: [DecisionOption] {
        guard question.type == "choice", sortByProbability, showResult else { return question.options }
        return question.options.sorted {
            ($0.probability ?? -1) == ($1.probability ?? -1)
                ? $0.id < $1.id : ($0.probability ?? -1) > ($1.probability ?? -1)
        }
    }

    var body: some View {
        Surface(inset: 18) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 8) {
                    Text(question.id).font(.system(size: 13, weight: .semibold, design: .monospaced)).textSelection(
                        .enabled)
                    Spacer(minLength: 4)
                    Pill(text: question.type.capitalized, color: FalconTheme.secondary)
                }
                Text(question.instructions.displayText).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if question.type == "noul" {
                    noulResult
                } else {
                    if question.type == "score", let score = question.score, showResult {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(score.formatted(.number.precision(.fractionLength(2)))).font(
                                .system(size: 24, weight: .medium, design: .rounded))
                            Text("weighted level · 0–\(max(0, question.options.count - 1))").font(.system(size: 11))
                                .foregroundStyle(FalconTheme.secondary)
                        }.foregroundStyle(FalconTheme.accent)
                    }
                    HStack {
                        Eyebrow(title: "Option · definition")
                        Spacer()
                        if question.type == "choice", showResult {
                            Menu {
                                Toggle("Sort by probability", isOn: $sortByProbability)
                            } label: {
                                Eyebrow(title: "Probability")
                            }.menuStyle(.borderlessButton).fixedSize()
                        } else {
                            Eyebrow(title: "Probability")
                        }
                    }.padding(.top, 4)
                    LazyVStack(spacing: 7) {
                        ForEach(showAll ? options : Array(options.prefix(8))) { option in
                            OptionRow(option: option, showResult: showResult)
                        }
                    }
                    if question.options.count > 8 {
                        Button(showAll ? "Show first 8" : "Show all \(question.options.count) options") {
                            showAll.toggle()
                        }.buttonStyle(.plain).foregroundStyle(FalconTheme.accent).font(.system(size: 12))
                    }
                }
                if showResult, let confidence = question.confidence {
                    HStack(spacing: 18) {
                        Label("Confidence \(DecisionFormat.probability(confidence))", systemImage: "scope").help(
                            "Distribution concentration, not accuracy.")
                        if question.type == "choice", let margin = question.margin {
                            Text("Margin \(DecisionFormat.probability(margin))")
                        }
                        Spacer(minLength: 0)
                    }.font(.system(size: 11)).foregroundStyle(FalconTheme.secondary).padding(.top, 1)
                }
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showResult)
    }

    private var noulResult: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(showResult ? DecisionFormat.probability(question.yesProbability) : "—").font(
                    .system(size: 25, weight: .medium, design: .rounded)
                ).foregroundStyle(FalconTheme.accent)
                Text("Yes probability").font(.system(size: 12)).foregroundStyle(FalconTheme.secondary)
            }
            ForEach(question.options) { option in
                HStack(alignment: .top, spacing: 10) {
                    Text(option.id).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(
                        width: 48, alignment: .leading)
                    Text(option.definition.displayText).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct OptionRow: View {
    let option: DecisionOption
    let showResult: Bool
    @State private var expanded = false
    private var selected: Bool { showResult && option.selected }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.id).font(.system(size: 12, weight: selected ? .semibold : .medium, design: .monospaced))
                    .textSelection(.enabled)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(
                        FalconTheme.accent)
                }
                Spacer()
                Text(showResult ? DecisionFormat.probability(option.probability) : "—").font(
                    .system(size: 12, weight: .medium, design: .monospaced)
                ).foregroundStyle(selected ? FalconTheme.accent : FalconTheme.secondary)
            }
            if option.definition != .null {
                Text(option.definition.displayText).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary)
                    .lineSpacing(3).lineLimit(expanded ? nil : 3).textSelection(.enabled).fixedSize(
                        horizontal: false, vertical: true)
                if option.definition.displayText.count > 220 {
                    Button(expanded ? "Less" : "Full definition") { expanded.toggle() }.font(.system(size: 11))
                        .buttonStyle(.plain).foregroundStyle(FalconTheme.accent)
                }
            }
            if showResult, let probability = option.probability {
                GeometryReader { geometry in
                    Capsule().fill(FalconTheme.line.opacity(0.65))
                    Capsule().fill(selected ? FalconTheme.accent : FalconTheme.tertiary.opacity(0.5)).frame(
                        width: geometry.size.width * max(0, min(1, probability)))
                }.frame(height: 3).padding(.top, 3).accessibilityHidden(true)
            }
        }.padding(.horizontal, 11).padding(.vertical, 10).background(
            selected ? FalconTheme.accentWash.opacity(0.72) : FalconTheme.inset.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 7)
        ).overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(
                selected ? FalconTheme.accent.opacity(0.22) : .clear, lineWidth: 0.75))
    }
}
