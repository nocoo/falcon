import AppKit
import FalconCore
import SwiftUI

@main struct FalconApp: App {
    @NSApplicationDelegateAdaptor(FalconDelegate.self) private var delegate
    private var runtime: AppRuntime { delegate.runtime }
    @Environment(\.openWindow) private var openWindow
    @State private var needsLaunchWindow = true
    private let navigationPages = [WorkspacePage.decisions, .usage, .sources, .connections]

    var body: some Scene {
        Window("Falcon", id: "main") {
            ZStack {
                if let model = runtime.workspace {
                    WorkspaceView(model: model, runtime: runtime)
                } else if let error = runtime.startupError {
                    ContentUnavailableView {
                        Label("Falcon needs attention", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await runtime.retryServer() } }
                    }.frame(minWidth: 1120, minHeight: 720)
                } else {
                    ProgressView("Opening your workspace…").frame(minWidth: 1120, minHeight: 720)
                }
            }
        }.defaultSize(width: 1600, height: 1000).defaultLaunchBehavior(.presented).windowResizability(.contentMinSize)
            .onChange(of: runtime.statusTitle, initial: true) {
                if needsLaunchWindow {
                    needsLaunchWindow = false
                    openWindow(id: "main")
                }
            }.commands {
                CommandGroup(replacing: .newItem) {
                    Button("Open Falcon") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }.keyboardShortcut("0")
                }
                CommandGroup(after: .appSettings) {
                    Button("Settings…") {
                        runtime.workspace?.page = .settings
                        openWindow(id: "main")
                    }.keyboardShortcut(",")
                }
                CommandGroup(after: .sidebar) {
                    ForEach(Array(navigationPages.enumerated()), id: \.element) { index, page in
                        Button(page.rawValue) {
                            runtime.workspace?.page = page
                            openWindow(id: "main")
                            NSApp.activate()
                        }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    }
                }
            }
        MenuBarExtra {
            Text("Falcon · \(runtime.statusTitle)")
            Divider()
            Button("Open workspace") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Button(runtime.isPaused ? "Resume service" : "Pause service") { Task { await runtime.togglePause() } }
                .disabled(runtime.preview)
            Divider()
            Button("Quit Falcon") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            if let image = FalconAssets.mark {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().frame(width: 18, height: 18)
                    .accessibilityLabel("Falcon")
            }
        }
    }
}

@MainActor final class FalconDelegate: NSObject, NSApplicationDelegate {
    let runtime = AppRuntime(preview: CommandLine.arguments.contains("--preview"))
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var terminating = false
    private var shutdownComplete = false
    private var didCapture = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = FalconAssets.bundle.image(forResource: "Falcon")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if CommandLine.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.runtime.sleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.runtime.wake() }
            },
        ]
        Task {
            await runtime.start()
            await captureIfRequested()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownComplete else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await runtime.shutdown()
            shutdownComplete = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func captureIfRequested() async {
        guard !didCapture, CommandLine.arguments.contains("--preview"),
            let index = CommandLine.arguments.firstIndex(of: "--capture"),
            CommandLine.arguments.indices.contains(index + 1)
        else { return }
        didCapture = true
        if CommandLine.arguments.contains("--focus") { runtime.workspace?.focusReview = true }
        if CommandLine.arguments.contains("--usage") {
            runtime.workspace?.page = .usage
            await runtime.workspace?.refresh(reset: true)
        }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        do {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }), let content = window.contentView else {
                throw FalconError(
                    "capture_window", "Falcon's preview window is unavailable: \(NSApp.windows.map(\.title)).")
            }
            if CommandLine.arguments.contains("--compact") {
                window.setContentSize(NSSize(width: 1120, height: 720))
            } else {
                window.setContentSize(NSSize(width: 1600, height: 1000))
            }
            if CommandLine.arguments.contains("--replay") {
                await runtime.workspace?.startReplay(range: false)
                runtime.workspace?.step(forward: true)
                runtime.workspace?.step(forward: true)
            }
            try await Task.sleep(for: .milliseconds(500))
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw FalconError("capture_bitmap", "Falcon's preview bitmap is unavailable.")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw FalconError("capture_png", "Falcon's preview could not be encoded.")
            }
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
        await runtime.shutdown()
        shutdownComplete = true
        NSApp.terminate(nil)
    }
}
