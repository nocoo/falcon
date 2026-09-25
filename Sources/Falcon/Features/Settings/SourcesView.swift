import AppKit
import FalconCore
import SwiftUI

struct SourcesView: View {
    @Bindable var model: WorkspaceModel
    let port: Int
    @State private var editor: SourceEditorPresentation?
    @State private var presentedKey: PresentedKey?
    @State private var pendingSource: AgentSource?
    @State private var rotating = false
    @State private var confirming = false
    @State private var showArchived = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                PageHeading(title: "Sources", subtitle: "One key per agent. A clear trail for every decision.") {
                    Button {
                        editor = SourceEditorPresentation(source: nil)
                    } label: {
                        Label("Add source", systemImage: "plus")
                    }.buttonStyle(FalconButtonStyle(prominent: true)).disabled(
                        model.profiles.isEmpty || model.isPreview)
                }
                if model.profiles.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
                            Text("Add an upstream connection first.").font(FalconTheme.sectionTitle)
                            Text("Sources can share a connection or use different endpoints and credentials.")
                                .foregroundStyle(FalconTheme.secondary)
                            Button("Manage connections") { model.page = .connections }.buttonStyle(
                                FalconButtonStyle(prominent: true))
                        }
                    }
                } else if model.sources.isEmpty {
                    ContentUnavailableView(
                        "No sources yet", systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Create a source for Codex, Pi, or any local agent.")
                    ).frame(height: 220)
                }
                HStack {
                    Text("Activity in the past 24 hours").font(FalconTheme.detail).foregroundStyle(
                        FalconTheme.secondary)
                    Spacer()
                    Toggle("Show archived", isOn: $showArchived).toggleStyle(.checkbox).font(FalconTheme.detail)
                }
                ForEach(model.sources.filter { showArchived || !$0.archived }) { source in
                    Surface(inset: FalconTheme.Space.large) {
                        HStack(spacing: FalconTheme.Space.medium) {
                            Button {
                                editor = SourceEditorPresentation(source: source)
                            } label: {
                                SourceAvatar(iconID: source.iconID, size: FalconTheme.Layout.profileAvatar)
                            }.buttonStyle(.plain).help("Change source icon").accessibilityLabel(
                                "Edit \(source.name) icon"
                            ).disabled(model.isPreview)
                            VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
                                HStack(spacing: FalconTheme.Space.compact) {
                                    Text(source.name).font(FalconTheme.sectionTitle)
                                    Pill(
                                        text: source.archived ? "Archived" : source.enabled ? "Enabled" : "Disabled",
                                        color: source.enabled && !source.archived
                                            ? FalconTheme.success : FalconTheme.tertiary)
                                    Text(String(source.id.uuidString.prefix(6)).lowercased()).font(
                                        FalconTheme.monoSmall
                                    ).foregroundStyle(FalconTheme.tertiary)
                                }
                                HStack(spacing: FalconTheme.Space.compact) {
                                    Image(systemName: "arrow.up.right")
                                    Text(
                                        model.profiles.first { $0.id == source.profileID }?.name ?? "Missing connection"
                                    )
                                    Text("·").padding(.horizontal, FalconTheme.Space.small)
                                    if let key = model.keys.first(where: {
                                        $0.sourceID == source.id && $0.revokedAt == nil
                                    }) {
                                        Text("•••• \(key.suffix)").font(FalconTheme.mono)
                                    } else {
                                        Text(model.isPreview ? "Preview identity" : "No active key")
                                    }
                                }.font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
                            }
                            Spacer()
                            if let activity = model.usage.sources.first(where: { $0.id == source.id }) {
                                VStack(alignment: .trailing, spacing: FalconTheme.Space.compact) {
                                    Text(
                                        "\(activity.requests) requests · \(DecisionFormat.tokens(activity.totalTokens)) tokens"
                                    ).font(FalconTheme.detail)
                                    if let last = activity.lastReceivedAt {
                                        Text(last, style: .relative).font(FalconTheme.footnote).foregroundStyle(
                                            FalconTheme.secondary)
                                    }
                                }
                            }
                            Button("View decisions") {
                                model.sourceFilters = [source.id]
                                model.page = .decisions
                            }.buttonStyle(FalconButtonStyle())
                            Menu {
                                Button("Edit source") { editor = SourceEditorPresentation(source: source) }
                                Button("Rotate source key…") {
                                    pendingSource = source
                                    rotating = true
                                    confirming = true
                                }
                                Button("Revoke source key…", role: .destructive) {
                                    pendingSource = source
                                    rotating = false
                                    confirming = true
                                }
                                Divider()
                                Button(source.archived ? "Restore source" : "Archive source") {
                                    Task { await setArchived(source) }
                                }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 22)
                            }.menuStyle(.borderlessButton).fixedSize().disabled(model.isPreview)
                        }
                    }
                }
                Surface(inset: FalconTheme.Space.large) {
                    VStack(alignment: .leading, spacing: FalconTheme.Space.medium) {
                        Text("Connect an agent").font(FalconTheme.sectionTitle)
                        HStack(spacing: FalconTheme.Space.section) {
                            endpoint("HTTP API root", "http://127.0.0.1:\(port)")
                            endpoint("MCP endpoint", "http://127.0.0.1:\(port)/mcp")
                        }
                        Text(
                            "Set Authorization: Bearer <source key>. "
                                + "MCP clients must support Streamable HTTP with a fixed Authorization header."
                        ).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary).lineSpacing(
                            FalconTheme.Space.small)
                        Button("Copy MCP template") {
                            let template = """
                                {"mcpServers":{"falcon":{"url":"http://127.0.0.1:\(port)/mcp","headers":{"Authorization":"Bearer YOUR_SOURCE_KEY"}}}}
                                """
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(template, forType: .string)
                        }.buttonStyle(FalconButtonStyle())
                    }
                }
            }.padding(FalconTheme.Space.page).frame(maxWidth: FalconTheme.Layout.managementWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }.sheet(item: $editor) { SourceEditor(model: model, source: $0.source) }.sheet(
            item: $presentedKey, content: { key in OneTimeKeyView(issued: key.value) }
        ).confirmationDialog(
            rotating ? "Rotate this source key?" : "Revoke this source key?", isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(rotating ? "Rotate key" : "Revoke key", role: .destructive) { Task { await changeKey() } }
        } message: {
            Text(
                "The current key stops working immediately. Update the agent before its next request. "
                    + "Historical decisions remain available.")
        }.onAppear {
            if model.isPreview, CommandLine.arguments.contains("--source-editor") {
                editor = SourceEditorPresentation(
                    source: CommandLine.arguments.contains("--edit-source") ? model.sources.first : nil)
            }
        }
    }

    private func endpoint(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
            Eyebrow(title: title)
            Text(value).font(FalconTheme.mono).textSelection(.enabled)
        }
    }
    private func changeKey() async {
        guard let source = pendingSource, let configuration = model.configuration else { return }
        do {
            if rotating {
                presentedKey = PresentedKey(value: try await configuration.rotateKey(sourceID: source.id))
            } else {
                try await configuration.revokeKey(sourceID: source.id)
            }
            await model.refresh(reset: true)
        } catch { model.errorMessage = error.localizedDescription }
    }
    private func setArchived(_ source: AgentSource) async {
        guard let configuration = model.configuration else { return }
        var updated = source
        updated.archived.toggle()
        do {
            try await configuration.saveSource(updated)
            await model.refresh(reset: true)
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private struct SourceEditorPresentation: Identifiable {
    let id = UUID()
    let source: AgentSource?
}

private struct PresentedKey: Identifiable {
    let value: IssuedSourceKey
    var id: UUID { value.key.id }
}

private struct SourceEditor: View {
    let model: WorkspaceModel
    let source: AgentSource?
    @State private var name = ""
    @State private var profileID: UUID?
    @State private var enabled = true
    @State private var icon: HarnessIcon = .unknown
    @State private var saving = false
    @State private var error: String?
    @State private var issued: IssuedSourceKey?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let issued {
            OneTimeKeyView(issued: issued)
        } else {
            VStack(alignment: .leading, spacing: FalconTheme.Space.section) {
                Text(source == nil ? "Add source" : "Edit source").font(FalconTheme.title).tracking(
                    FalconTheme.titleTracking)
                Form {
                    TextField("Source name", text: $name)
                    Picker("Connection", selection: $profileID) {
                        Text("Select a connection").tag(nil as UUID?)
                        ForEach(model.profiles.filter(\.enabled)) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    if source != nil { Toggle("Enabled", isOn: $enabled) }
                }.textFieldStyle(.roundedBorder)
                HarnessIconPicker(selection: $icon)
                Text(
                    "Each source gets its own local key. "
                        + "Multiple sources can route to the same connection without sharing their identity."
                ).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary).lineSpacing(FalconTheme.Space.small)
                if let error { Text(error).font(FalconTheme.detail).foregroundStyle(FalconTheme.danger) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(FalconButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(saving ? "Saving…" : source == nil ? "Create source" : "Save changes") {
                        Task { await save() }
                    }.buttonStyle(FalconButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(
                        saving || name.trimmingCharacters(in: .whitespaces).isEmpty || profileID == nil)
                }
            }.padding(FalconTheme.Space.sheet).frame(width: FalconTheme.Layout.sheetWidth).background(
                FalconTheme.canvas
            ).foregroundStyle(FalconTheme.ink).onAppear {
                name = source?.name ?? ""
                profileID = source?.profileID ?? model.profiles.first?.id
                enabled = source?.enabled ?? true
                icon = HarnessIcon(storedID: source?.iconID)
            }
        }
    }
    private func save() async {
        guard let configuration = model.configuration, let profileID else { return }
        saving = true
        defer { saving = false }
        do {
            if var source {
                source.name = name
                source.profileID = profileID
                source.enabled = enabled
                source.iconID = icon.storedID
                try await configuration.saveSource(source)
                dismiss()
            } else {
                issued = try await configuration.createSource(name: name, profileID: profileID, iconID: icon.storedID)
            }
            await model.refresh(reset: true)
        } catch { self.error = error.localizedDescription }
    }
}

private struct OneTimeKeyView: View {
    let issued: IssuedSourceKey
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.large) {
            Image(systemName: "key.horizontal").font(FalconTheme.featureSymbol).foregroundStyle(FalconTheme.accent)
            Text("\(issued.source.name) is ready").font(FalconTheme.title).tracking(FalconTheme.titleTracking)
            Text("Save this key now. Falcon only shows it once.").foregroundStyle(FalconTheme.secondary)
            Text(issued.token).font(FalconTheme.mono).textSelection(.enabled).padding(FalconTheme.Space.medium).frame(
                maxWidth: .infinity, alignment: .leading
            ).background(FalconTheme.inset, in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control))
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issued.token, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy key", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(FalconButtonStyle())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(FalconButtonStyle(prominent: true)).keyboardShortcut(
                    .defaultAction)
            }
        }.padding(FalconTheme.Space.sheet).frame(width: FalconTheme.Layout.sheetWidth).background(FalconTheme.canvas)
            .foregroundStyle(FalconTheme.ink)
    }
}
