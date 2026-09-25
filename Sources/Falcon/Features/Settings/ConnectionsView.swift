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
            VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                PageHeading(title: "Connections", subtitle: "Manage Jev endpoints and credentials in one place.") {
                    Button {
                        editing = nil
                        showingEditor = true
                    } label: {
                        Label("Add connection", systemImage: "plus")
                    }.buttonStyle(FalconButtonStyle(prominent: true)).disabled(model.isPreview)
                }
                if model.profiles.isEmpty {
                    Surface(inset: FalconTheme.Space.page) {
                        VStack(alignment: .leading, spacing: FalconTheme.Space.medium) {
                            Image(systemName: "arrow.up.right.square").font(FalconTheme.featureSymbol).foregroundStyle(
                                FalconTheme.accent)
                            Text("Connect your first Jev endpoint").font(FalconTheme.sectionTitle)
                            Text(
                                "Add your TypeSafe API key, then create a local key for each agent. "
                                    + "Several sources can share this connection."
                            ).foregroundStyle(FalconTheme.secondary).lineSpacing(FalconTheme.Space.small)
                            Button("Add connection") { showingEditor = true }.buttonStyle(
                                FalconButtonStyle(prominent: true))
                        }.frame(maxWidth: 540, alignment: .leading)
                    }
                }
                ForEach(model.profiles) { profile in
                    Surface(inset: FalconTheme.Space.large) {
                        HStack(alignment: .top, spacing: FalconTheme.Space.medium) {
                            Image(systemName: "arrow.up.right.square").font(FalconTheme.symbol).foregroundStyle(
                                FalconTheme.accent
                            ).frame(width: FalconTheme.Layout.profileAvatar, height: FalconTheme.Layout.profileAvatar)
                                .background(
                                    FalconTheme.accentWash,
                                    in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control))
                            VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
                                HStack(spacing: FalconTheme.Space.compact) {
                                    Text(profile.name).font(FalconTheme.sectionTitle)
                                    Pill(
                                        text: profile.enabled ? "Enabled" : "Disabled",
                                        color: profile.enabled ? FalconTheme.success : FalconTheme.tertiary)
                                }
                                Text(profile.baseURL + "/v1/systemone").font(FalconTheme.mono).foregroundStyle(
                                    FalconTheme.secondary
                                ).textSelection(.enabled)
                                HStack(spacing: FalconTheme.Space.medium) {
                                    Label(profile.defaultModel, systemImage: "cpu")
                                    Label(
                                        "\(model.sources.filter { $0.profileID == profile.id && !$0.archived }.count) sources",
                                        systemImage: "point.3.connected.trianglepath.dotted")
                                    Text("Revision \(profile.revision)")
                                }.font(FalconTheme.footnote).foregroundStyle(FalconTheme.tertiary)
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
                    "Upstream keys are saved in ~/.config/falcon/credentials.json, accessible only to your macOS user.",
                    systemImage: "lock.shield"
                ).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
            }.padding(FalconTheme.Space.page).frame(maxWidth: FalconTheme.Layout.managementWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
            Text(profile == nil ? "Add connection" : "Edit connection").font(FalconTheme.title).tracking(
                FalconTheme.titleTracking)
            Form {
                TextField("Name", text: $name)
                TextField("Base API", text: $baseURL)
                TextField("Default model", text: $defaultModel)
                SecureField(profile == nil ? "API key" : "Replace API key", text: $key)
                Toggle("Enabled", isOn: $enabled)
            }.textFieldStyle(.roundedBorder)
            Text("Endpoint: \(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/systemone").font(
                FalconTheme.monoSmall
            ).foregroundStyle(FalconTheme.secondary).textSelection(.enabled)
            Text(
                profile == nil
                    ? "The API key is saved locally in ~/.config/falcon/credentials.json."
                    : "Leave the key empty to keep it. A new target requires its own key. "
                        + "Changes apply to new requests."
            ).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary).lineSpacing(FalconTheme.Space.small)
            if let error { Text(error).foregroundStyle(FalconTheme.danger).font(FalconTheme.detail) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(FalconButtonStyle())
                Button(saving ? "Saving…" : "Save connection") { Task { await save() } }.buttonStyle(
                    FalconButtonStyle(prominent: true)
                ).keyboardShortcut(.defaultAction).disabled(
                    saving || name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.isEmpty
                        || (profile == nil && key.isEmpty))
            }
        }.padding(FalconTheme.Space.sheet).frame(width: FalconTheme.Layout.sheetWidth).background(FalconTheme.canvas)
            .foregroundStyle(FalconTheme.ink).onAppear {
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
