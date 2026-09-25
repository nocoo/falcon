import FalconCore
import SwiftUI

struct RequestRow: View {
    let record: RequestSummary
    let preview: RequestPreview?
    let selected: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.micro) {
            HStack(spacing: FalconTheme.Space.tight) {
                statusMark
                Text(record.sourceName).font(FalconTheme.label.weight(.semibold)).lineLimit(1)
                Spacer(minLength: FalconTheme.Space.tight)
                if record.reviewState == .flagged {
                    Image(systemName: "flag.fill").font(FalconTheme.caption).foregroundStyle(FalconTheme.warning)
                        .accessibilityLabel("Needs attention")
                }
                Text(record.receivedAt, format: .dateTime.hour().minute().second()).font(FalconTheme.monoSmall)
                    .foregroundStyle(FalconTheme.secondary).help(
                        record.receivedAt.formatted(.dateTime.year().month().day().hour().minute().second()))
            }
            Text(context).font(FalconTheme.detail).lineLimit(1).help(context).frame(
                maxWidth: .infinity, alignment: .leading)
            HStack(spacing: FalconTheme.Space.small) {
                if record.status == .succeeded, let question = preview?.questionID, let decision = preview?.decision {
                    (Text(question).foregroundColor(FalconTheme.secondary)
                        + Text(" → ").foregroundColor(FalconTheme.tertiary)
                        + Text(decision).foregroundColor(FalconTheme.accent)).lineLimit(1).help(
                            "\(question) → \(decision)")
                    if record.questionCount > 1 {
                        Text("+\(record.questionCount - 1)").foregroundStyle(FalconTheme.secondary).monospacedDigit()
                            .accessibilityLabel("\(record.questionCount) questions in this request")
                    }
                } else {
                    Text(record.status.title).foregroundStyle(
                        record.status.isFailure ? FalconTheme.warning : FalconTheme.secondary)
                }
                Spacer(minLength: FalconTheme.Space.tight)
                Text(DecisionFormat.duration(latency)).monospacedDigit().foregroundStyle(FalconTheme.secondary)
                    .fixedSize().help(
                        record.delivery == .written
                            ? "Time until the response was returned" : "Processing time; return time is unknown")
            }.font(FalconTheme.footnote)
        }.padding(.horizontal, FalconTheme.Space.compact).padding(.vertical, FalconTheme.Space.compact).frame(
            minHeight: FalconTheme.Layout.requestRowHeight
        ).background(
            selected ? FalconTheme.accentWash : hovered ? FalconTheme.inset : .clear,
            in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
        ).contentShape(Rectangle()).onHover { hovered = $0 }.animation(
            reduceMotion ? nil : FalconTheme.feedback, value: hovered
        ).accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var statusMark: some View {
        Group {
            if !record.status.isTerminal {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: record.status.isFailure ? "exclamationmark.circle" : "checkmark.circle").font(
                    FalconTheme.caption
                ).foregroundStyle(record.status.isFailure ? FalconTheme.warning : FalconTheme.success)
            }
        }.frame(width: FalconTheme.Layout.requestStatusMark, height: FalconTheme.Layout.requestStatusMark)
            .accessibilityLabel(record.status.title).help(record.status.title)
    }

    private var context: String {
        if let context = preview?.context, !context.isEmpty { return context }
        return record.errorMessage ?? "\(record.questionCount) \(record.questionCount == 1 ? "question" : "questions")"
    }

    private var latency: Double? {
        record.delivery == .written ? record.timing.deliveryFinishedMS : record.timing.terminalMS
    }
}
