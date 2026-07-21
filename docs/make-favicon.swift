#!/usr/bin/env swift
// Render the Loudini mark to the two raster icons the inline SVG favicon can't cover:
//
//   docs/apple-touch-icon.png  180x180  iOS "Add to Home Screen" / Safari bookmarks,
//                                       which ignore SVG favicons entirely
//   docs/favicon-32.png         32x32   fallback for Safari older than 16.4, which
//                                       shows a generic globe for an SVG favicon
//
// Same shape as docs/make-og.swift and menubar/make-appicon.swift: draw into an
// NSBitmapImageRep, write a PNG. Geometry is copied from the inline SVG in
// docs/index.html (viewBox 0 0 1024 1024) and scaled, so all three stay one mark.
//
//   swift docs/make-favicon.swift
import AppKit

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// The four level bars, in SVG user units: x, y (from the TOP), width, height.
let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (182, 371, 120, 282), (362, 202, 120, 620), (542, 286, 120, 451), (722, 385, 120, 254),
]

func render(_ side: CGFloat, to url: URL) {
    let s = side / 1024   // SVG user units -> pixels
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side),
                                     pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("bitmap ctx failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // AppKit's origin is bottom-left, the SVG's is top-left — flip y as we go.
    func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: (1024 - top - h) * s, width: w * s, height: h * s)
    }

    // Rounded-square backdrop. The SVG uses a radial gradient; two stops of it read
    // the same at favicon sizes and keep this script short.
    let bg = NSBezierPath(roundedRect: rect(51, 51, 922, 922),
                          xRadius: 207 * s, yRadius: 207 * s)
    bg.addClip()
    NSGradient(colors: [rgb(0x1B2054), rgb(0x0E1232), rgb(0x07091B)])?
        .draw(in: rect(51, 51, 922, 922), angle: -60)

    // The bars share ONE gradient across the whole group (as in the SVG), so each bar
    // shows its own slice of pink -> violet -> cyan rather than repeating the ramp.
    let ramp = NSGradient(colors: [rgb(0xFF3CAC), rgb(0x865DFF), rgb(0x20D9FF)])
    let group = NSBezierPath()
    for (x, top, w, h) in bars {
        group.append(NSBezierPath(roundedRect: rect(x, top, w, h), xRadius: 55 * s, yRadius: 55 * s))
    }
    NSGraphicsContext.saveGraphicsState()
    group.addClip()
    ramp?.draw(in: rect(182, 202, 660, 620), angle: 42)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
    do { try png.write(to: url) } catch { fatalError("write failed: \(error)") }
    print("wrote \(url.lastPathComponent) (\(Int(side))x\(Int(side)), \(png.count) bytes)")
}

let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
render(180, to: docs.appendingPathComponent("apple-touch-icon.png"))
render(32, to: docs.appendingPathComponent("favicon-32.png"))
