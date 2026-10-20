import Foundation

public struct JevHTTPResult: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String?
    public let retryAfter: String?
    public let retryAfterMS: String?
    public let requestID: String?
    public let errorOrigin: String?
    public init(
        status: Int, body: Data, contentType: String? = nil, retryAfter: String? = nil, retryAfterMS: String? = nil,
        requestID: String? = nil, errorOrigin: String? = nil
    ) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.retryAfter = retryAfter
        self.retryAfterMS = retryAfterMS
        self.requestID = requestID
        self.errorOrigin = errorOrigin == "relay" ? "relay" : nil
    }

    var relayError: FalconError? {
        guard status >= 400, errorOrigin == "relay" else { return nil }
        guard let error = try? JSONValue.decode(body)["error"], error["origin"]?.stringValue == "relay",
            let code = error["code"]?.stringValue, !code.isEmpty, code.utf8.count <= 120,
            let message = error["message"]?.stringValue, !message.isEmpty, message.utf8.count <= 512,
            let unknown = error["outcome_unknown"]?.boolValue
        else {
            return FalconError(
                "relay_invalid_error", "Relay returned an invalid error", status: status, outcomeUnknown: true)
        }
        return FalconError(code, message, status: status, outcomeUnknown: unknown)
    }
}

public struct JevClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    public init(transport: Transport? = nil) {
        self.transport = transport ?? { request in try await BoundedSessionDelegate.execute(request) }
    }

    public func send(_ body: Data, snapshot: ExecutionSnapshot) async throws -> JevHTTPResult {
        try await send(body, to: snapshot.endpoint, credential: snapshot.credential)
    }

    public func listModels(snapshot: ExecutionSnapshot) async throws -> JevHTTPResult {
        try await send(nil, to: URL(string: snapshot.profile.baseURL + "/v1/models")!, credential: snapshot.credential)
    }

    private func send(_ body: Data?, to endpoint: URL, credential: String) async throws -> JevHTTPResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = FalconLimits.timeout
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Falcon/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        guard data.count <= FalconLimits.responseBytes else {
            throw JevResponseLimitError(prefix: Data(data.prefix(4_096)))
        }
        guard !(300...399).contains(response.statusCode) else {
            throw FalconError("upstream_redirect", "Upstream redirect refused", status: 502, outcomeUnknown: true)
        }
        return JevHTTPResult(
            status: response.statusCode, body: data, contentType: response.value(forHTTPHeaderField: "Content-Type"),
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            retryAfterMS: response.value(forHTTPHeaderField: "retry-after-ms"),
            requestID: response.value(forHTTPHeaderField: "x-typesafe-request-id"),
            errorOrigin: response.value(forHTTPHeaderField: "X-Falcon-Error-Origin"))
    }
}

struct JevResponseLimitError: Error, Sendable { let prefix: Data }

private final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var count = 0
    private var oversized = false
    private var cancelled = false

    static func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = BoundedSessionDelegate()
        let session = URLSession(configuration: .falconEphemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.start(task, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        self.task = task
        self.continuation = continuation
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        let tooLarge = response.expectedContentLength > Int64(FalconLimits.responseBytes)
        if tooLarge { oversized = true }
        lock.unlock()
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        count = min(FalconLimits.responseBytes + 1, count + data.count)
        if body.count < FalconLimits.responseBytes {
            body.append(contentsOf: data.prefix(FalconLimits.responseBytes - body.count))
        }
        let tooLarge = count > FalconLimits.responseBytes
        if tooLarge { oversized = true }
        lock.unlock()
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let response = self.response
        let oversized = self.oversized
        let body = self.body
        lock.unlock()
        guard let continuation else { return }
        if oversized {
            continuation.resume(throwing: JevResponseLimitError(prefix: Data(body.prefix(4_096))))
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (body, response))
        } else {
            continuation.resume(
                throwing: FalconError(
                    "upstream_transport", "Invalid upstream transport response", status: 502, outcomeUnknown: true))
        }
    }
}

extension URLSessionConfiguration {
    fileprivate static var falconEphemeral: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}
