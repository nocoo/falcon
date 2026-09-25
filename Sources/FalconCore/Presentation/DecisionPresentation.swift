import Foundation

public struct DecisionOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let definition: JSONValue
    public let probability: Double?
    public let selected: Bool
}

public struct DecisionQuestion: Identifiable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let instructions: JSONValue
    public let options: [DecisionOption]
    public let result: String?
    public let confidence: Double?
    public let yesProbability: Double?
    public let score: Double?
    public var margin: Double? {
        let values = options.compactMap(\.probability).sorted(by: >)
        guard values.count >= 2 else { return nil }
        return values[0] - values[1]
    }
}

public struct DecisionPresentation: Sendable {
    public let state: JSONValue?
    public let define: JSONValue?
    public let questions: [DecisionQuestion]
    public let received: JSONValue?
    public let effective: JSONValue?
    public let response: JSONValue?

    public init(detail: RequestDetail) {
        received = detail.receivedRequest.flatMap { try? JSONValue.decode($0) }
        effective = detail.effectiveRequest.flatMap { try? JSONValue.decode($0) }
        response = detail.upstreamResponse.flatMap { try? JSONValue.decode($0) }
        let input = effective ?? (detail.summary.transport == .mcp ? received?["params"]?["arguments"] : received)
        state = input?["state"]
        define = input?["define"]
        let answers = detail.summary.status == .succeeded ? response?["answers"] : nil
        questions = (input?["questions"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { id, question in
            let answer = answers?[id]
            let type = question["type"]?.stringValue ?? "unknown"
            let choice = type == "choice" ? answer?["choice"]?.stringValue : nil
            let probabilities = answer?["probabilities"]?.objectValue ?? [:]
            let criteria = question["criteria"]
            let options: [DecisionOption]
            if type == "score", let levels = criteria?.arrayValue {
                options = levels.enumerated().map { index, definition in
                    DecisionOption(
                        id: String(index), definition: definition,
                        probability: probabilities[String(index)]?.numberValue, selected: false)
                }
            } else {
                options = (criteria?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { key, definition in
                    DecisionOption(
                        id: key, definition: definition, probability: probabilities[key]?.numberValue,
                        selected: key == choice)
                }
            }
            return DecisionQuestion(
                id: id, type: type, instructions: question["instructions"] ?? .null, options: options, result: choice,
                confidence: type == "choice" || type == "score" ? answer?["confidence"]?.numberValue : nil,
                yesProbability: type == "noul" ? answer?["noul"]?.numberValue : nil,
                score: type == "score" ? answer?["score"]?.numberValue : nil)
        }
    }
}

public enum DecisionFormat {
    public static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite else { return "—" }
        return milliseconds < 1000
            ? String(format: "%.0f ms", milliseconds) : String(format: "%.2f s", milliseconds / 1000)
    }
    public static func probability(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }
    public static func tokens(_ value: Int?) -> String { value.map { $0.formatted() } ?? "—" }

    public static func csv(_ records: [RequestSummary]) -> String {
        func cell(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let formula = ["=", "+", "-", "@"].contains { trimmed.hasPrefix($0) }
            let safe = formula || ["\t", "\r", "\n"].contains { value.hasPrefix($0) } ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header =
            "request_id,received_at,source,transport,status,model,questions,"
            + "processing_ms,return_ms,input_tokens,output_tokens,review"
        var lines = [header]
        lines += records.map { record in
            [
                record.id.uuidString, record.receivedAt.ISO8601Format(), record.sourceName, record.transport.rawValue,
                record.status.rawValue, record.resolvedModel ?? record.requestedModel, String(record.questionCount),
                record.timing.terminalMS.map(String.init(describing:)) ?? "",
                record.timing.deliveryFinishedMS.map(String.init(describing:)) ?? "",
                record.inputTokens.map(String.init) ?? "", record.outputTokens.map(String.init) ?? "",
                record.reviewState.rawValue,
            ].map(cell).joined(separator: ",")
        }
        return lines.joined(separator: "\r\n")
    }
}
