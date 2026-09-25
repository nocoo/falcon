import FalconCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var runtime: AppRuntime
    @AppStorage("appearance") private var appearance = "system"
    @State private var portText = ""
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(
                    eyebrow: "Your workspace", title: "Settings",
                    subtitle: "Keep Falcon small, local, and under your control."
                ) { EmptyView() }
                Surface(inset: 24) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Appearance").font(.system(size: 15, weight: .semibold))
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Theme")
                                Text("Follows macOS accessibility and motion preferences.").font(.system(size: 12))
                                    .foregroundStyle(FalconTheme.secondary)
                            }
                            Spacer()
                            Picker("Theme", selection: $appearance) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }.labelsHidden().pickerStyle(.segmented).frame(width: 250)
                        }
                    }
                }
                Surface(inset: 24) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text("Local service").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Pill(
                                text: runtime.statusTitle,
                                color: runtime.isRunning ? FalconTheme.success : FalconTheme.tertiary)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Listening port")
                                Text("Available only at 127.0.0.1 on this Mac.").font(.system(size: 12))
                                    .foregroundStyle(FalconTheme.secondary)
                            }
                            Spacer()
                            TextField("Port", text: $portText).textFieldStyle(.roundedBorder).frame(width: 85)
                            Button("Apply") { if let port = Int(portText) { Task { await runtime.changePort(port) } } }
                                .buttonStyle(FalconButtonStyle()).disabled(
                                    model.isPreview || Int(portText).map { !(1024...65535).contains($0) } != false)
                        }
                        Divider()
                        Toggle("Start Falcon at login", isOn: $loginEnabled).disabled(model.isPreview).onChange(
                            of: loginEnabled
                        ) { _, value in
                            do {
                                if value {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                model.errorMessage = error.localizedDescription
                                loginEnabled = SMAppService.mainApp.status == .enabled
                            }
                        }
                        Text("Closing the window keeps the service running in the menu bar. Quit Falcon to stop it.")
                            .font(.system(size: 12)).foregroundStyle(FalconTheme.secondary)
                    }
                }
                Surface(inset: 24) {
                    VStack(alignment: .leading, spacing: 19) {
                        Text("History & storage").font(.system(size: 15, weight: .semibold))
                        HStack {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Seven rolling days").font(.system(size: 16, weight: .medium))
                                Text(
                                    "Full inputs and responses stay on this Mac for 168 hours. "
                                        + "Every new request still calls Jev."
                                ).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary).lineSpacing(4)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .binary))
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                        }
                        ProgressView(value: Double(model.storageBytes), total: Double(FalconLimits.storageBytes)).tint(
                            FalconTheme.accent)
                        if runtime.storageRejections > 0 {
                            Label(
                                "\(runtime.storageRejections) requests rejected for insufficient storage in this session.",
                                systemImage: "exclamationmark.triangle"
                            ).font(.system(size: 12)).foregroundStyle(FalconTheme.warning)
                        }
                        HStack {
                            Text("2 GiB limit · history is never silently shortened").font(.system(size: 11))
                                .foregroundStyle(FalconTheme.tertiary)
                            Spacer()
                            Button(clearing ? "Clearing…" : "Clear history…", role: .destructive) {
                                confirmClear = true
                            }.buttonStyle(FalconButtonStyle()).disabled(clearing || model.isPreview)
                        }
                        Text(
                            "Recorded payloads may include sensitive context. "
                                + "Exported files are yours to manage and are not removed by Falcon."
                        ).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary).lineSpacing(4)
                    }
                }
                HStack(spacing: 10) {
                    FalconMark(size: 28)
                    Text("Falcon 0.1.0").font(.system(size: 12, weight: .medium))
                    Text("Native decision observability").font(.system(size: 12)).foregroundStyle(FalconTheme.tertiary)
                }
            }.padding(32).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.onAppear { portText = String(runtime.port) }.confirmationDialog(
            "Clear all decision history?", isPresented: $confirmClear, titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                Task {
                    clearing = true
                    await runtime.clearHistory()
                    clearing = false
                }
            }
        } message: {
            Text(
                "This removes recorded requests, responses, usage, and review notes. Sources and connections are kept.")
        }
    }
}
