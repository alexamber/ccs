import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let artwork = URL(fileURLWithPath: CommandLine.arguments[2])
guard let unicorn = NSImage(contentsOf: artwork) else { throw CocoaError(.fileReadCorruptFile) }
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(x: 62, y: 62, width: 900, height: 900)
        let path = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(srgbRed: 0.26, green: 0.23, blue: 0.54, alpha: 1), ending: NSColor(srgbRed: 0.45, green: 0.36, blue: 0.83, alpha: 1))!.draw(in: path, angle: 65)
        NSGraphicsContext.current?.imageInterpolation = .high
        unicorn.draw(in: NSRect(x: 112, y: 112, width: 800, height: 800),
                     from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
