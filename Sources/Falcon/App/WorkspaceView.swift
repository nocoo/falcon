import AppKit
import FalconCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var runtime: AppRuntime
    @AppStorage("appearance") private var appearance = "system"
    @State private var hoveredPage: WorkspacePage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let error = runtime.startupError {
                HStack(spacing: FalconTheme.Space.regular) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(FalconTheme.warning)
                    Text(error).font(FalconTheme.detail).textSelection(.enabled)
                    Spacer()
                    Button("Settings") { model.page = .settings }
                    Button("Retry") { Task { await runtime.retryServer() } }
                }.buttonStyle(FalconButtonStyle(compact: true)).padding(FalconTheme.Space.regular).background(
                    FalconTheme.surface)
                Divider()
            }
            HStack(spacing: 0) {
                if !model.focusReview || model.page != .decisions {
                    sidebar.frame(width: FalconTheme.Layout.sidebarWidth)
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
        }.font(FalconTheme.body).foregroundStyle(FalconTheme.ink).tint(FalconTheme.accent).background(
            FalconTheme.canvas
        ).frame(minWidth: FalconTheme.Layout.minimumWidth, minHeight: FalconTheme.Layout.minimumHeight)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light).toolbar {
                toolbar
            }.toolbarBackground(FalconTheme.canvas, for: .windowToolbar).animation(
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
                RequestListView(model: model).frame(width: FalconTheme.Layout.requestListWidth)
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
            HStack(spacing: FalconTheme.Space.regular) {
                FalconMark(size: FalconTheme.Layout.brandMark)
                VStack(alignment: .leading, spacing: FalconTheme.Space.micro) {
                    Text("Falcon").font(FalconTheme.brand).tracking(FalconTheme.titleTracking)
                    Text("Local decisions").font(FalconTheme.caption).foregroundStyle(FalconTheme.secondary)
                }
            }.padding(.horizontal, FalconTheme.Space.large).frame(height: FalconTheme.Layout.brandHeight)
            Eyebrow(title: "Workspace").padding(.horizontal, FalconTheme.Space.large).padding(
                .bottom, FalconTheme.Space.compact)
            ForEach([WorkspacePage.decisions, .usage], id: \.self) { navigation($0) }
            Eyebrow(title: "Manage").padding(.horizontal, FalconTheme.Space.large).padding(
                .top, FalconTheme.Space.sheet
            ).padding(.bottom, FalconTheme.Space.compact)
            ForEach([WorkspacePage.sources, .connections], id: \.self) { navigation($0) }
            Spacer()
            VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
                HStack(spacing: FalconTheme.Space.tight) {
                    Circle().fill(runtime.isRunning ? FalconTheme.success : FalconTheme.tertiary).frame(
                        width: 6, height: 6)
                    Text(runtime.statusTitle).font(FalconTheme.caption)
                }
                Text("127.0.0.1:\(String(runtime.port))").font(FalconTheme.monoSmall).foregroundStyle(
                    FalconTheme.secondary)
                Text("7-day local history").font(FalconTheme.footnote).foregroundStyle(FalconTheme.secondary)
            }.padding(FalconTheme.Space.regular).frame(maxWidth: .infinity, alignment: .leading).background(
                FalconTheme.reader, in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
            ).overlay(
                RoundedRectangle(cornerRadius: FalconTheme.Radius.control).strokeBorder(
                    FalconTheme.line, lineWidth: FalconTheme.hairline)
            ).padding(FalconTheme.Space.regular)
            navigation(.settings).padding(.bottom, FalconTheme.Space.medium)
        }.background(FalconTheme.sidebar.overlay(QuietTexture()))
    }

    private func navigation(_ page: WorkspacePage) -> some View {
        Button {
            model.page = page
        } label: {
            HStack(spacing: FalconTheme.Space.compact) {
                Image(systemName: page.symbol).font(FalconTheme.sectionTitle).frame(width: FalconTheme.Layout.menuMark)
                Text(page.rawValue).font(FalconTheme.label.weight(model.page == page ? .semibold : .medium))
                Spacer(minLength: 0)
                if page == .decisions, !model.requests.isEmpty {
                    Text(model.requests.count.formatted()).font(FalconTheme.monoSmall).padding(
                        .horizontal, FalconTheme.Space.tight
                    ).padding(.vertical, FalconTheme.Space.micro).background(FalconTheme.inset, in: Capsule())
                }
            }.foregroundStyle(model.page == page ? FalconTheme.accent : FalconTheme.secondary).padding(
                .horizontal, FalconTheme.Space.regular
            ).frame(height: FalconTheme.Layout.navigationHeight).background(
                model.page == page ? FalconTheme.surface : hoveredPage == page ? FalconTheme.accentWash : .clear,
                in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
            ).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hoveredPage = $0 ? page : nil }.animation(
            reduceMotion ? nil : FalconTheme.feedback, value: hoveredPage
        ).padding(.horizontal, FalconTheme.Space.regular).padding(.bottom, FalconTheme.Space.small)
            .accessibilityAddTraits(model.page == page ? .isSelected : [])
    }

    private var emptyWorkspace: some View {
        VStack(spacing: FalconTheme.Space.large) {
            FalconMark(size: FalconTheme.Layout.emptyMark)
            Text(model.profiles.isEmpty ? "A window into every decision." : "Ready for the first decision.").font(
                FalconTheme.title
            ).tracking(FalconTheme.titleTracking)
            Text(
                model.profiles.isEmpty
                    ? "Connect Jev, give each agent its own key,\nand see every input and decision in one place."
                    : "Requests sent through Falcon will appear here.\n"
                        + "Filter by source and time to review the full context."
            ).multilineTextAlignment(.center).lineSpacing(FalconTheme.Space.small).foregroundStyle(
                FalconTheme.secondary)
            Button(model.profiles.isEmpty ? "Connect to Jev" : "Manage sources") {
                model.page = model.profiles.isEmpty ? .connections : .sources
            }.buttonStyle(FalconButtonStyle(prominent: true)).padding(.top, FalconTheme.Space.tight)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: FalconTheme.Space.compact) {
                Text("Falcon").font(FalconTheme.emphasis)
                Image(systemName: "chevron.right").font(FalconTheme.caption).foregroundStyle(FalconTheme.tertiary)
                Text(model.page.rawValue).font(FalconTheme.label).foregroundStyle(FalconTheme.secondary)
            }.padding(.leading, FalconTheme.Space.tight)
        }.falconToolbar()
        ToolbarItem(placement: .principal) {
            Pill(
                text: model.isPreview ? "Synthetic preview" : runtime.statusTitle,
                color: model.isPreview
                    ? FalconTheme.warning : runtime.isRunning ? FalconTheme.success : FalconTheme.secondary,
                symbol: model.isPreview ? "sparkle" : runtime.isRunning ? "checkmark.circle" : "pause.circle")
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
                }.labelStyle(.titleAndIcon).buttonStyle(FalconButtonStyle()).keyboardShortcut(
                    "f", modifiers: [.command, .shift])
            }
            Button {
                Task { await runtime.togglePause() }
            } label: {
                Label(
                    runtime.isPaused ? "Resume service" : "Pause service",
                    systemImage: runtime.isPaused ? "play" : "pause")
            }.labelStyle(.titleAndIcon).buttonStyle(FalconButtonStyle()).disabled(
                model.isPreview || runtime.service == nil)
        }.falconToolbar()
    }
}
