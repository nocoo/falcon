import AppKit
import SwiftUI

enum FalconTheme {
    static let canvas = adaptive("canvas", light: 0xF6F9FA, dark: 0x131A20)
    static let sidebar = adaptive("sidebar", light: 0xEBF4F8, dark: 0x18252F)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x1D2A34)
    static let reader = adaptive("reader", light: 0xFAFDFE, dark: 0x17222B)
    static let inset = adaptive("inset", light: 0xEFF5F7, dark: 0x14212A)
    static let ink = adaptive("ink", light: 0x203340, dark: 0xEDF7FA)
    static let secondary = adaptive("secondary", light: 0x506674, dark: 0xADC1CD)
    static let tertiary = adaptive("tertiary", light: 0x596D79, dark: 0x9EB3C0)
    static let accent = adaptive("accent", light: 0x006D96, dark: 0x63CEF2)
    static let action = adaptive("action", light: 0x006D96, dark: 0x007DA9)
    static let onAction = Color.white
    static let accentWash = adaptive("accentWash", light: 0xDCF3FC, dark: 0x173C4E)
    static let success = adaptive("success", light: 0x007C46, dark: 0x38E8A1)
    static let warning = adaptive("warning", light: 0x996000, dark: 0xFFD43B)
    static let flag = adaptive("flag", light: 0xBD7A1F, dark: 0xFFCC66)
    static let danger = adaptive("danger", light: 0xCF1943, dark: 0xFF5574)
    static let live = adaptive("live", light: 0x00D68A, dark: 0x38F5AD)
    static let line = adaptive("line", light: 0xDCE7ED, dark: 0x31434F)

    enum Candy {
        static let blue = adaptive("candy.blue", light: 0x57C7EF, dark: 0x63CEF2)
        static let green = adaptive("candy.green", light: 0x26D995, dark: 0x38E8A1)
        static let yellow = adaptive("candy.yellow", light: 0xFFE16B, dark: 0xFFE889)
        static let pink = adaptive("candy.pink", light: 0xFF5574, dark: 0xFF718B)
        static let white = adaptive("candy.white", light: 0xFFFFFF, dark: 0xEDF7FA)
    }

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
        static let requestRowHeight: CGFloat = 60
        static let requestStatusMark: CGFloat = 12
        static let requestIcon: CGFloat = 16
        static let minimumWidth: CGFloat = 1120
        static let minimumHeight: CGFloat = 680
        static let defaultWidth: CGFloat = 1600
        static let defaultHeight: CGFloat = 1000
        static let compactHeight: CGFloat = 720
        static let brandHeight: CGFloat = 72
        static let navigationHeight: CGFloat = 36
        static let controlHeight: CGFloat = 32
        static let compactControlHeight: CGFloat = 28
        static let modeSwitchWidth: CGFloat = 180
        static let rangeSwitchWidth: CGFloat = 220
        static let reviewBarHeight: CGFloat = 48
        static let brandMark: CGFloat = 44
        static let brandMarkWidth: CGFloat = 32
        static let statusLight: CGFloat = 7
        static let emptyMark: CGFloat = 64
        static let menuMark: CGFloat = 18
        static let avatar: CGFloat = 28
        static let detailAvatar: CGFloat = 36
        static let profileAvatar: CGFloat = 40
        static let iconChoiceHeight: CGFloat = 66
        static let pageWidth: CGFloat = 1400
        static let managementWidth: CGFloat = 1150
        static let settingsWidth: CGFloat = 1080
        static let sheetWidth: CGFloat = 520
        static let notePopoverWidth: CGFloat = 360
        static let noteEditorHeight: CGFloat = 120
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
    static let brand = Font.system(size: 18, weight: .semibold, design: .rounded)
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
