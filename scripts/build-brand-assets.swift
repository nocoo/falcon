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
    let available = side * (1 - inset * 2)
    let scale = available / max(image.size.width, image.size.height)
    let width = image.size.width * scale
    let height = image.size.height * scale
    image.draw(
        in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height), from: .zero,
        operation: .copy, fraction: 1)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw BrandAssetError.bitmapUnavailable
    }
    return data
}

let foreground = try load("logo.png")
try png(foreground, pixels: 64).write(to: resources.appendingPathComponent("FalconMark.png"), options: .atomic)
try png(foreground, pixels: 128).write(to: resources.appendingPathComponent("FalconMark@2x.png"), options: .atomic)

func menuTemplate() throws -> NSImage {
    let artwork = try load("assets/brand/menu/2026-09-26-01/template.svg")
    let source = try NSBitmapImageRep(data: png(artwork, pixels: 720))
    guard let source, let sourceImage = source.cgImage,
        let mask = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: source.pixelsWide * 4, bitsPerPixel: 32), let pixels = mask.bitmapData,
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: pixels, width: source.pixelsWide, height: source.pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: mask.bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    else { throw BrandAssetError.bitmapUnavailable }
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh))
    for y in 0..<source.pixelsHigh {
        for x in 0..<source.pixelsWide {
            let offset = y * mask.bytesPerRow + x * 4
            let luminance =
                (Double(pixels[offset]) * 0.2126 + Double(pixels[offset + 1]) * 0.7152 + Double(pixels[offset + 2])
                    * 0.0722) / 255
            let alpha = (1 - luminance) * Double(pixels[offset + 3]) / 255
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = UInt8((alpha * 255).rounded())
        }
    }
    guard let template = mask.cgImage else { throw BrandAssetError.bitmapUnavailable }
    return NSImage(cgImage: template, size: artwork.size)
}

let menu = try menuTemplate()
try png(menu, pixels: 18, inset: 1 / 18).write(to: resources.appendingPathComponent("FalconMenu.png"), options: .atomic)
try png(menu, pixels: 36, inset: 1 / 18).write(
    to: resources.appendingPathComponent("FalconMenu@2x.png"), options: .atomic)
try png(menu, pixels: 512, inset: 1 / 18).write(
    to: root.appendingPathComponent("assets/brand/menu/2026-09-26-01/template.png"), options: .atomic)

let harnessDirectory = root.appendingPathComponent("assets/harness/originals", isDirectory: true)
for url in try FileManager.default.contentsOfDirectory(at: harnessDirectory, includingPropertiesForKeys: nil)
where url.pathExtension == "svg" {
    let name = "Harness-" + url.deletingPathExtension().lastPathComponent
    let path =
        url.lastPathComponent == "hermes.svg"
        ? "assets/harness/prepared/hermes.png" : "assets/harness/originals/" + url.lastPathComponent
    let source = try load(path)
    try png(source, pixels: 40).write(to: resources.appendingPathComponent(name + ".png"), options: .atomic)
    try png(source, pixels: 80).write(to: resources.appendingPathComponent(name + "@2x.png"), options: .atomic)
}

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
print("Generated Falcon marks, menu-bar template, harness icons, and native macOS icon.")
