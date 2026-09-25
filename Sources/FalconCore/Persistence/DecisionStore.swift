import CryptoKit
import Darwin
import Foundation
import GRDB

public struct StorageCapacity: Sendable {
    public let physicalBytes: Int64
    public let reservedBytes: Int64
    public let budgetBytes: Int64
}

private enum StoreSetup {
    static func configure(_ database: Database, existed: Bool, testRunID: UUID?) throws {
        try database.execute(sql: "PRAGMA foreign_keys = ON")
        try database.execute(sql: "PRAGMA secure_delete = ON")
        if !existed { try database.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") }
        try database.execute(sql: "PRAGMA journal_mode = WAL")
        try database.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS _test_marker (run_id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS upstream_profiles (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, base_url TEXT NOT NULL,
                    default_model TEXT NOT NULL, revision INTEGER NOT NULL,
                    credential_id TEXT NOT NULL, enabled INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sources (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, profile_id TEXT NOT NULL,
                    enabled INTEGER NOT NULL, archived INTEGER NOT NULL, created_at REAL NOT NULL,
                    FOREIGN KEY (profile_id) REFERENCES upstream_profiles(id)
                );
                CREATE TABLE IF NOT EXISTS source_keys (
                    id TEXT PRIMARY KEY, source_id TEXT NOT NULL, digest BLOB NOT NULL,
                    suffix TEXT NOT NULL, created_at REAL NOT NULL, revoked_at REAL,
                    FOREIGN KEY (source_id) REFERENCES sources(id)
                );
                CREATE UNIQUE INDEX IF NOT EXISTS source_keys_active ON source_keys(source_id) WHERE revoked_at IS NULL;
                CREATE TABLE IF NOT EXISTS requests (
                    id TEXT PRIMARY KEY, source_id TEXT NOT NULL, profile_id TEXT NOT NULL,
                    received_at REAL NOT NULL, expires_at REAL NOT NULL,
                    status TEXT NOT NULL, review_state TEXT NOT NULL,
                    question_count INTEGER NOT NULL, terminal_ms REAL,
                    summary_json BLOB NOT NULL,
                    received_request BLOB, effective_request BLOB, upstream_response BLOB
                );
                CREATE INDEX IF NOT EXISTS requests_time ON requests(received_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS requests_source_time ON requests(source_id, received_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS requests_status_time ON requests(status, received_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS requests_profile_time ON requests(profile_id, received_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS requests_expiry ON requests(expires_at);
                CREATE TABLE IF NOT EXISTS questions (
                    request_id TEXT NOT NULL, question_id TEXT NOT NULL, type TEXT NOT NULL,
                    fingerprint BLOB NOT NULL, result TEXT, confidence REAL, top_probability REAL,
                    margin REAL, numeric_value REAL, PRIMARY KEY (request_id, question_id),
                    FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS questions_type_confidence ON questions(type, confidence);
                CREATE INDEX IF NOT EXISTS questions_fingerprint ON questions(fingerprint, request_id);
                CREATE INDEX IF NOT EXISTS questions_type_numeric ON questions(type, numeric_value);
                CREATE TABLE IF NOT EXISTS reviews (
                    request_id TEXT PRIMARY KEY, state TEXT NOT NULL, note TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE
                );
                """)
        if let testRunID {
            let marker: String? = try String.fetchOne(database, sql: "SELECT run_id FROM _test_marker")
            if let marker {
                guard marker == testRunID.uuidString else {
                    throw FalconError("test_marker_mismatch", "Test database marker does not match.")
                }
            } else {
                guard !existed else {
                    throw FalconError("test_marker_missing", "Existing database has no test marker.")
                }
                try database.execute(
                    sql: "INSERT INTO _test_marker(run_id) VALUES (?)", arguments: [testRunID.uuidString])
            }
        } else {
            let marker: String? = try String.fetchOne(database, sql: "SELECT run_id FROM _test_marker")
            guard marker == nil else {
                throw FalconError("test_database", "Test database cannot be opened as production data.")
            }
        }
    }

    static func restrictFiles(at path: String) throws {
        if !path.hasPrefix(":memory:") {
            for suffix in ["", "-wal", "-shm"] {
                let item = path + suffix
                if FileManager.default.fileExists(atPath: item) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item)
                }
            }
        }
    }
}

private enum DecisionSQLFilter {
    static func predicate(_ filter: DecisionFilter, before: RequestCursor?, now: Date) throws -> (
        String, [any DatabaseValueConvertible]
    ) {
        var clauses = ["expires_at > ?"]
        var values: [any DatabaseValueConvertible] = [now.timeIntervalSince1970]
        appendMetadata(filter, clauses: &clauses, values: &values)
        appendCursorAndSearch(filter, before: before, clauses: &clauses, values: &values)
        try appendQuestionEvidence(filter, clauses: &clauses, values: &values)
        return (clauses.joined(separator: " AND "), values)
    }

    private static func appendMetadata(
        _ filter: DecisionFilter, clauses: inout [String], values: inout [any DatabaseValueConvertible]
    ) {
        if let since = filter.since {
            clauses.append("received_at >= ?")
            values.append(since.timeIntervalSince1970)
        }
        if let until = filter.until {
            clauses.append("received_at < ?")
            values.append(until.timeIntervalSince1970)
        }
        if !filter.sourceIDs.isEmpty {
            clauses.append(
                "source_id IN (\(Array(repeating: "?", count: filter.sourceIDs.count).joined(separator: ",")))")
            values.append(contentsOf: filter.sourceIDs.map(\.uuidString))
        }
        if let status = filter.status {
            clauses.append("status = ?")
            values.append(status.rawValue)
        }
        if let review = filter.reviewState {
            clauses.append("review_state = ?")
            values.append(review.rawValue)
        }
    }

    private static func appendCursorAndSearch(
        _ filter: DecisionFilter, before: RequestCursor?, clauses: inout [String],
        values: inout [any DatabaseValueConvertible]
    ) {
        if let before {
            clauses.append("(received_at < ? OR (received_at = ? AND id < ?))")
            values += [
                before.receivedAt.timeIntervalSince1970, before.receivedAt.timeIntervalSince1970, before.id.uuidString,
            ]
        }
        if !filter.search.isEmpty {
            clauses.append(
                "(instr(lower(CAST(summary_json AS TEXT)), lower(?)) > 0 OR instr(lower(CAST(received_request AS TEXT)), lower(?)) > 0 OR instr(lower(CAST(effective_request AS TEXT)), lower(?)) > 0 OR instr(lower(CAST(upstream_response AS TEXT)), lower(?)) > 0)"
            )
            values += Array(repeating: filter.search, count: 4)
        }
    }

    private static func appendQuestionEvidence(
        _ filter: DecisionFilter, clauses: inout [String], values: inout [any DatabaseValueConvertible]
    ) throws {
        var questionClauses: [String] = []
        if let fingerprint = filter.questionFingerprint {
            guard fingerprint.count == 64,
                fingerprint.utf8.allSatisfy({
                    ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
                })
            else { throw FalconError("invalid_filter", "Question fingerprint must be a SHA-256 hex digest.") }
            questionClauses.append("hex(q.fingerprint)=?")
            values.append(fingerprint.uppercased())
        }
        if let band = filter.confidenceBand {
            guard (0...9).contains(band) else { throw FalconError("invalid_filter", "Confidence band must be 0 to 9.") }
            questionClauses.append(
                "q.type IN ('choice', 'score') AND q.confidence>=? AND q.confidence\(band == 9 ? "<=?" : "<?")")
            values += [Double(band) / 10, Double(band + 1) / 10]
        }
        if let band = filter.noulBand {
            guard (0...9).contains(band) else { throw FalconError("invalid_filter", "Noul band must be 0 to 9.") }
            questionClauses.append(
                "q.type='noul' AND q.numeric_value>=? AND q.numeric_value\(band == 9 ? "<=?" : "<?")")
            values += [Double(band) / 10, Double(band + 1) / 10]
        }
        if !questionClauses.isEmpty {
            clauses.append(
                "EXISTS (SELECT 1 FROM questions q WHERE q.request_id=requests.id AND \(questionClauses.joined(separator: " AND ")))"
            )
        }
    }
}

public actor DecisionStore {
    private let db: DatabaseQueue
    private let path: String
    private let budgetBytes: Int64
    private let lockFD: Int32
    private var reservations: [UUID: (bytes: Int64, generation: Int, questionCount: Int)] = [:]
    private var blockedIDs: Set<UUID> = []
    private var generation = 0

    public init(path: String, testRunID: UUID? = nil, budgetBytes: Int64 = FalconLimits.storageBytes) throws {
        guard budgetBytes > 0 else { throw FalconError("invalid_budget", "Storage budget must be positive.") }
        let file = URL(fileURLWithPath: path)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup = URLResourceValues()
        backup.isExcludedFromBackup = true
        var backupDirectory = directory
        try backupDirectory.setResourceValues(backup)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw FalconError("storage_unavailable", "Unable to open Falcon database lock.", status: 507)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FalconError("storage_in_use", "Falcon database is already open.", status: 503)
        }
        var initialized = false
        defer {
            if !initialized {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        lockFD = fd
        let existed = FileManager.default.fileExists(atPath: path)
        self.path = path
        self.budgetBytes = budgetBytes
        db = try DatabaseQueue(path: path)
        try db.write { database in try StoreSetup.configure(database, existed: existed, testRunID: testRunID) }
        try StoreSetup.restrictFiles(at: path)
        initialized = true
    }

    deinit {
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    public func profiles() throws -> [UpstreamProfile] {
        try db.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM upstream_profiles ORDER BY name, id").map(Self.profile)
        }
    }

    public func saveProfile(_ profile: UpstreamProfile) throws {
        try checkName(profile.name)
        try managedWrite(131_072) { database in
            try database.execute(
                sql: """
                    INSERT INTO upstream_profiles VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name, base_url=excluded.base_url,
                    default_model=excluded.default_model, revision=excluded.revision,
                    credential_id=excluded.credential_id, enabled=excluded.enabled
                    """,
                arguments: [
                    profile.id.uuidString, profile.name, profile.baseURL, profile.defaultModel, profile.revision,
                    profile.credentialID, profile.enabled,
                ])
        }
    }

    public func sources() throws -> [AgentSource] {
        try db.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM sources ORDER BY created_at, id").map(Self.source)
        }
    }

    public func saveSource(_ source: AgentSource) throws {
        try checkName(source.name)
        try managedWrite(131_072) { database in
            try database.execute(
                sql: """
                    INSERT INTO sources VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name, profile_id=excluded.profile_id,
                    enabled=excluded.enabled, archived=excluded.archived
                    """,
                arguments: [
                    source.id.uuidString, source.name, source.profileID.uuidString, source.enabled, source.archived,
                    source.createdAt.timeIntervalSince1970,
                ])
        }
    }

    public func createSourceWithKey(_ source: AgentSource, key: SourceKey) throws {
        try checkName(source.name)
        guard key.sourceID == source.id, key.digest.count == 32, key.suffix.count == 4, key.revokedAt == nil else {
            throw FalconError("invalid_key", "Invalid source key.")
        }
        try managedWrite(131_072) { database in
            try database.execute(
                sql: "INSERT INTO sources VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [
                    source.id.uuidString, source.name, source.profileID.uuidString, source.enabled, source.archived,
                    source.createdAt.timeIntervalSince1970,
                ])
            try database.execute(
                sql: "INSERT INTO source_keys VALUES (?, ?, ?, ?, ?, NULL)",
                arguments: [
                    key.id.uuidString, source.id.uuidString, key.digest, key.suffix,
                    key.createdAt.timeIntervalSince1970,
                ])
        }
    }

    public func sourceKeys() throws -> [SourceKey] {
        try db.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM source_keys ORDER BY created_at, id").map(Self.key)
        }
    }

    public func configurationSnapshot(tokenDigest: Data) throws -> (SourceIdentity, UpstreamProfile)? {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT * FROM source_keys WHERE revoked_at IS NULL")
            var matched: SourceKey?
            for row in rows {
                let candidate = Self.key(row)
                guard candidate.digest.count == tokenDigest.count else { continue }
                var difference: UInt8 = 0
                for index in candidate.digest.indices { difference |= candidate.digest[index] ^ tokenDigest[index] }
                if difference == 0 { matched = candidate }
            }
            guard let key = matched,
                let sourceRow = try Row.fetchOne(
                    database, sql: "SELECT * FROM sources WHERE id=?", arguments: [key.sourceID.uuidString])
            else { return nil }
            let source = Self.source(sourceRow)
            guard
                let profileRow = try Row.fetchOne(
                    database, sql: "SELECT * FROM upstream_profiles WHERE id=?",
                    arguments: [source.profileID.uuidString])
            else { return nil }
            return (SourceIdentity(source: source, keyID: key.id), Self.profile(profileRow))
        }
    }

    public func replaceKey(_ key: SourceKey) throws {
        guard key.digest.count == 32, key.suffix.count == 4 else {
            throw FalconError("invalid_key", "Invalid source key.")
        }
        try managedWrite(131_072) { database in
            try database.execute(
                sql: "UPDATE source_keys SET revoked_at=? WHERE source_id=? AND revoked_at IS NULL",
                arguments: [key.createdAt.timeIntervalSince1970, key.sourceID.uuidString])
            try database.execute(
                sql: "INSERT INTO source_keys VALUES (?, ?, ?, ?, ?, NULL)",
                arguments: [
                    key.id.uuidString, key.sourceID.uuidString, key.digest, key.suffix,
                    key.createdAt.timeIntervalSince1970,
                ])
        }
    }

    public func revokeKey(sourceID: UUID) throws {
        try managedWrite(131_072) { database in
            try database.execute(
                sql: "UPDATE source_keys SET revoked_at=? WHERE source_id=? AND revoked_at IS NULL",
                arguments: [Date().timeIntervalSince1970, sourceID.uuidString])
        }
    }

    public func reserve(requestID: UUID, requestBytes: Int, questionCount: Int) throws {
        guard !blockedIDs.contains(requestID), reservations[requestID] == nil, requestBytes >= 0,
            requestBytes <= FalconLimits.requestBytes, questionCount >= 0, questionCount <= requestBytes
        else { throw FalconError("invalid_reservation", "Invalid request reservation.", status: 507) }
        let amount = Self.reservationBytes(requestBytes: requestBytes, questionCount: questionCount)
        if !hasCapacity(amount) {
            try reclaim()
            guard hasCapacity(amount) else { throw FalconError("storage_full", "Falcon storage is full.", status: 507) }
        }
        reservations[requestID] = (amount, generation, questionCount)
    }

    public func release(requestID: UUID) throws {
        reservations.removeValue(forKey: requestID)
        blockedIDs.remove(requestID)
        _ = try physicalBytes()
    }

    public func insert(_ detail: RequestDetail) throws {
        try validate(detail)
        guard let reservation = reservations[detail.id], reservation.generation == generation,
            detail.summary.questionCount <= reservation.questionCount, !blockedIDs.contains(detail.id),
            detail.summary.expiresAt > Date()
        else { throw FalconError("request_not_reserved", "Request cannot be inserted.", status: 507) }
        try db.write { database in try Self.write(detail, database: database, insert: true) }
    }

    public func update(_ detail: RequestDetail) throws {
        try validate(detail)
        guard let reservation = reservations[detail.id], reservation.generation == generation,
            detail.summary.questionCount <= reservation.questionCount, !blockedIDs.contains(detail.id)
        else { throw FalconError("request_cleared", "Request was cleared or not reserved.") }
        try db.write { database in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT summary_json FROM requests WHERE id=? AND expires_at>?",
                    arguments: [detail.id.uuidString, Date().timeIntervalSince1970])
            else { throw FalconError("request_missing", "Request no longer exists.") }
            let old = try JSONDecoder().decode(RequestSummary.self, from: row["summary_json"] as Data)
            let next = detail.summary
            guard old.id == next.id, old.sourceID == next.sourceID, old.keyID == next.keyID,
                old.profileID == next.profileID, old.profileRevision == next.profileRevision,
                old.receivedAt == next.receivedAt, old.expiresAt == next.expiresAt, !old.status.isTerminal
            else { throw FalconError("invalid_transition", "Request identity or terminal status cannot change.") }
            var merged = detail
            merged.summary.reviewState = old.reviewState
            merged.summary.reviewNote = old.reviewNote
            merged.summary.delivery = old.delivery
            merged.summary.timing.deliveryFinishedMS = old.timing.deliveryFinishedMS
            try Self.write(merged, database: database, insert: false)
        }
    }

    public func updateDelivery(id: UUID, state: DeliveryState, finishedMS: Double?) throws {
        guard finishedMS == nil || (finishedMS!.isFinite && finishedMS! >= 0) else {
            throw FalconError("invalid_timing", "Invalid delivery timing.")
        }
        try managedWrite(131_072) { database in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT summary_json FROM requests WHERE id=? AND expires_at>?",
                    arguments: [id.uuidString, Date().timeIntervalSince1970])
            else { return }
            var summary = try JSONDecoder().decode(RequestSummary.self, from: row["summary_json"] as Data)
            guard summary.status.isTerminal else {
                throw FalconError("invalid_delivery", "Delivery requires a terminal request.")
            }
            guard state != .written || finishedMS != nil else {
                throw FalconError("invalid_delivery", "Written delivery requires timing.")
            }
            summary.delivery = state
            summary.timing.deliveryFinishedMS = finishedMS
            try database.execute(
                sql: "UPDATE requests SET summary_json=? WHERE id=?",
                arguments: [try JSONEncoder().encode(summary), id.uuidString])
        }
    }

    public func requests(
        filter: DecisionFilter = .init(), before: RequestCursor? = nil, limit: Int = 100, now: Date = Date()
    ) async throws -> [RequestSummary] {
        guard (1...100).contains(limit) else { throw FalconError("invalid_limit", "Page limit must be 1 to 100.") }
        let queue = db
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try queue.read { database in
                let (whereSQL, arguments) = try DecisionSQLFilter.predicate(
                    filter, before: before, now: max(now, Date()))
                return try Row.fetchAll(
                    database,
                    sql:
                        "SELECT summary_json FROM requests WHERE \(whereSQL) ORDER BY received_at DESC, id DESC LIMIT ?",
                    arguments: StatementArguments(arguments + [limit])
                ).map { try JSONDecoder().decode(RequestSummary.self, from: $0["summary_json"] as Data) }
            }
        } onCancel: {
            queue.interrupt()
        }
    }

    public func detail(id: UUID, now: Date = Date()) throws -> RequestDetail? {
        try db.read { database in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT * FROM requests WHERE id=? AND expires_at>?",
                    arguments: [id.uuidString, max(now, Date()).timeIntervalSince1970])
            else { return nil }
            return RequestDetail(
                summary: try JSONDecoder().decode(RequestSummary.self, from: row["summary_json"] as Data),
                receivedRequest: row["received_request"], effectiveRequest: row["effective_request"],
                upstreamResponse: row["upstream_response"])
        }
    }

    public func replayCandidates(filter: DecisionFilter, limit: Int = 10_000, now: Date = Date()) async throws
        -> [RequestSummary]
    {
        guard (1...10_000).contains(limit) else {
            throw FalconError("invalid_limit", "Replay limit must be 1 to 10000.")
        }
        let queue = db
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try queue.read { database in
                let (whereSQL, arguments) = try DecisionSQLFilter.predicate(filter, before: nil, now: max(now, Date()))
                let terminal = "status NOT IN ('accepted', 'in_flight')"
                let rows = try Row.fetchAll(
                    database,
                    sql:
                        "SELECT summary_json FROM requests WHERE \(whereSQL) AND \(terminal) ORDER BY received_at, id LIMIT ?",
                    arguments: StatementArguments(arguments + [limit + 1]))
                guard rows.count <= limit else { throw FalconError("replay_limit", "Replay exceeds 10000 requests.") }
                return try rows.map { try JSONDecoder().decode(RequestSummary.self, from: $0["summary_json"] as Data) }
            }
        } onCancel: {
            queue.interrupt()
        }
    }

    public func usage(filter: DecisionFilter = .init(), now: Date = Date()) async throws -> UsageSnapshot {
        let queue = db
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try queue.read { database in
                let current = max(now, Date())
                let (whereSQL, arguments) = try DecisionSQLFilter.predicate(filter, before: nil, now: current)
                var result = try UsageQueries.summaries(
                    database, whereSQL: whereSQL, arguments: arguments, filter: filter, current: current)
                try UsageQueries.questions(database, whereSQL: whereSQL, arguments: arguments, result: &result)
                try UsageQueries.groups(database, whereSQL: whereSQL, arguments: arguments, result: &result)
                return result
            }
        } onCancel: {
            queue.interrupt()
        }
    }

    public func saveReview(id: UUID, state: ReviewState, note: String, now: Date = Date()) throws {
        guard note.utf8.count <= 4_096 else { throw FalconError("review_too_long", "Review note exceeds 4 KiB.") }
        try managedWrite(262_144) { database in
            guard
                let row = try Row.fetchOne(
                    database, sql: "SELECT summary_json FROM requests WHERE id=? AND expires_at>?",
                    arguments: [id.uuidString, max(now, Date()).timeIntervalSince1970])
            else { throw FalconError("request_missing", "Request no longer exists.") }
            var summary = try JSONDecoder().decode(RequestSummary.self, from: row["summary_json"] as Data)
            summary.reviewState = state
            summary.reviewNote = note
            try database.execute(
                sql:
                    "INSERT INTO reviews VALUES (?, ?, ?, ?) ON CONFLICT(request_id) DO UPDATE SET state=excluded.state, note=excluded.note, updated_at=excluded.updated_at",
                arguments: [id.uuidString, state.rawValue, note, max(now, Date()).timeIntervalSince1970])
            try database.execute(
                sql: "UPDATE requests SET review_state=?, summary_json=? WHERE id=?",
                arguments: [state.rawValue, try JSONEncoder().encode(summary), id.uuidString])
        }
    }

    public func cleanup(now: Date = Date()) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM requests WHERE expires_at<=?", arguments: [max(now, Date()).timeIntervalSince1970])
        }
        try reclaimPages()
    }

    public func recoverInterrupted(now: Date = Date()) throws {
        try db.write { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT id, summary_json FROM requests WHERE expires_at>? AND status IN ('accepted', 'in_flight')",
                arguments: [max(now, Date()).timeIntervalSince1970])
            for row in rows {
                var summary = try JSONDecoder().decode(RequestSummary.self, from: row["summary_json"] as Data)
                summary.status = .interrupted
                summary.delivery = .unknown
                try database.execute(
                    sql: "UPDATE requests SET status=?, summary_json=? WHERE id=?",
                    arguments: [
                        RequestStatus.interrupted.rawValue, try JSONEncoder().encode(summary), summary.id.uuidString,
                    ])
            }
        }
    }

    public func clearHistory() throws {
        blockedIDs.formUnion(reservations.keys)
        generation += 1
        reservations.removeAll()
        try db.write { database in try database.execute(sql: "DELETE FROM requests") }
        try reclaimPages()
    }

    public func storageBytes() throws -> Int64 { try physicalBytes() }

    public func capacityUsage() throws -> StorageCapacity {
        StorageCapacity(physicalBytes: try physicalBytes(), reservedBytes: reservedBytes(), budgetBytes: budgetBytes)
    }

    public func testMarkerMatches(_ id: UUID) throws -> Bool {
        try db.read { database in
            let marker: String? = try String.fetchOne(database, sql: "SELECT run_id FROM _test_marker")
            return marker == id.uuidString
        }
    }

    private func managedWrite(_ extra: Int64, _ body: (Database) throws -> Void) throws {
        guard hasCapacity(extra) else { throw FalconError("storage_full", "Falcon storage is full.", status: 507) }
        try db.write(body)
    }

    private func hasCapacity(_ extra: Int64) -> Bool {
        guard let physical = try? physicalBytes(), let free = try? freeBytes() else { return false }
        let outstanding = reservedBytes()
        return physical <= budgetBytes - outstanding - extra && free >= 268_435_456 + extra
    }

    private func reservedBytes() -> Int64 { reservations.values.reduce(Int64(0)) { $0 + $1.bytes } }

    private func physicalBytes() throws -> Int64 {
        try [path, path + "-wal", path + "-shm"].reduce(Int64(0)) { total, name in
            guard FileManager.default.fileExists(atPath: name) else { return total }
            let value = try FileManager.default.attributesOfItem(atPath: name)[.size] as? NSNumber
            return total + (value?.int64Value ?? 0)
        }
    }

    private func freeBytes() throws -> Int64 {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else {
            throw FalconError("storage_unavailable", "Unable to measure free space.", status: 507)
        }
        return Int64(info.f_bavail) * Int64(info.f_frsize)
    }

    private func reclaim() throws { try cleanup() }

    private func reclaimPages() throws {
        _ = try db.writeWithoutTransaction { database in
            var remaining = try Int.fetchOne(database, sql: "PRAGMA freelist_count") ?? 0
            while remaining > 0 {
                try database.execute(sql: "PRAGMA incremental_vacuum(1024)")
                let next = try Int.fetchOne(database, sql: "PRAGMA freelist_count") ?? 0
                if next >= remaining { break }
                remaining = next
            }
            return try database.checkpoint(.truncate)
        }
    }

    private static func reservationBytes(requestBytes: Int, questionCount: Int) -> Int64 {
        let logical =
            Int64(FalconLimits.responseBytes) + Int64(requestBytes) * 4 + Int64(questionCount) * 16_384 + 131_072
        return logical * 4
    }

    private func validate(_ detail: RequestDetail) throws {
        let summary = detail.summary
        guard summary.expiresAt == summary.receivedAt.addingTimeInterval(FalconLimits.retention),
            summary.questionCount >= 0, summary.preview.utf8.count <= 4_096,
            (try? JSONEncoder().encode(summary.metadata).count) ?? Int.max <= 4_096,
            (try? JSONEncoder().encode(summary).count) ?? Int.max <= 32_768,
            (detail.receivedRequest?.count ?? 0) <= FalconLimits.requestBytes,
            (detail.effectiveRequest?.count ?? 0) <= FalconLimits.requestBytes,
            (detail.upstreamResponse?.count ?? 0) <= FalconLimits.responseBytes,
            [
                summary.timing.bodyReceivedMS, summary.timing.upstreamStartedMS, summary.timing.responseReceivedMS,
                summary.timing.terminalMS, summary.timing.deliveryFinishedMS,
            ].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 })
        else { throw FalconError("invalid_record", "Request record exceeds bounds or has invalid timing.") }
    }

    private static func write(_ detail: RequestDetail, database: Database, insert: Bool) throws {
        let summary = detail.summary
        let json = try JSONEncoder().encode(summary)
        if insert {
            try database.execute(
                sql: "INSERT INTO requests VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    summary.id.uuidString, summary.sourceID.uuidString, summary.profileID.uuidString,
                    summary.receivedAt.timeIntervalSince1970, summary.expiresAt.timeIntervalSince1970,
                    summary.status.rawValue, summary.reviewState.rawValue, summary.questionCount,
                    summary.timing.terminalMS, json, detail.receivedRequest, detail.effectiveRequest,
                    detail.upstreamResponse,
                ])
        } else {
            try database.execute(
                sql: """
                    UPDATE requests SET status=?, review_state=?, question_count=?, terminal_ms=?,
                    summary_json=?, received_request=?, effective_request=?, upstream_response=? WHERE id=?
                    """,
                arguments: [
                    summary.status.rawValue, summary.reviewState.rawValue, summary.questionCount,
                    summary.timing.terminalMS, json, detail.receivedRequest, detail.effectiveRequest,
                    detail.upstreamResponse, summary.id.uuidString,
                ])
        }
        let projections = try projectQuestions(detail)
        guard projections.count <= summary.questionCount else {
            throw FalconError("invalid_record", "Question count exceeds reservation.")
        }
        try database.execute(sql: "DELETE FROM questions WHERE request_id=?", arguments: [summary.id.uuidString])
        for question in projections {
            try database.execute(
                sql: "INSERT INTO questions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    summary.id.uuidString, question.id, question.type, question.fingerprint, question.result,
                    question.confidence, question.topProbability, question.margin, question.numericValue,
                ])
        }
    }

    private struct QuestionProjection {
        let id: String
        let type: String
        let fingerprint: Data
        let result: String?
        let confidence: Double?
        let topProbability: Double?
        let margin: Double?
        let numericValue: Double?
    }

    private static func projectQuestions(_ detail: RequestDetail) throws -> [QuestionProjection] {
        guard let data = detail.effectiveRequest, let request = try? JSONValue.decode(data),
            let questions = request["questions"]?.objectValue
        else { return [] }
        let answers = detail.upstreamResponse.flatMap { try? JSONValue.decode($0)["answers"]?.objectValue } ?? [:]
        return try questions.map { id, definition in
            let answer = answers[id]
            let probabilities =
                answer?["probabilities"]?.objectValue?.values.compactMap(\.numberValue).sorted(by: >) ?? answer?[
                    "probabilities"]?.arrayValue?.compactMap(\.numberValue).sorted(by: >) ?? []
            let type = definition["type"]?.stringValue ?? "unknown"
            let selected = type == "choice" ? answer?["choice"]?.stringValue : nil
            var semantics: [String: JSONValue] = ["type": .string(type)]
            if let instructions = definition["instructions"] { semantics["instructions"] = instructions }
            if let criteria = definition["criteria"] { semantics["criteria"] = criteria }
            let fingerprint = Data(SHA256.hash(data: try JSONValue.object(semantics).data()))
            return QuestionProjection(
                id: id, type: type, fingerprint: fingerprint, result: selected,
                confidence: answer?["confidence"]?.numberValue, topProbability: probabilities.first,
                margin: probabilities.count > 1 ? probabilities[0] - probabilities[1] : nil,
                numericValue: type == "score"
                    ? answer?["score"]?.numberValue : (type == "noul" ? answer?["noul"]?.numberValue : nil))
        }
    }

    private func checkName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw FalconError("invalid_name", "Name must contain 1 to 120 characters.")
        }
    }

    private static func profile(_ row: Row) -> UpstreamProfile {
        UpstreamProfile(
            id: UUID(uuidString: row["id"] as String)!, name: row["name"], baseURL: row["base_url"],
            defaultModel: row["default_model"], revision: row["revision"], credentialID: row["credential_id"],
            enabled: row["enabled"])
    }

    private static func source(_ row: Row) -> AgentSource {
        AgentSource(
            id: UUID(uuidString: row["id"] as String)!, name: row["name"],
            profileID: UUID(uuidString: row["profile_id"] as String)!, enabled: row["enabled"],
            archived: row["archived"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }

    private static func key(_ row: Row) -> SourceKey {
        let revoked: Double? = row["revoked_at"]
        return SourceKey(
            id: UUID(uuidString: row["id"] as String)!, sourceID: UUID(uuidString: row["source_id"] as String)!,
            digest: row["digest"], suffix: row["suffix"], createdAt: Date(timeIntervalSince1970: row["created_at"]),
            revokedAt: revoked.map(Date.init(timeIntervalSince1970:)))
    }
}

private struct RequestUsageAccumulator {
    private(set) var result = UsageSnapshot()
    private var processing: [Double] = []
    private var returning: [Double] = []
    private var buckets: [Date: UsageBucket] = [:]
    private var sources: [UUID: SourceUsage] = [:]
    private var models: [String: Int] = [:]

    init(filter: DecisionFilter, current: Date) {
        guard let since = filter.since?.timeIntervalSince1970, let until = filter.until?.timeIntervalSince1970,
            since.isFinite, until.isFinite, until > since
        else { return }
        result.bucketSeconds = until - since <= 3_600 ? 300 : (until - since <= 86_400 ? 3_600 : 86_400)
        let start = max(since, current.timeIntervalSince1970 - FalconLimits.retention)
        let end = min(until, current.timeIntervalSince1970)
        guard end > start else { return }
        let step = result.bucketSeconds
        for index in Int(floor(start / step))...Int(floor(end.nextDown / step)) {
            let date = Date(timeIntervalSince1970: Double(index) * step)
            buckets[date] = UsageBucket(date: date, requests: 0, failures: 0)
        }
    }

    mutating func add(_ summary: RequestSummary) {
        result.requests += 1
        result.questions += summary.questionCount
        if summary.status.isTerminal { addTerminal(summary) }
        result.inputTokens += summary.inputTokens ?? 0
        result.outputTokens += summary.outputTokens ?? 0
        if summary.inputTokens == nil || summary.outputTokens == nil { result.unknownUsage += 1 }
        let date = Date(
            timeIntervalSince1970: floor(summary.receivedAt.timeIntervalSince1970 / result.bucketSeconds)
                * result.bucketSeconds)
        var bucket = buckets[date] ?? UsageBucket(date: date, requests: 0, failures: 0)
        bucket.requests += 1
        if summary.status.isFailure { bucket.failures += 1 }
        bucket.inputTokens += summary.inputTokens ?? 0
        bucket.outputTokens += summary.outputTokens ?? 0
        buckets[date] = bucket
        var source =
            sources[summary.sourceID] ?? SourceUsage(id: summary.sourceID, name: summary.sourceName, requests: 0)
        source.requests += 1
        source.inputTokens += summary.inputTokens ?? 0
        source.outputTokens += summary.outputTokens ?? 0
        source.lastReceivedAt = max(source.lastReceivedAt ?? summary.receivedAt, summary.receivedAt)
        sources[summary.sourceID] = source
        models[summary.resolvedModel ?? summary.requestedModel, default: 0] += 1
    }

    private mutating func addTerminal(_ summary: RequestSummary) {
        result.terminal += 1
        result.completedQuestions += summary.status == .succeeded ? summary.questionCount : 0
        if summary.status.isFailure { result.failures += 1 }
        if summary.timing.upstreamStartedMS != nil { result.forwardedTerminal += 1 }
        if summary.status == .succeeded { result.succeeded += 1 }
        if let duration = summary.timing.terminalMS, duration.isFinite, duration >= 0 {
            processing.append(duration)
        } else {
            result.missingLatency += 1
        }
        if summary.delivery == .written, let duration = summary.timing.deliveryFinishedMS, duration.isFinite,
            duration >= 0
        {
            returning.append(duration)
        } else {
            result.missingReturnLatency += 1
        }
    }

    mutating func finish() -> UsageSnapshot {
        processing.sort()
        returning.sort()
        result.latencySamples = processing.count
        result.returnLatencySamples = returning.count
        if !processing.isEmpty {
            result.p50MS = processing[Int(ceil(0.5 * Double(processing.count))) - 1]
            result.p95MS = processing[Int(ceil(0.95 * Double(processing.count))) - 1]
        }
        if !returning.isEmpty {
            result.returnP50MS = returning[Int(ceil(0.5 * Double(returning.count))) - 1]
            result.returnP95MS = returning[Int(ceil(0.95 * Double(returning.count))) - 1]
        }
        result.processingLatencies = Self.latencyBuckets(processing)
        result.returnLatencies = Self.latencyBuckets(returning)
        result.models = models.map { CategoryUsage(name: $0.key, count: $0.value) }.sorted {
            $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }
        result.buckets = buckets.values.sorted { $0.date < $1.date }
        result.sources = sources.values.sorted { $0.name < $1.name }
        return result
    }

    private static func latencyBuckets(_ samples: [Double]) -> [LatencyBucket] {
        let bounds: [Double] = [100, 500, 1_000, 5_000, 10_000]
        let labels = ["<100 ms", "100–500 ms", "500 ms–1 s", "1–5 s", "5–10 s", "≥10 s"]
        var counts = Array(repeating: 0, count: labels.count)
        for sample in samples { counts[bounds.firstIndex(where: { sample < $0 }) ?? bounds.count] += 1 }
        return labels.enumerated().map { LatencyBucket(label: $0.element, count: counts[$0.offset]) }
    }
}

private enum UsageQueries {
    static func summaries(
        _ database: Database, whereSQL: String, arguments: [any DatabaseValueConvertible], filter: DecisionFilter,
        current: Date
    ) throws -> UsageSnapshot {
        let cursor = try Row.fetchCursor(
            database, sql: "SELECT summary_json FROM requests WHERE \(whereSQL)",
            arguments: StatementArguments(arguments))
        var aggregate = RequestUsageAccumulator(filter: filter, current: current)
        while let row = try cursor.next() {
            try Task.checkCancellation()
            aggregate.add(try JSONDecoder().decode(RequestSummary.self, from: row["summary_json"] as Data))
        }
        return aggregate.finish()
    }

    static func questions(
        _ database: Database, whereSQL: String, arguments: [any DatabaseValueConvertible], result: inout UsageSnapshot
    ) throws {
        let questionSQL = "FROM questions q JOIN requests ON requests.id=q.request_id WHERE \(whereSQL)"
        let cursor = try Row.fetchCursor(
            database, sql: "SELECT q.type, q.confidence, q.numeric_value, requests.status \(questionSQL)",
            arguments: StatementArguments(arguments))
        var types: [String: Int] = [:]
        var confidence = Array(repeating: 0, count: 10)
        var noul = Array(repeating: 0, count: 10)
        while let row = try cursor.next() {
            try Task.checkCancellation()
            let type: String = row["type"]
            types[type, default: 0] += 1
            guard (row["status"] as String) == RequestStatus.succeeded.rawValue else { continue }
            if type == "choice" || type == "score" {
                let value: Double? = row["confidence"]
                if let value, value.isFinite, (0...1).contains(value) {
                    confidence[min(9, Int(value * 10))] += 1
                } else {
                    result.missingConfidence += 1
                }
            } else if type == "noul" {
                let value: Double? = row["numeric_value"]
                if let value, value.isFinite, (0...1).contains(value) {
                    noul[min(9, Int(value * 10))] += 1
                } else {
                    result.missingNoul += 1
                }
            }
        }
        result.questionTypes = types.map { CategoryUsage(name: $0.key, count: $0.value) }.sorted {
            $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }
        result.confidence = confidence.enumerated().map { ProbabilityBucket(index: $0.offset, count: $0.element) }
        result.noul = noul.enumerated().map { ProbabilityBucket(index: $0.offset, count: $0.element) }
    }

    static func groups(
        _ database: Database, whereSQL: String, arguments: [any DatabaseValueConvertible], result: inout UsageSnapshot
    ) throws {
        let succeededSQL =
            "FROM questions q JOIN requests ON requests.id=q.request_id WHERE \(whereSQL) AND requests.status='succeeded'"
        let groupCount =
            try Int.fetchOne(
                database, sql: "SELECT COUNT(DISTINCT q.fingerprint) \(succeededSQL)",
                arguments: StatementArguments(arguments)) ?? 0
        result.omittedDecisionGroups = max(0, groupCount - 100)
        let groupRows = try Row.fetchAll(
            database,
            sql: """
                SELECT q.fingerprint, hex(q.fingerprint) AS fingerprint_hex, MIN(q.question_id) AS question_id,
                       MIN(q.type) AS type, COUNT(*) AS samples, AVG(q.numeric_value) AS mean,
                       MIN(q.numeric_value) AS minimum, MAX(q.numeric_value) AS maximum
                \(succeededSQL) GROUP BY q.fingerprint ORDER BY samples DESC, fingerprint_hex LIMIT 100
                """, arguments: StatementArguments(arguments))
        for row in groupRows {
            try Task.checkCancellation()
            let type: String = row["type"]
            let fingerprint: Data = row["fingerprint"]
            var outcomes: [CategoryUsage] = []
            if type == "choice" {
                let outcomeRows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT q.result AS name, COUNT(*) AS count \(succeededSQL) AND q.fingerprint=?
                        GROUP BY q.result ORDER BY count DESC, name
                        """, arguments: StatementArguments(arguments + [fingerprint]))
                outcomes = outcomeRows.compactMap { outcome in
                    guard let name: String = outcome["name"] else { return nil }
                    return CategoryUsage(name: name, count: outcome["count"])
                }
            }
            result.decisionGroups.append(
                DecisionGroup(
                    fingerprint: row["fingerprint_hex"], questionID: row["question_id"], type: type,
                    samples: row["samples"], outcomes: outcomes, mean: row["mean"], minimum: row["minimum"],
                    maximum: row["maximum"]))
        }
    }
}
