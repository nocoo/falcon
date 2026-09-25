import AppKit
import SwiftUI

enum HarnessIcon: String, CaseIterable, Identifiable {
    case unknown, codex, claude, grok, gemini, opencode, hermes, openclaw, qwen
    case piAgent = "pi"

    var id: String { rawValue }
    var storedID: String? { self == .unknown ? nil : rawValue }
    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .hermes: "Hermes"
        case .piAgent: "Pi"
        case .openclaw: "OpenClaw"
        case .qwen: "Qwen Code"
        }
    }
    var isTemplate: Bool { [.codex, .grok, .opencode, .hermes].contains(self) }

    init(storedID: String?) { self = storedID.flatMap(Self.init(rawValue:)) ?? .unknown }
}

struct SourceAvatar: View {
    var iconID: String?
    var size: CGFloat = FalconTheme.Layout.avatar
    var framed = true
    private var icon: HarnessIcon { HarnessIcon(storedID: iconID) }

    var body: some View {
        Group {
            if icon == .piAgent {
                Text("π").font(.system(size: size * 0.66, weight: .semibold, design: .serif))
            } else if icon != .unknown, let image = FalconAssets.bundle.image(forResource: "Harness-" + icon.rawValue) {
                Image(nsImage: image).resizable().renderingMode(icon.isTemplate ? .template : .original).interpolation(
                    .high
                ).scaledToFit().padding(framed ? size * 0.18 : 0)
            } else {
                Image(systemName: "questionmark").font(.system(size: size * 0.48, weight: .medium))
            }
        }.foregroundStyle(FalconTheme.ink).frame(width: size, height: size).background(
            framed ? FalconTheme.inset : .clear, in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
        ).accessibilityHidden(true)
    }
}

struct HarnessIconPicker: View {
    @Binding var selection: HarnessIcon

    var body: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
            Text("Source icon").font(FalconTheme.label).foregroundStyle(FalconTheme.secondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: FalconTheme.Space.compact), count: 5),
                spacing: FalconTheme.Space.compact
            ) {
                ForEach(HarnessIcon.allCases) { icon in
                    Button {
                        selection = icon
                    } label: {
                        VStack(spacing: FalconTheme.Space.tight) {
                            SourceAvatar(iconID: icon.storedID, framed: false)
                            Text(icon.title).font(FalconTheme.caption).lineLimit(1)
                        }.frame(maxWidth: .infinity).frame(height: FalconTheme.Layout.iconChoiceHeight).background(
                            selection == icon ? FalconTheme.accentWash : FalconTheme.surface,
                            in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
                        ).overlay(alignment: .topTrailing) {
                            if selection == icon {
                                Image(systemName: "checkmark.circle.fill").font(FalconTheme.caption).foregroundStyle(
                                    FalconTheme.accent
                                ).padding(FalconTheme.Space.small)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(icon.title).accessibilityAddTraits(
                        selection == icon ? .isSelected : [])
                }
            }
        }
    }
}
