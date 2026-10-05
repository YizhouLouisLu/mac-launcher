// Generates the app icon as an .iconset directory.
//
// The icon is drawn from code with AppKit rather than committed as a binary asset, so
// it stays in sync with the SF Symbol used by the status item and can be regenerated on
// any machine:  ./build/make-icon build/AppIcon.iconset && iconutil -c icns ...
//
// Drawing goes into an explicit NSBitmapImageRep graphics context. An earlier version
// used NSImage.lockFocus + tiffRepresentation, which fails with
// "CGImageDestinationFinalize failed for output type 'public.tiff'" when run headless.
//
// Usage: make-icon <output-directory>

import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"

// The sizes `iconutil` expects for a complete macOS iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixels,
                                        pixelsHigh: pixels,
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0) else { return nil }

    let side = CGFloat(pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // macOS app icons leave a small margin and use a squircle-like corner radius.
    let margin = side * 0.055
    let plate = NSRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    let radius = plate.width * 0.2237
    NSColor.systemBlue.setFill()
    NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()

    if let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
        let glyphSide = plate.width * 0.60
        let configuration = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let tinted = symbol.withSymbolConfiguration(configuration) {
            // SF Symbols carry visual padding, so the box is slightly larger than the glyph.
            let box = glyphSide * 1.15
            tinted.draw(in: NSRect(x: plate.midX - box / 2,
                                   y: plate.midY - box / 2,
                                   width: box,
                                   height: box),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

for variant in variants {
    guard let png = drawIcon(pixels: variant.pixels) else {
        FileHandle.standardError.write("failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(variant.name).png")
    do {
        try png.write(to: url)
        print("wrote \(variant.name).png (\(variant.pixels)px)")
    } catch {
        FileHandle.standardError.write("failed to write \(url.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
