import AppKit
import SwiftUI

enum FalconTheme {
    static let canvas = adaptive("canvas", light: 0xF5F6FA, dark: 0x11151F)
    static let sidebar = adaptive("sidebar", light: 0xEDF0F6, dark: 0x171D2A)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x1D2433)
    static let reader = adaptive("reader", light: 0xFAFBFD, dark: 0x181F2D)
    static let inset = adaptive("inset", light: 0xF1F3F8, dark: 0x151B27)
    static let ink = adaptive("ink", light: 0x293043, dark: 0xE9EDF5)
    static let secondary = adaptive("secondary", light: 0x556277, dark: 0xA7B1C6)
    static let tertiary = adaptive("tertiary", light: 0x5E6A7D, dark: 0x95A2BA)
    static let accent = adaptive("accent", light: 0x515677, dark: 0xB8C6EC)
    static let onAccent = adaptive("onAccent", light: 0xFFFFFF, dark: 0x192239)
    static let accentWash = adaptive("accentWash", light: 0xE9ECF5, dark: 0x2A344D)
    static let success = adaptive("success", light: 0x256B52, dark: 0x8AD2AF)
    static let warning = adaptive("warning", light: 0x86550A, dark: 0xE8BD70)
    static let danger = adaptive("danger", light: 0xB13B3B, dark: 0xFFAAA4)
    static let line = adaptive("line", light: 0xDCE1EB, dark: 0x323D52)

    enum Space {
        static let micro: CGFloat = 2
        static let small: CGFloat = 4
        static let tight: CGFloat = 6
        static let compact: CGFloat = 8
        static let regular: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 20
        static let section: CGFloat = 24
        static let sheet: CGFloat = 28
        static let page: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 4
        static let badge: CGFloat = 5
        static let control: CGFloat = 8
        static let card: CGFloat = 12
    }

    enum Layout {
        static let sidebarWidth: CGFloat = 176 * 1.1
        static let requestListWidth: CGFloat = 292
        static let minimumWidth: CGFloat = 1120
        static let minimumHeight: CGFloat = 680
        static let defaultWidth: CGFloat = 1600
        static let defaultHeight: CGFloat = 1000
        static let compactHeight: CGFloat = 720
        static let brandHeight: CGFloat = 84
        static let navigationHeight: CGFloat = 36
        static let controlHeight: CGFloat = 32
        static let compactControlHeight: CGFloat = 28
        static let modeSwitchWidth: CGFloat = 180
        static let rangeSwitchWidth: CGFloat = 220
        static let reviewBarHeight: CGFloat = 48
        static let brandMark: CGFloat = 44
        static let emptyMark: CGFloat = 64
        static let menuMark: CGFloat = 18
        static let avatar: CGFloat = 28
        static let detailAvatar: CGFloat = 36
        static let profileAvatar: CGFloat = 40
        static let pageWidth: CGFloat = 1400
        static let managementWidth: CGFloat = 1150
        static let settingsWidth: CGFloat = 1080
        static let sheetWidth: CGFloat = 520
    }

    static let hairline: CGFloat = 0.75
    static let titleTracking: CGFloat = -0.5
    static let labelTracking: CGFloat = 0.8
    static let codePointSize: CGFloat = 12
    static let motion = Animation.easeInOut(duration: 0.24)
    static let feedback = Animation.easeOut(duration: 0.14)
    static let body = Font.system(size: 13)
    static let emphasis = Font.system(size: 13, weight: .semibold)
    static let detail = Font.system(size: 12)
    static let label = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
    static let footnote = Font.system(size: 11)
    static let title = Font.system(size: 22, weight: .semibold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let brand = Font.system(size: 21, weight: .semibold, design: .rounded)
    static let metric = Font.system(size: 28, weight: .medium, design: .rounded)
    static let resultValue = Font.system(size: 24, weight: .medium, design: .rounded)
    static let compactValue = Font.system(size: 18, weight: .medium, design: .rounded)
    static let symbol = Font.system(size: 22)
    static let featureSymbol = Font.system(size: 28)
    static let mono = Font.system(size: codePointSize, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoValue = Font.system(size: codePointSize, weight: .medium, design: .monospaced)
    static let monoTitle = Font.system(size: 13, weight: .semibold, design: .monospaced)

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
