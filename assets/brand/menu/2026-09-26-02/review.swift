import AppKit

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let previous = NSImage(
    contentsOf: directory.deletingLastPathComponent().appendingPathComponent("2026-09-26-01/template.png"))!
let candidate = NSImage(contentsOf: directory.appendingPathComponent("template.png"))!
let canvas = NSImage(size: NSSize(width: 900, height: 380))
canvas.lockFocus()
for theme in 0...1 {
    let origin = CGFloat(theme * 450)
    let ink = theme == 0 ? NSColor.black : NSColor.white
    (theme == 0 ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
    NSRect(x: origin, y: 0, width: 450, height: 380).fill()
    for (column, source) in [previous, candidate].enumerated() {
        let x = origin + CGFloat(column * 210) + 20
        let mark = source.copy() as! NSImage
        mark.lockFocus()
        ink.setFill()
        NSRect(origin: .zero, size: mark.size).fill(using: .sourceAtop)
        mark.unlockFocus()
        mark.draw(in: NSRect(x: x, y: 160, width: 180, height: 180))
        mark.draw(in: NSRect(x: x + 40, y: 105, width: 18, height: 18))
        mark.draw(in: NSRect(x: x + 100, y: 96, width: 36, height: 36))
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: ink]
        (column == 0 ? "Current" : "Rounded / +10%" as NSString).draw(
            at: NSPoint(x: x + 20, y: 55), withAttributes: style)
        ("18 pt       2x view" as NSString).draw(at: NSPoint(x: x + 15, y: 25), withAttributes: style)
    }
}
canvas.unlockFocus()
let bitmap = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("review.png"))
