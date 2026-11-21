import AppKit

// Draw the orbital dial at each macOS icon resolution.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon rendering failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
        let surface = NSBezierPath(roundedRect: NSRect(x: 30, y: 29, width: 452, height: 454), xRadius: 108, yRadius: 108)
        NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.23, blue: 0.23, alpha: 1),
                   ending: NSColor(srgbRed: 0.045, green: 0.075, blue: 0.09, alpha: 1))!.draw(in: surface, angle: -75)
        let mint = NSColor(srgbRed: 0.61, green: 0.91, blue: 0.80, alpha: 1)
        cg.translateBy(x: 256, y: 256)
        cg.rotate(by: .pi / 5.0)
        mint.setStroke()
        let orbit = NSBezierPath(ovalIn: NSRect(x: -161, y: -58, width: 322, height: 116))
        orbit.lineWidth = 12
        orbit.stroke()
        let dial = NSBezierPath(ovalIn: NSRect(x: -97, y: -97, width: 194, height: 194))
        dial.lineWidth = 14
        dial.stroke()
        mint.setFill()
        NSBezierPath(ovalIn: NSRect(x: -16, y: -16, width: 32, height: 32)).fill()
        NSColor(srgbRed: 1, green: 0.64, blue: 0.46, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 133, y: -19, width: 38, height: 38)).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
