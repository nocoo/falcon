import AppKit
import Foundation

enum BrandAssetError: Error {
    case unreadableImage(String)
    case bitmapUnavailable
    case iconConversionFailed
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Sources/Falcon/Resources", isDirectory: true)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FalconBrand-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("Falcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func load(_ path: String) throws -> NSImage {
    guard let image = NSImage(contentsOf: root.appendingPathComponent(path)) else {
        throw BrandAssetError.unreadableImage(path)
    }
    return image
}

func png(_ image: NSImage, pixels: Int, inset: CGFloat = 0) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw BrandAssetError.bitmapUnavailable }
    let side = CGFloat(pixels)
    bitmap.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
    image.draw(
        in: NSRect(x: side * inset, y: side * inset, width: side * (1 - inset * 2), height: side * (1 - inset * 2)),
        from: .zero, operation: .copy, fraction: 1)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw BrandAssetError.bitmapUnavailable
    }
    return data
}

let foreground = try load("logo.png")
try png(foreground, pixels: 64).write(to: resources.appendingPathComponent("FalconMark.png"), options: .atomic)
try png(foreground, pixels: 128).write(to: resources.appendingPathComponent("FalconMark@2x.png"), options: .atomic)

let presentation = try load("assets/brand/icon-rounded.png")
for size in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try png(presentation, pixels: size * scale, inset: 100 / 1024).write(
            to: iconset.appendingPathComponent(name), options: .atomic)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", resources.appendingPathComponent("Falcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { throw BrandAssetError.iconConversionFailed }
print("Generated Falcon transparent marks and the native macOS icon.")
