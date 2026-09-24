import Foundation

public struct JevRequest: Sendable {
    public let value: JSONValue
    public let questions: [String: JSONValue]
    public let model: String

    public init(_ value: JSONValue, defaultModel: String? = nil) throws {
        guard var root = value.objectValue,
              let state = root["state"], Self.isStructured(state),
              let questions = root["questions"]?.objectValue, !questions.isEmpty else {
            throw FalconError("invalid_request", "Invalid Jev request", status: 422)
        }
        let model = root["model"]?.stringValue ?? defaultModel
        guard let model, !model.isEmpty,
              root["model"] == nil || root["model"]?.stringValue != nil else {
            throw FalconError("invalid_model", "Invalid Jev model", status: 422)
        }
        for (id, question) in questions {
            guard !id.isEmpty,
                  let fields = question.objectValue,
                  let type = fields["type"]?.stringValue,
                  let instructions = fields["instructions"], Self.isStructured(instructions) else {
                throw FalconError("invalid_question", "Invalid Jev question", status: 422)
            }
            switch type {
            case "choice":
                guard let criteria = fields["criteria"]?.objectValue,
                      (2...255).contains(criteria.count),
                      criteria.keys.allSatisfy({ !$0.isEmpty }),
                      criteria.values.allSatisfy(Self.isDescription) else {
                    throw FalconError("invalid_choice", "Invalid Choice criteria", status: 422)
                }
            case "noul":
                if let criteria = fields["criteria"] {
                    guard let values = criteria.objectValue,
                          Set(values.keys) == ["true", "false"],
                          values.values.allSatisfy(Self.isDescription) else {
                        throw FalconError("invalid_noul", "Invalid Noul criteria", status: 422)
                    }
                }
            case "score":
                guard let criteria = fields["criteria"]?.arrayValue,
                      (2...10).contains(criteria.count),
                      criteria.allSatisfy(Self.isDescription) else {
                    throw FalconError("invalid_score", "Invalid Score criteria", status: 422)
                }
            default:
                throw FalconError("unsupported_question", "Unsupported Jev question type", status: 422)
            }
        }
        root["model"] = .string(model)
        self.value = .object(root)
        self.questions = questions
        self.model = model
    }

    private static func isStructured(_ value: JSONValue) -> Bool {
        switch value { case .string, .object, .array: true; default: false }
    }

    private static func isDescription(_ value: JSONValue) -> Bool {
        switch value { case .string, .object, .array, .null: true; default: false }
    }
}

public struct JevResponse: Sendable {
    public let value: JSONValue
    public let resolvedModel: String
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(_ value: JSONValue, request: JevRequest) throws {
        guard let root = value.objectValue,
              let model = root["model"]?.stringValue, !model.isEmpty,
              let answers = root["answers"]?.objectValue,
              Set(answers.keys) == Set(request.questions.keys) else { throw Self.invalid() }
        for (id, question) in request.questions {
            guard let fields = answers[id]?.objectValue,
                  let type = fields["type"]?.stringValue,
                  type == question["type"]?.stringValue else { throw Self.invalid() }
            switch type {
            case "choice":
                guard let criteria = question["criteria"]?.objectValue,
                      let winner = fields["choice"]?.stringValue,
                      criteria[winner] != nil,
                      let probabilities = fields["probabilities"]?.objectValue,
                      Self.validProbabilities(probabilities, keys: Set(criteria.keys)),
                      Self.probability(fields["confidence"]) != nil else { throw Self.invalid() }
            case "noul":
                guard Self.probability(fields["noul"]) != nil else { throw Self.invalid() }
            case "score":
                guard let criteria = question["criteria"]?.arrayValue,
                      let legend = fields["legend"]?.objectValue,
                      let probabilities = fields["probabilities"]?.objectValue,
                      Set(legend.keys) == Set((0..<criteria.count).map(String.init)),
                      criteria.enumerated().allSatisfy({ legend[String($0.offset)] == $0.element }),
                      Self.validProbabilities(probabilities, keys: Set(legend.keys)),
                      let score = fields["score"]?.numberValue,
                      score.isFinite, score >= 0, score <= Double(criteria.count - 1),
                      Self.probability(fields["confidence"]) != nil else { throw Self.invalid() }
            default: throw Self.invalid()
            }
        }
        self.value = value
        self.resolvedModel = model
        if let usage = root["usage"]?.objectValue {
            self.inputTokens = Self.tokenCount(usage["input_tokens"])
            self.outputTokens = Self.tokenCount(usage["output_tokens"])
        } else {
            self.inputTokens = nil
            self.outputTokens = nil
        }
    }

    private static func probability(_ value: JSONValue?) -> Double? {
        guard let number = value?.numberValue, number.isFinite, (0...1).contains(number) else { return nil }
        return number
    }

    private static func validProbabilities(_ values: [String: JSONValue], keys: Set<String>) -> Bool {
        guard Set(values.keys) == keys else { return false }
        let probabilities = values.values.compactMap(probability)
        return probabilities.count == values.count && abs(probabilities.reduce(0, +) - 1) <= 0.02
    }

    private static func tokenCount(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isFinite, number >= 0,
              number.rounded() == number, number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func invalid() -> FalconError {
        FalconError("invalid_response", "Invalid Jev response", status: 502, outcomeUnknown: true)
    }
}
