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
            VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                PageHeading(title: "Settings", subtitle: "Keep Falcon small, local, and under your control.") {
                    EmptyView()
                }
                Surface(inset: FalconTheme.Space.section) {
                    VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                        Text("Appearance").font(FalconTheme.sectionTitle)
                        HStack {
                            VStack(alignment: .leading, spacing: FalconTheme.Space.tight) {
                                Text("Theme")
                                Text("Follows macOS accessibility and motion preferences.").font(FalconTheme.detail)
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
                Surface(inset: FalconTheme.Space.section) {
                    VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                        HStack {
                            Text("Local service").font(FalconTheme.sectionTitle)
                            Spacer()
                            Pill(
                                text: runtime.statusTitle,
                                color: runtime.isRunning ? FalconTheme.success : FalconTheme.tertiary)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: FalconTheme.Space.tight) {
                                Text("Listening port")
                                Text("Available only at 127.0.0.1 on this Mac.").font(FalconTheme.detail)
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
                            .font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
                    }
                }
                Surface(inset: FalconTheme.Space.section) {
                    VStack(alignment: .leading, spacing: FalconTheme.Space.large) {
                        Text("History & storage").font(FalconTheme.sectionTitle)
                        HStack {
                            VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
                                Text("Seven rolling days").font(FalconTheme.sectionTitle)
                                Text(
                                    "Full inputs and responses stay on this Mac for 168 hours. "
                                        + "Every new request still calls Jev."
                                ).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary).lineSpacing(
                                    FalconTheme.Space.small)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .binary))
                                .font(FalconTheme.compactValue)
                        }
                        ProgressView(value: Double(model.storageBytes), total: Double(FalconLimits.storageBytes)).tint(
                            FalconTheme.accent)
                        if runtime.storageRejections > 0 {
                            Label(
                                "\(runtime.storageRejections) requests rejected for insufficient storage in this session.",
                                systemImage: "exclamationmark.triangle"
                            ).font(FalconTheme.detail).foregroundStyle(FalconTheme.warning)
                        }
                        HStack {
                            Text("2 GiB limit · history is never silently shortened").font(FalconTheme.footnote)
                                .foregroundStyle(FalconTheme.tertiary)
                            Spacer()
                            Button(clearing ? "Clearing…" : "Clear history…", role: .destructive) {
                                confirmClear = true
                            }.buttonStyle(FalconButtonStyle()).disabled(clearing || model.isPreview)
                        }
                        Text(
                            "Recorded payloads may include sensitive context. "
                                + "Exported files are yours to manage and are not removed by Falcon."
                        ).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary).lineSpacing(
                            FalconTheme.Space.small)
                    }
                }
                HStack(spacing: FalconTheme.Space.regular) {
                    FalconMark()
                    Text("Falcon \(runtime.versionLabel)").font(FalconTheme.label)
                    Text("Native decision observability").font(FalconTheme.detail).foregroundStyle(FalconTheme.tertiary)
                }
            }.padding(FalconTheme.Space.page).frame(maxWidth: FalconTheme.Layout.settingsWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
