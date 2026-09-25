import AppKit
import SwiftUI

enum FalconTheme {
    static let canvas = adaptive("canvas", light: 0xF5F6F7, dark: 0x10151C)
    static let sidebar = adaptive("sidebar", light: 0xEBEFF1, dark: 0x151C25)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x19212C)
    static let inset = adaptive("inset", light: 0xF3F6F7, dark: 0x131A23)
    static let ink = adaptive("ink", light: 0x223342, dark: 0xE4EBF3)
    static let secondary = adaptive("secondary", light: 0x687C88, dark: 0x95A7B9)
    static let tertiary = adaptive("tertiary", light: 0x81939D, dark: 0x728699)
    static let accent = adaptive("accent", light: 0x236C7C, dark: 0x83C7D3)
    static let accentWash = adaptive("accentWash", light: 0xE5F0F2, dark: 0x213842)
    static let success = adaptive("success", light: 0x267B62, dark: 0x78C9A5)
    static let warning = adaptive("warning", light: 0x9B681F, dark: 0xE3B572)
    static let danger = adaptive("danger", light: 0xB64D47, dark: 0xF09B94)
    static let line = adaptive("line", light: 0xDCE3E7, dark: 0x2B3845)
    static let insetMedium: CGFloat = 20
    static let radius: CGFloat = 12
    static let controlHeight: CGFloat = 30
    static let motion = Animation.easeInOut(duration: 0.24)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 12, design: .monospaced)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: NSColor.Name("Falcon.\(name)")) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
            })
    }
}

struct FalconButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        FalconButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
}

private struct FalconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let compact: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(
            prominent ? FalconTheme.surface : FalconTheme.ink
        ).padding(.horizontal, compact ? 8 : 12).frame(height: FalconTheme.controlHeight).background(
            prominent ? FalconTheme.accent : hovered ? FalconTheme.accentWash : FalconTheme.surface,
            in: RoundedRectangle(cornerRadius: 7)
        ).overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(prominent ? .clear : FalconTheme.line, lineWidth: 0.75)
        ).opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45).onHover { hovered = $0 }
    }
}

struct Surface<Content: View>: View {
    var inset: CGFloat = FalconTheme.insetMedium
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(inset).frame(maxWidth: .infinity, alignment: .leading).background(
            FalconTheme.surface, in: RoundedRectangle(cornerRadius: FalconTheme.radius)
        ).overlay(RoundedRectangle(cornerRadius: FalconTheme.radius).strokeBorder(FalconTheme.line, lineWidth: 0.75))
    }
}

struct Eyebrow: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(FalconTheme.caption).tracking(1.2).foregroundStyle(FalconTheme.secondary)
    }
}

struct Pill: View {
    let text: String
    var color: Color = FalconTheme.accent
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4).background(
            color.opacity(0.09), in: RoundedRectangle(cornerRadius: 5)
        ).accessibilityElement(children: .combine)
    }
}

struct FalconMark: View {
    var size: CGFloat = 28
    var body: some View {
        if let image = FalconAssets.mark {
            Image(nsImage: image).resizable().renderingMode(.original).interpolation(.high).scaledToFit().frame(
                width: size, height: size
            ).accessibilityHidden(true)
        }
    }
}

struct SourceAvatar: View {
    let name: String
    var size: CGFloat = 28
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(FalconTheme.accent).frame(width: size, height: size).background(
                FalconTheme.accentWash, in: RoundedRectangle(cornerRadius: size * 0.3)
            ).accessibilityHidden(true)
    }
}

struct QuietTexture: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Canvas { context, size in
            guard !reduceTransparency else { return }
            for x in stride(from: 0.0, to: size.width, by: 8) {
                for y in stride(from: 0.0, to: size.height, by: 8) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 0.6, height: 0.6)),
                        with: .color(FalconTheme.secondary.opacity(0.12)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder func falconToolbar() -> some ToolbarContent {
        if #available(macOS 26.0, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}
