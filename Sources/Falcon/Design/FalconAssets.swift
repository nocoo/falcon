import AppKit

enum FalconAssets {
    #if SWIFT_PACKAGE
        static let bundle = Bundle.module
    #else
        static let bundle = Bundle.main
    #endif

    // Xcode combines PNG scale variants into TIFF; AppKit resolves both bundle formats.
    static var mark: NSImage? { bundle.image(forResource: "FalconMark") }
}
