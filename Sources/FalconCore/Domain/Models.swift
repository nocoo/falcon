import Foundation

public enum FalconLimits {
    public static let retention: TimeInterval = 604_800
    public static let requestBytes = 1_048_576
    public static let responseBytes = 4_194_304
    public static let storageBytes: Int64 = 2_147_483_648
    public static let port = 19_823
    public static let timeout: TimeInterval = 30
}

public struct FalconError: Error, LocalizedError, Sendable, Equatable {
    public var code: String
    public var message: String
    public var status: Int
    public var outcomeUnknown: Bool
    public init(_ code: String, _ message: String, status: Int = 500, outcomeUnknown: Bool = false) {
        self.code = code
        self.message = message
        self.status = status
        self.outcomeUnknown = outcomeUnknown
    }
    public var errorDescription: String? { message }
}

public struct UpstreamProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var defaultModel: String
    public var revision: Int
    public var credentialID: String
    public var enabled: Bool
    public init(
        id: UUID = UUID(), name: String, baseURL: String = "https://api.typesafe.ai",
        defaultModel: String = "jev-latest", revision: Int = 1, credentialID: String = "", enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.revision = revision
        self.credentialID = credentialID
        self.enabled = enabled
    }
}

public struct AgentSource: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var profileID: UUID
    public var enabled: Bool
    public var archived: Bool
    public var createdAt: Date
    public init(
        id: UUID = UUID(), name: String, profileID: UUID, enabled: Bool = true, archived: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.enabled = enabled
        self.archived = archived
        self.createdAt = createdAt
    }
}

public struct SourceKey: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sourceID: UUID
    public var digest: Data
    public var suffix: String
    public var createdAt: Date
    public var revokedAt: Date?
    public init(
        id: UUID = UUID(), sourceID: UUID, digest: Data, suffix: String, createdAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.digest = digest
        self.suffix = suffix
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }
}

public struct SourceIdentity: Sendable {
    public let source: AgentSource
    public let keyID: UUID
    public init(source: AgentSource, keyID: UUID) {
        self.source = source
        self.keyID = keyID
    }
}

public struct ExecutionSnapshot: Sendable {
    public let identity: SourceIdentity
    public let profile: UpstreamProfile
    public let endpoint: URL
    public let credential: String
    public init(identity: SourceIdentity, profile: UpstreamProfile, endpoint: URL, credential: String) {
        self.identity = identity
        self.profile = profile
        self.endpoint = endpoint
        self.credential = credential
    }
}

public enum RequestStatus: String, Codable, CaseIterable, Sendable {
    case accepted
    case inFlight = "in_flight"
    case succeeded, rejected
    case upstreamError = "upstream_error"
    case transportError = "transport_error"
    case timedOut = "timed_out"
    case cancelled, interrupted
    case invalidResponse = "invalid_response"
    public var isTerminal: Bool { self != .accepted && self != .inFlight }
    public var isFailure: Bool { isTerminal && self != .succeeded }
    public var title: String {
        switch self {
        case .accepted: "Accepted"
        case .inFlight: "In progress"
        case .succeeded: "Completed"
        case .rejected: "Rejected"
        case .upstreamError: "Upstream error"
        case .transportError: "Network error"
        case .timedOut: "Timed out"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        case .invalidResponse: "Invalid response"
        }
    }
}

public enum DeliveryState: String, Codable, Sendable { case unknown, written, failed }
public enum ReviewState: String, Codable, CaseIterable, Sendable { case unreviewed, reviewed, flagged }
public enum RequestTransport: String, Codable, Sendable { case http, mcp, app }

public struct RequestTiming: Codable, Sendable, Equatable {
    public var bodyReceivedMS: Double?
    public var upstreamStartedMS: Double?
    public var responseReceivedMS: Double?
    public var terminalMS: Double?
    public var deliveryFinishedMS: Double?
    public init(
        bodyReceivedMS: Double? = nil, upstreamStartedMS: Double? = nil, responseReceivedMS: Double? = nil,
        terminalMS: Double? = nil, deliveryFinishedMS: Double? = nil
    ) {
        self.bodyReceivedMS = bodyReceivedMS
        self.upstreamStartedMS = upstreamStartedMS
        self.responseReceivedMS = responseReceivedMS
        self.terminalMS = terminalMS
        self.deliveryFinishedMS = deliveryFinishedMS
    }
    public var upstreamMS: Double? {
        guard let start = upstreamStartedMS, let end = responseReceivedMS else { return nil }
        return max(0, end - start)
    }
    public var lastKnownMS: Double {
        [bodyReceivedMS, upstreamStartedMS, responseReceivedMS, terminalMS, deliveryFinishedMS].compactMap { $0 }.max()
            ?? 0
    }
}

public struct RequestSummary: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var sourceID: UUID
    public var keyID: UUID
    public var sourceName: String
    public var profileID: UUID
    public var profileName: String
    public var profileRevision: Int
    public var baseURL: String
    public var transport: RequestTransport
    public var receivedAt: Date
    public var expiresAt: Date
    public var status: RequestStatus
    public var delivery: DeliveryState
    public var requestedModel: String
    public var resolvedModel: String?
    public var timing: RequestTiming
    public var httpStatus: Int?
    public var errorCode: String?
    public var errorMessage: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var questionCount: Int
    public var preview: String
    public var metadata: [String: String]
    public var reviewState: ReviewState
    public var reviewNote: String
    public init(
        id: UUID = UUID(), sourceID: UUID, keyID: UUID, sourceName: String, profileID: UUID, profileName: String,
        profileRevision: Int = 1, baseURL: String = "https://api.typesafe.ai", transport: RequestTransport = .http,
        receivedAt: Date = Date(), status: RequestStatus = .accepted, requestedModel: String = "jev-latest"
    ) {
        self.id = id
        self.sourceID = sourceID
        self.keyID = keyID
        self.sourceName = sourceName
        self.profileID = profileID
        self.profileName = profileName
        self.profileRevision = profileRevision
        self.baseURL = baseURL
        self.transport = transport
        self.receivedAt = receivedAt
        self.expiresAt = receivedAt.addingTimeInterval(FalconLimits.retention)
        self.status = status
        self.delivery = .unknown
        self.requestedModel = requestedModel
        self.timing = RequestTiming()
        self.questionCount = 0
        self.preview = ""
        self.metadata = [:]
        self.reviewState = .unreviewed
        self.reviewNote = ""
    }
}

public struct RequestDetail: Identifiable, Codable, Sendable, Equatable {
    public var summary: RequestSummary
    public var receivedRequest: Data?
    public var effectiveRequest: Data?
    public var upstreamResponse: Data?
    public var id: UUID { summary.id }
    public init(
        summary: RequestSummary, receivedRequest: Data? = nil, effectiveRequest: Data? = nil,
        upstreamResponse: Data? = nil
    ) {
        self.summary = summary
        self.receivedRequest = receivedRequest
        self.effectiveRequest = effectiveRequest
        self.upstreamResponse = upstreamResponse
    }
}

public struct DecisionFilter: Sendable, Equatable {
    public var since: Date?
    public var until: Date?
    public var sourceIDs: Set<UUID>
    public var status: RequestStatus?
    public var reviewState: ReviewState?
    public var search: String
    public var questionFingerprint: String?
    public var confidenceBand: Int?
    public var noulBand: Int?
    public init(
        since: Date? = nil, until: Date? = nil, sourceIDs: Set<UUID> = [], status: RequestStatus? = nil,
        reviewState: ReviewState? = nil, search: String = "", questionFingerprint: String? = nil,
        confidenceBand: Int? = nil, noulBand: Int? = nil
    ) {
        self.since = since
        self.until = until
        self.sourceIDs = sourceIDs
        self.status = status
        self.reviewState = reviewState
        self.search = search
        self.questionFingerprint = questionFingerprint
        self.confidenceBand = confidenceBand
        self.noulBand = noulBand
    }
}

public struct RequestCursor: Sendable, Equatable {
    public var receivedAt: Date
    public var id: UUID
    public init(receivedAt: Date, id: UUID) {
        self.receivedAt = receivedAt
        self.id = id
    }
}

public struct UsageBucket: Identifiable, Sendable {
    public var date: Date
    public var requests: Int
    public var failures: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var id: Date { date }
    public init(date: Date, requests: Int, failures: Int, inputTokens: Int = 0, outputTokens: Int = 0) {
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
    public var inputTokens: Int
    public var outputTokens: Int
    public var lastReceivedAt: Date?
    public init(
        id: UUID, name: String, requests: Int, inputTokens: Int = 0, outputTokens: Int = 0, lastReceivedAt: Date? = nil
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
    public var inputTokens = 0
    public var outputTokens = 0
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
