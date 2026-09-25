import SwiftUI

struct FalconButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        FalconButtonBody(configuration: configuration, prominent: prominent, compact: compact, selected: selected)
    }
}

private struct FalconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let compact: Bool
    let selected: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        configuration.label.font(FalconTheme.label).foregroundStyle(
            prominent
                ? FalconTheme.onAction
                : configuration.role == .destructive
                    ? FalconTheme.danger : selected ? FalconTheme.accent : FalconTheme.ink
        ).padding(.horizontal, compact ? FalconTheme.Space.compact : FalconTheme.Space.regular).frame(
            height: compact ? FalconTheme.Layout.compactControlHeight : FalconTheme.Layout.controlHeight
        ).background(
            prominent
                ? FalconTheme.action : selected || (hovered && enabled) ? FalconTheme.accentWash : FalconTheme.surface,
            in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control)
        ).overlay(
            RoundedRectangle(cornerRadius: FalconTheme.Radius.control).strokeBorder(
                prominent ? .clear : contrast == .increased ? FalconTheme.secondary : FalconTheme.line,
                lineWidth: FalconTheme.hairline)
        ).opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45).onHover { hovered = $0 }.animation(
            reduceMotion ? nil : FalconTheme.feedback, value: hovered)
    }
}

struct Surface<Content: View>: View {
    var inset: CGFloat = FalconTheme.Space.large
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        content.padding(inset).frame(maxWidth: .infinity, alignment: .leading).background(
            FalconTheme.surface, in: RoundedRectangle(cornerRadius: FalconTheme.Radius.card)
        ).overlay(
            RoundedRectangle(cornerRadius: FalconTheme.Radius.card).strokeBorder(
                contrast == .increased ? FalconTheme.secondary : FalconTheme.line, lineWidth: FalconTheme.hairline))
    }
}

struct Eyebrow: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(FalconTheme.caption).tracking(FalconTheme.labelTracking).foregroundStyle(
            FalconTheme.secondary)
    }
}

struct Pill: View {
    let text: String
    var color: Color = FalconTheme.accent
    var symbol: String?
    var body: some View {
        HStack(spacing: FalconTheme.Space.small) {
            if let symbol { Image(systemName: symbol).font(FalconTheme.caption) }
            Text(text).font(FalconTheme.caption)
        }.foregroundStyle(color).padding(.horizontal, FalconTheme.Space.compact).padding(
            .vertical, FalconTheme.Space.small
        ).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: FalconTheme.Radius.badge))
            .accessibilityElement(children: .combine)
    }
}

struct FalconMark: View {
    var size: CGFloat = FalconTheme.Layout.avatar
    var body: some View {
        if let image = FalconAssets.mark {
            Image(nsImage: image).resizable().renderingMode(.original).interpolation(.high).scaledToFit().frame(
                width: size, height: size
            ).accessibilityHidden(true)
        }
    }
}

struct PageHeading<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: FalconTheme.Space.large) {
            VStack(alignment: .leading, spacing: FalconTheme.Space.compact) {
                Text(title).font(FalconTheme.title).tracking(FalconTheme.titleTracking).accessibilityAddTraits(
                    .isHeader)
                Text(subtitle).font(FalconTheme.detail).foregroundStyle(FalconTheme.secondary)
            }
            Spacer(minLength: FalconTheme.Space.medium)
            actions.fixedSize()
        }
    }
}

struct QuietTexture: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Canvas { context, size in
            guard !reduceTransparency, contrast != .increased else { return }
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
