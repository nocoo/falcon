import Foundation

enum TokenCount {
    static func adding(_ left: Int?, _ right: Int?) -> Int? {
        guard let left, let right else { return nil }
        let sum = left.addingReportingOverflow(right)
        return sum.overflow ? nil : sum.partialValue
    }
}

public struct UsageBucket: Identifiable, Sendable {
    public var date: Date
    public var requests: Int
    public var failures: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var id: Date { date }
    public init(date: Date, requests: Int, failures: Int, inputTokens: Int? = 0, outputTokens: Int? = 0) {
        self.date = date
        self.requests = requests
        self.failures = failures
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ProbabilityBucket: Identifiable, Sendable {
    public var index: Int
    public var count: Int
    public var id: Int { index }
    public var lowerBound: Double { Double(index) / 10 }
    public var upperBound: Double { Double(index + 1) / 10 }
    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

public struct CategoryUsage: Identifiable, Sendable {
    public var name: String
    public var count: Int
    public var id: String { name }
    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct LatencyBucket: Identifiable, Sendable {
    public var label: String
    public var count: Int
    public var id: String { label }
    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }
}

public struct DecisionGroup: Identifiable, Sendable {
    public var fingerprint: String
    public var questionID: String
    public var type: String
    public var samples: Int
    public var outcomes: [CategoryUsage]
    public var mean: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var id: String { fingerprint }
    public init(
        fingerprint: String, questionID: String, type: String, samples: Int, outcomes: [CategoryUsage] = [],
        mean: Double? = nil, minimum: Double? = nil, maximum: Double? = nil
    ) {
        self.fingerprint = fingerprint
        self.questionID = questionID
        self.type = type
        self.samples = samples
        self.outcomes = outcomes
        self.mean = mean
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct SourceUsage: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var requests: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int? { TokenCount.adding(inputTokens, outputTokens) }
    public var lastReceivedAt: Date?
    public init(
        id: UUID, name: String, requests: Int, inputTokens: Int? = 0, outputTokens: Int? = 0,
        lastReceivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.lastReceivedAt = lastReceivedAt
    }
}

public struct UsageSnapshot: Sendable {
    public var requests = 0
    public var questions = 0
    public var completedQuestions = 0
    public var terminal = 0
    public var failures = 0
    public var forwardedTerminal = 0
    public var succeeded = 0
    public var inputTokens: Int? = 0
    public var outputTokens: Int? = 0
    public var totalTokens: Int? { TokenCount.adding(inputTokens, outputTokens) }
    public var unknownUsage = 0
    public var p50MS: Double?
    public var p95MS: Double?
    public var latencySamples = 0
    public var missingLatency = 0
    public var returnP50MS: Double?
    public var returnP95MS: Double?
    public var returnLatencySamples = 0
    public var missingReturnLatency = 0
    public var confidence: [ProbabilityBucket] = []
    public var missingConfidence = 0
    public var noul: [ProbabilityBucket] = []
    public var missingNoul = 0
    public var decisionGroups: [DecisionGroup] = []
    public var omittedDecisionGroups = 0
    public var processingLatencies: [LatencyBucket] = []
    public var returnLatencies: [LatencyBucket] = []
    public var models: [CategoryUsage] = []
    public var questionTypes: [CategoryUsage] = []
    public var bucketSeconds: TimeInterval = 86_400
    public var buckets: [UsageBucket] = []
    public var sources: [SourceUsage] = []
    public init() {}
}
