import AppKit
import FalconCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var runtime: AppRuntime
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let error = runtime.startupError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(FalconTheme.warning)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("Settings") { model.page = .settings }
                    Button("Retry") { Task { await runtime.retryServer() } }
                }.buttonStyle(FalconButtonStyle(compact: true)).padding(12).background(FalconTheme.surface)
                Divider()
            }
            HStack(spacing: 0) {
                if !model.focusReview || model.page != .decisions {
                    sidebar.frame(width: 176)
                    Divider().overlay(FalconTheme.line)
                }
                switch model.page {
                case .decisions: decisions
                case .usage: UsageView(model: model)
                case .sources: SourcesView(model: model, port: runtime.port)
                case .connections: ConnectionsView(model: model, service: runtime.service)
                case .settings: SettingsView(model: model, runtime: runtime)
                }
            }
            if model.timeline != nil, model.page == .decisions { ReplayBar(model: model) }
        }.font(FalconTheme.body).foregroundStyle(FalconTheme.ink).background(FalconTheme.canvas).frame(
            minWidth: 1120, minHeight: 680
        ).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light).toolbar { toolbar }
            .toolbarBackground(FalconTheme.canvas, for: .windowToolbar).animation(
                reduceMotion ? nil : FalconTheme.motion, value: model.focusReview
            ).onChange(of: model.page) { _, _ in
                model.pauseReplay()
                Task { await model.refresh(reset: true) }
            }.onChange(of: model.hours) { _, _ in
                model.timeRange = nil
                Task { await model.refresh(reset: true) }
            }.onChange(of: model.sourceFilters) { _, _ in Task { await model.refresh(reset: true) } }.onChange(
                of: model.statusFilter
            ) { _, _ in Task { await model.refresh(reset: true) } }.onChange(of: model.reviewFilter) { _, _ in
                Task { await model.refresh(reset: true) }
            }.task(id: model.search) {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await model.refresh(reset: true)
            }.onChange(of: scenePhase) { _, phase in Task { await model.setActive(phase == .active) } }.task {
                await model.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
                    await model.refresh()
                    await runtime.refreshStatus()
                }
            }.alert(
                "Falcon",
                isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    private var decisions: some View {
        HStack(spacing: 0) {
            if !model.focusReview {
                RequestListView(model: model).frame(width: 292)
                Divider().overlay(FalconTheme.line)
            }
            Group {
                if !model.isActive {
                    ContentUnavailableView(
                        "Review paused", systemImage: "pause.circle",
                        description: Text("Return to Falcon to continue reviewing."))
                } else if let detail = model.detail, let presentation = model.presentation {
                    DecisionDetailView(model: model, detail: detail, presentation: presentation)
                } else if model.isLoading {
                    ProgressView("Loading decisions…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyWorkspace
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                FalconMark(size: 30)
                Text("Falcon").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(-0.5)
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 32)
            Eyebrow(title: "Workspace").padding(.horizontal, 20).padding(.bottom, 9)
            ForEach([WorkspacePage.decisions, .usage], id: \.self) { navigation($0) }
            Eyebrow(title: "Manage").padding(.horizontal, 20).padding(.top, 29).padding(.bottom, 9)
            ForEach([WorkspacePage.sources, .connections], id: \.self) { navigation($0) }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(runtime.isRunning ? FalconTheme.success : FalconTheme.tertiary).frame(
                        width: 6, height: 6)
                    Text(runtime.statusTitle).font(.system(size: 11, weight: .medium))
                }
                Text("127.0.0.1:\(String(runtime.port))").font(.system(size: 11, design: .monospaced)).foregroundStyle(
                    FalconTheme.secondary)
                Text("7-day local history").font(.system(size: 11)).foregroundStyle(FalconTheme.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                FalconTheme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 9)
            ).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(FalconTheme.line, lineWidth: 0.75)).padding(12)
            navigation(.settings).padding(.bottom, 14)
        }.background(FalconTheme.sidebar.overlay(QuietTexture()))
    }

    private func navigation(_ page: WorkspacePage) -> some View {
        Button {
            model.page = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(page.rawValue).font(.system(size: 12, weight: model.page == page ? .semibold : .medium))
                Spacer(minLength: 0)
                if page == .decisions, !model.requests.isEmpty {
                    Text(model.requests.count.formatted()).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(
                            FalconTheme.surface.opacity(0.7), in: Capsule())
                }
            }.foregroundStyle(model.page == page ? FalconTheme.accent : FalconTheme.secondary).padding(.horizontal, 11)
                .frame(height: 35).background(
                    model.page == page ? FalconTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7)
                ).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 3).accessibilityAddTraits(
            model.page == page ? .isSelected : [])
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 18) {
            FalconMark(size: 60)
            Text(model.profiles.isEmpty ? "A window into every decision." : "Ready for the first decision.").font(
                .system(size: 24, weight: .semibold)
            ).tracking(-0.5)
            Text(
                model.profiles.isEmpty
                    ? "Connect Jev, give each agent its own key,\nand see every input and decision in one place."
                    : "Requests sent through Falcon will appear here.\n"
                        + "Filter by source and time to review the full context."
            ).multilineTextAlignment(.center).lineSpacing(5).foregroundStyle(FalconTheme.secondary)
            Button(model.profiles.isEmpty ? "Connect to Jev" : "Manage sources") {
                model.page = model.profiles.isEmpty ? .connections : .sources
            }.buttonStyle(FalconButtonStyle(prominent: true)).padding(.top, 5)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                Text(model.page == .decisions ? "Decision workspace" : model.page.rawValue).font(
                    .system(size: 13, weight: .medium)
                ).foregroundStyle(FalconTheme.secondary)
                if model.isPreview { Pill(text: "Synthetic preview", color: FalconTheme.warning) }
            }.padding(.leading, 6)
        }.falconToolbar()
        ToolbarItemGroup(placement: .primaryAction) {
            if model.page == .decisions {
                if model.focusReview {
                    Menu {
                        Picker("Time range", selection: $model.hours) {
                            Text("Past hour").tag(1)
                            Text("Past 24 hours").tag(24)
                            Text("Past 7 days").tag(168)
                        }
                        Divider()
                        SourceFilterOptions(model: model)
                        Divider()
                        Button("Show all filters") { model.focusReview = false }
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease")
                    }
                    Button {
                        Task { await model.selectAdjacent(forward: false) }
                    } label: {
                        Image(systemName: "chevron.up")
                    }.help("Previous decision").accessibilityLabel("Previous decision")
                    Button {
                        Task { await model.selectAdjacent(forward: true) }
                    } label: {
                        Image(systemName: "chevron.down")
                    }.help("Next decision").accessibilityLabel("Next decision")
                }
                Button {
                    model.focusReview.toggle()
                } label: {
                    Label(
                        model.focusReview ? "Show navigation" : "Focus review",
                        systemImage: model.focusReview ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                }.buttonStyle(FalconButtonStyle()).keyboardShortcut("f", modifiers: [.command, .shift])
            }
            Button {
                Task { await runtime.togglePause() }
            } label: {
                Label(
                    runtime.isPaused ? "Resume service" : "Pause service",
                    systemImage: runtime.isPaused ? "play" : "pause")
            }.buttonStyle(FalconButtonStyle()).disabled(model.isPreview || runtime.service == nil)
        }.falconToolbar()
    }
}
