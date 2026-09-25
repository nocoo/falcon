import AppKit
import Darwin
import FalconCore
import Foundation
import Observation

@MainActor @Observable final class AppRuntime {
    var workspace: WorkspaceModel?
    var startupError: String?
    var statusTitle = "Starting"
    var isRunning = false
    var isPaused = false
    var storageRejections = 0
    var inFlight = 0
    var port =
        UserDefaults.standard.integer(forKey: "proxyPort") == 0
        ? FalconLimits.port : UserDefaults.standard.integer(forKey: "proxyPort")
    private(set) var service: DecisionService?
    private var server: ProxyServer?
    private var maintenance: Task<Void, Never>?
    private var lockDescriptor: Int32 = -1
    private var started = false
    private var pausedBeforeSleep = false
    private var previewDirectory: URL?
    private var previewRunID: UUID?
    let preview: Bool

    init(preview: Bool) { self.preview = preview }

    func start() async {
        guard !started else { return }
        started = true
        do {
            if preview {
                try await startPreview()
                return
            }
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("Falcon", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            lockDescriptor = Darwin.open(
                directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw FalconError(
                    "already_running",
                    "Another Falcon instance is using this history. Open the existing window from the menu bar.")
            }
            let store = try await Task.detached {
                try DecisionStore(path: directory.appendingPathComponent("falcon.sqlite").path)
            }.value
            try await store.recoverInterrupted()
            try await store.cleanup()
            let configuration = ConfigurationManager(store: store, vault: .keychain())
            try await configuration.reconcileCredentials()
            let service = DecisionService(store: store, configuration: configuration)
            self.service = service
            workspace = WorkspaceModel(store: store, configuration: configuration)
            await workspace?.refresh(reset: true)
            do { try await startServer(configuration: configuration) } catch {
                startupError = "The local service could not start: \(error.localizedDescription)"
            }
            startMaintenance(store: store, service: service)
        } catch {
            startupError = error.localizedDescription
            statusTitle = "Needs attention"
        }
    }

    private func startPreview() async throws {
        let runID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FalconPreview-\(runID)")
        let store = try DecisionStore(path: directory.appendingPathComponent("preview.sqlite").path, testRunID: runID)
        previewDirectory = directory
        previewRunID = runID
        workspace = WorkspaceModel(store: store, preview: true)
        try await store.saveProfile(UpstreamProfile(id: PreviewData.profileID, name: "TypeSafe"))
        for source in PreviewData.sources { try await store.saveSource(source) }
        if !CommandLine.arguments.contains("--empty") {
            for record in try PreviewData.records() {
                try await store.reserve(
                    requestID: record.id, requestBytes: record.effectiveRequest?.count ?? 0,
                    questionCount: record.summary.questionCount)
                try await store.insert(record)
                try await store.release(requestID: record.id)
            }
        }
        statusTitle = "Preview"
        await workspace?.refresh(reset: true)
    }

    private func startMaintenance(store: DecisionStore, service: DecisionService) {
        maintenance = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.workspace?.validateExpiry()
                ticks += 1
                if ticks % 60 == 0 {
                    do { try await store.cleanup() } catch {
                        await service.pause()
                        self.startupError = "History cleanup failed: \(error.localizedDescription)"
                    }
                }
                await self.refreshStatus()
            }
        }
    }

    private func startServer(configuration: ConfigurationManager) async throws {
        guard let service else { return }
        let server = ProxyServer(service: service, configuration: configuration, port: port)
        self.server = server
        _ = try await server.start()
        await refreshStatus()
    }

    func refreshStatus() async {
        guard !preview, let service else { return }
        let status = await service.status()
        storageRejections = status.storageRejections
        inFlight = status.inFlight
        let bound = await server?.status().running ?? false
        isPaused = status.state == .paused
        isRunning = bound && status.state == .ready
        if !bound {
            statusTitle = "Not listening"
        } else {
            switch status.state {
            case .ready: statusTitle = "Running"
            case .needsSetup: statusTitle = "Needs setup"
            case .paused: statusTitle = "Paused"
            case .storageFault: statusTitle = "Storage fault"
            }
        }
    }

    func togglePause() async {
        guard let service else { return }
        do {
            if isPaused { try await service.resume() } else { await service.pause() }
            await refreshStatus()
        } catch { workspace?.errorMessage = error.localizedDescription }
    }

    func retryServer() async {
        if workspace == nil {
            await shutdown()
            started = false
            startupError = nil
            await start()
            return
        }
        guard let configuration = workspace?.configuration else { return }
        do {
            let wasPaused = isPaused
            try await service?.pauseAndDrain()
            try await workspace?.store.cleanup()
            try await configuration.reconcileCredentials()
            await server?.shutdown()
            try await startServer(configuration: configuration)
            if !wasPaused { try await service?.resume() }
            startupError = nil
        } catch { startupError = error.localizedDescription }
    }

    func changePort(_ newPort: Int) async {
        guard (1024...65535).contains(newPort), !preview, let configuration = workspace?.configuration else { return }
        do {
            let wasPaused = isPaused
            try await service?.pauseAndDrain()
            await server?.shutdown()
            port = newPort
            UserDefaults.standard.set(port, forKey: "proxyPort")
            try await startServer(configuration: configuration)
            if !wasPaused { try await service?.resume() }
            startupError = nil
        } catch { workspace?.errorMessage = error.localizedDescription }
        await refreshStatus()
    }

    func clearHistory() async {
        guard let workspace, let service else { return }
        do {
            workspace.stopReplay()
            try await service.clearHistory()
            workspace.resetHistoryView()
            await workspace.refresh(reset: true)
        } catch { workspace.errorMessage = error.localizedDescription }
        await refreshStatus()
    }

    func sleep() async {
        pausedBeforeSleep = isPaused
        await workspace?.setActive(false)
        await service?.pause()
    }

    func wake() async {
        do {
            try await workspace?.store.cleanup()
            if !pausedBeforeSleep { try await service?.resume() }
        } catch { workspace?.errorMessage = error.localizedDescription }
        await workspace?.setActive(true)
        await refreshStatus()
    }

    func shutdown() async {
        maintenance?.cancel()
        workspace?.pauseReplay()
        await service?.shutdown()
        await server?.shutdown()
        if let previewDirectory, let previewRunID, let workspace {
            do {
                guard try await workspace.store.testMarkerMatches(previewRunID) else { return }
                try FileManager.default.removeItem(at: previewDirectory)
            } catch { startupError = error.localizedDescription }
        }
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

}
