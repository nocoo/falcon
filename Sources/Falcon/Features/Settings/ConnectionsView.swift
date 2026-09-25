import FalconCore
import SwiftUI

struct ConnectionsView: View {
    @Bindable var model: WorkspaceModel
    let service: DecisionService?
    @State private var editing: UpstreamProfile?
    @State private var showingEditor = false
    @State private var checking: UpstreamProfile?
    @State private var confirmTest = false
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(
                    eyebrow: "Upstream", title: "Connections",
                    subtitle: "Manage Jev endpoints and credentials in one place."
                ) {
                    Button {
                        editing = nil
                        showingEditor = true
                    } label: {
                        Label("Add connection", systemImage: "plus")
                    }.buttonStyle(FalconButtonStyle(prominent: true)).disabled(model.isPreview)
                }
                if model.profiles.isEmpty {
                    Surface(inset: 32) {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 28)).foregroundStyle(
                                FalconTheme.accent)
                            Text("Connect your first Jev endpoint").font(.system(size: 18, weight: .semibold))
                            Text(
                                "Add your TypeSafe API key, then create a local key for each agent. "
                                    + "Several sources can share this connection."
                            ).foregroundStyle(FalconTheme.secondary).lineSpacing(4)
                            Button("Add connection") { showingEditor = true }.buttonStyle(
                                FalconButtonStyle(prominent: true))
                        }.frame(maxWidth: 540, alignment: .leading)
                    }
                }
                ForEach(model.profiles) { profile in
                    Surface(inset: 22) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 22)).foregroundStyle(
                                FalconTheme.accent
                            ).frame(width: 42, height: 42).background(
                                FalconTheme.accentWash, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Text(profile.name).font(.system(size: 16, weight: .semibold))
                                    Pill(
                                        text: profile.enabled ? "Enabled" : "Disabled",
                                        color: profile.enabled ? FalconTheme.success : FalconTheme.tertiary)
                                }
                                Text(profile.baseURL + "/v1/systemone").font(FalconTheme.mono).foregroundStyle(
                                    FalconTheme.secondary
                                ).textSelection(.enabled)
                                HStack(spacing: 16) {
                                    Label(profile.defaultModel, systemImage: "cpu")
                                    Label(
                                        "\(model.sources.filter { $0.profileID == profile.id && !$0.archived }.count) sources",
                                        systemImage: "point.3.connected.trianglepath.dotted")
                                    Text("Revision \(profile.revision)")
                                }.font(.system(size: 11)).foregroundStyle(FalconTheme.tertiary)
                            }
                            Spacer()
                            Button("Test…") {
                                checking = profile
                                confirmTest = true
                            }.buttonStyle(FalconButtonStyle()).disabled(
                                model.isPreview || !profile.enabled || isTesting || service == nil)
                            Button("Edit") {
                                editing = profile
                                showingEditor = true
                            }.buttonStyle(FalconButtonStyle()).disabled(model.isPreview)
                        }
                    }
                }
                Label(
                    "Upstream keys stay in your Mac’s Keychain. Agents only receive their own Falcon source keys.",
                    systemImage: "lock.shield"
                ).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary)
            }.padding(32).frame(maxWidth: 1150, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.sheet(isPresented: $showingEditor) { ConnectionEditor(model: model, profile: editing) }.confirmationDialog(
            "Send a test decision?", isPresented: $confirmTest, titleVisibility: .visible
        ) {
            Button("Send test decision") {
                guard let checking, let service else { return }
                Task {
                    isTesting = true
                    await model.testConnection(profileID: checking.id, service: service)
                    isTesting = false
                }
            }
        } message: {
            Text(
                "Falcon sends one fixed synthetic input to \(checking?.name ?? "this connection"). This uses your upstream account and may incur usage. The complete result is recorded in Decisions."
            )
        }
    }
}

private struct ConnectionEditor: View {
    let model: WorkspaceModel
    let profile: UpstreamProfile?
    @State private var name = "TypeSafe"
    @State private var baseURL = "https://api.typesafe.ai"
    @State private var defaultModel = "jev-latest"
    @State private var key = ""
    @State private var enabled = true
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(profile == nil ? "Add connection" : "Edit connection").font(.system(size: 23, weight: .semibold))
                .tracking(-0.5)
            Form {
                TextField("Name", text: $name)
                TextField("Base API", text: $baseURL)
                TextField("Default model", text: $defaultModel)
                SecureField(profile == nil ? "API key" : "Replace API key", text: $key)
                Toggle("Enabled", isOn: $enabled)
            }.textFieldStyle(.roundedBorder)
            Text("Endpoint: \(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/systemone").font(
                .system(size: 11, design: .monospaced)
            ).foregroundStyle(FalconTheme.secondary).textSelection(.enabled)
            Text(
                profile == nil
                    ? "The API key is stored only in Falcon’s Keychain namespace."
                    : "Leave the key empty to keep it. A new target requires its own key. "
                        + "Changes apply to new requests."
            ).font(.system(size: 12)).foregroundStyle(FalconTheme.secondary).lineSpacing(4)
            if let error { Text(error).foregroundStyle(FalconTheme.danger).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(FalconButtonStyle())
                Button(saving ? "Saving…" : "Save connection") { Task { await save() } }.buttonStyle(
                    FalconButtonStyle(prominent: true)
                ).keyboardShortcut(.defaultAction).disabled(
                    saving || name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.isEmpty
                        || (profile == nil && key.isEmpty))
            }
        }.padding(28).frame(width: 520).background(FalconTheme.canvas).foregroundStyle(FalconTheme.ink).onAppear {
            if let profile {
                name = profile.name
                baseURL = profile.baseURL
                defaultModel = profile.defaultModel
                enabled = profile.enabled
            }
        }
    }

    private func save() async {
        guard let configuration = model.configuration else { return }
        saving = true
        defer { saving = false }
        do {
            var value = profile ?? UpstreamProfile(name: name)
            value.name = name
            value.baseURL = baseURL
            value.defaultModel = defaultModel
            value.enabled = enabled
            _ = try await configuration.saveProfile(value, apiKey: key.isEmpty ? nil : key)
            key = ""
            await model.refresh(reset: true)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct PageHeading<Actions: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(title: eyebrow)
                Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                Text(subtitle).foregroundStyle(FalconTheme.secondary)
            }
            Spacer()
            actions
        }
    }
}
