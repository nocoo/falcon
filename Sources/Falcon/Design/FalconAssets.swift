import AppKit

enum FalconAssets {
    #if SWIFT_PACKAGE
        static let bundle = Bundle.module
    #else
        static let bundle = Bundle.main
    #endif

    // Xcode combines PNG scale variants into TIFF; AppKit resolves both bundle formats.
    static var mark: NSImage? { bundle.image(forResource: "FalconMark") }

    static var menuBarMark: NSImage? {
        guard let image = bundle.image(forResource: "FalconMenu")?.copy() as? NSImage else { return nil }
        // MenuBarExtra reads native image properties rather than SwiftUI sizing modifiers.
        image.size = NSSize(width: FalconTheme.Layout.menuMark, height: FalconTheme.Layout.menuMark)
        image.isTemplate = true
        return image
    }
}
