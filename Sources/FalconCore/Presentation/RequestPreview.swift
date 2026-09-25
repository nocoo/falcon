import Foundation

public struct RequestPreview: Sendable {
    public let status: RequestStatus
    public let expiresAt: Date
    public let context: String
    public let questionID: String?
    public let decision: String?

    init(status: RequestStatus, expiresAt: Date, context: String?, question: JSONValue?) {
        self.status = status
        self.expiresAt = expiresAt
        self.context = Self.compact(context ?? "", limit: 240)
        questionID = question?["id"]?.stringValue.map { Self.compact($0, limit: 80) }
        switch question?["type"]?.stringValue {
        case "choice": decision = question?["choice"]?.stringValue.map { Self.compact($0, limit: 160) }
        case "score":
            decision = question?["numeric"]?.numberValue.map {
                "Score \($0.formatted(.number.precision(.fractionLength(0...2))))"
            }
        case "noul": decision = question?["numeric"]?.numberValue.map { "Yes \(DecisionFormat.probability($0))" }
        default: decision = nil
        }
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
