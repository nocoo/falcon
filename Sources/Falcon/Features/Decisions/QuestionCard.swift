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
        Surface {
            VStack(alignment: .leading, spacing: FalconTheme.Space.medium) {
                HStack(spacing: FalconTheme.Space.compact) {
                    Text(question.id).font(FalconTheme.monoTitle).textSelection(.enabled)
                    Spacer(minLength: FalconTheme.Space.small)
                    Pill(text: question.type.capitalized, color: FalconTheme.secondary)
                }
                Text(question.instructions.displayText).font(FalconTheme.body).lineSpacing(FalconTheme.Space.small)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if question.type == "noul" {
                    noulResult
                } else {
                    if question.type == "score", let score = question.score, showResult {
                        HStack(alignment: .firstTextBaseline, spacing: FalconTheme.Space.compact) {
                            Text(score.formatted(.number.precision(.fractionLength(2)))).font(FalconTheme.resultValue)
                            Text("weighted level · 0–\(max(0, question.options.count - 1))").font(FalconTheme.footnote)
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
                    }.padding(.top, FalconTheme.Space.small)
                    LazyVStack(spacing: FalconTheme.Space.compact) {
                        ForEach(showAll ? options : Array(options.prefix(8))) { option in
                            OptionRow(option: option, showResult: showResult)
                        }
                    }
                    if question.options.count > 8 {
                        Button(showAll ? "Show first 8" : "Show all \(question.options.count) options") {
                            showAll.toggle()
                        }.buttonStyle(.plain).foregroundStyle(FalconTheme.accent).font(FalconTheme.detail)
                    }
                }
                if showResult, let confidence = question.confidence {
                    HStack(spacing: FalconTheme.Space.large) {
                        Label("Confidence \(DecisionFormat.probability(confidence))", systemImage: "scope").help(
                            "Distribution concentration, not accuracy.")
                        if question.type == "choice", let margin = question.margin {
                            Text("Margin \(DecisionFormat.probability(margin))")
                        }
                        Spacer(minLength: 0)
                    }.font(FalconTheme.footnote).foregroundStyle(FalconTheme.secondary).padding(
                        .top, FalconTheme.Space.micro)
                }
            }
        }.animation(reduceMotion ? nil : FalconTheme.feedback, value: showResult)
    }

    private var noulResult: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
            HStack(alignment: .firstTextBaseline, spacing: FalconTheme.Space.compact) {
                Text(showResult ? DecisionFormat.probability(question.yesProbability) : "—").font(
                    FalconTheme.resultValue
                ).foregroundStyle(FalconTheme.accent)
                Text("Yes probability").font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
            }
            ForEach(question.options) { option in
                HStack(alignment: .top, spacing: FalconTheme.Space.regular) {
                    Text(option.id).font(FalconTheme.monoValue).frame(width: 48, alignment: .leading)
                    Text(option.definition.displayText).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
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
        VStack(alignment: .leading, spacing: FalconTheme.Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: FalconTheme.Space.compact) {
                Text(option.id).font(FalconTheme.mono.weight(selected ? .semibold : .medium)).textSelection(.enabled)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(FalconTheme.detail).foregroundStyle(
                        FalconTheme.accent)
                }
                Spacer()
                Text(showResult ? DecisionFormat.probability(option.probability) : "—").font(FalconTheme.monoValue)
                    .foregroundStyle(selected ? FalconTheme.accent : FalconTheme.secondary)
            }
            if option.definition != .null {
                Text(option.definition.displayText).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
                    .lineSpacing(FalconTheme.Space.small).lineLimit(expanded ? nil : 3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if option.definition.displayText.count > 220 {
                    Button(expanded ? "Less" : "Full definition") { expanded.toggle() }.font(FalconTheme.footnote)
                        .buttonStyle(.plain).foregroundStyle(FalconTheme.accent)
                }
            }
            if showResult, let probability = option.probability {
                GeometryReader { geometry in
                    Capsule().fill(FalconTheme.line)
                    Capsule().fill(selected ? FalconTheme.accent : FalconTheme.tertiary).frame(
                        width: geometry.size.width * max(0, min(1, probability)))
                }.frame(height: 3).padding(.top, FalconTheme.Space.small).accessibilityHidden(true)
            }
        }.padding(.horizontal, FalconTheme.Space.regular).padding(.vertical, FalconTheme.Space.regular).background(
            selected ? FalconTheme.accentWash : FalconTheme.inset,
            in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
        ).overlay(
            RoundedRectangle(cornerRadius: FalconTheme.Radius.control).strokeBorder(
                selected ? FalconTheme.accent.opacity(0.22) : .clear, lineWidth: FalconTheme.hairline))
    }
}
