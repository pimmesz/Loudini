// Regenerates docs/og.png — the 1200x630 share preview Slack/Discord/X/Reddit unfurl
// for loudini.app (run: swift make-og.swift).
//
// WHY a script and not a checked-in export: the repo has no design tool and no image
// pipeline, and the brand is four rounded bars plus three gradient stops. Drawing it in
// AppKit keeps the image regenerable from the same numbers as menubar/AppIcon.svg, so a
// colour or wording change is a one-line edit here instead of a lost source file.
//
// Same shape as menubar/make-appicon.swift: render into an NSBitmapImageRep, write a PNG.
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let out = here.appendingPathComponent("og.png")

let W: CGFloat = 1200
let H: CGFloat = 630

// Brand palette, copied from docs/index.html's :root and menubar/AppIcon.svg.
func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// The card is fully opaque, but the alpha channel stays: NSGraphicsContext refuses to wrap
// a 3-sample rep, so an alpha-less bitmap simply cannot be drawn into.
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("bitmap ctx failed") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

// AppKit draws y-up; every layout number below is measured from the top, like CSS.
func box(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) -> NSRect {
    NSRect(x: x, y: H - top - h, width: w, height: h)
}

// Background: the same off-centre radial glow as the app icon (72% across, 24% down).
// relativeCenterPosition runs -1...1 from edge to edge, hence the *2-1.
NSGradient(colors: [rgb(0x1B2054), rgb(0x0E1232), rgb(0x07091B)],
           atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)?
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H),
          relativeCenterPosition: NSPoint(x: 0.72 * 2 - 1, y: (1 - 0.24) * 2 - 1))

// The mark: AppIcon.svg's four bars, scaled from its 1024 viewBox. Their bounding box is
// x 182...842, y 202...822, so we scale by height and offset by that box's top-left.
let markTop: CGFloat = 92
let markHeight: CGFloat = 128
let scale = markHeight / 620
let markLeft: CGFloat = 80
let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (182, 371, 120, 282), (362, 202, 120, 620), (542, 286, 120, 451), (722, 385, 120, 254),
]
let markPath = NSBezierPath()
for (x, y, w, h) in bars {
    markPath.append(NSBezierPath(
        roundedRect: box(x: markLeft + (x - 182) * scale, top: markTop + (y - 202) * scale,
                         w: w * scale, h: h * scale),
        xRadius: 55 * scale, yRadius: 55 * scale))
}
// SVG runs this gradient lower-left to upper-right; in y-up pixels that is a 45° angle.
NSGradient(colors: [rgb(0xFF3CAC), rgb(0x865DFF), rgb(0x20D9FF)],
           atLocations: [0, 0.48, 1], colorSpace: .deviceRGB)?
    .draw(in: markPath, angle: 45)

func draw(_ text: String, _ font: NSFont, _ color: NSColor, x: CGFloat, top: CGFloat,
          width: CGFloat, lineHeight: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
    NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: style,
    ]).draw(in: box(x: x, top: top, w: width, h: H))
}

let markRight = markLeft + 660 * scale + 26
draw("Loudini", .systemFont(ofSize: 56, weight: .bold), rgb(0xF4F5FA),
     x: markRight, top: markTop + 30, width: 500, lineHeight: 64)

draw("The master volume\nmacOS wouldn't give you.", .systemFont(ofSize: 72, weight: .bold),
     rgb(0xF4F5FA), x: markLeft, top: 282, width: W - markLeft * 2, lineHeight: 88)

draw("Free & open source  ·  macOS 14.4+  ·  works with any output device",
     .systemFont(ofSize: 27, weight: .medium), rgb(0x8A8FA3),
     x: markLeft, top: 498, width: W - markLeft * 2, lineHeight: 34)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
try png.write(to: out)
print("wrote \(out.path) (\(Int(W))x\(Int(H)), \(png.count) bytes)")
