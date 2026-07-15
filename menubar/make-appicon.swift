// Regenerates AppIcon.icns from AppIcon.svg (run: swift make-appicon.swift).
// Uses NSImage's native SVG support, so the SVG must stick to the basic
// shapes/gradients subset — no filters, masks, text, or CSS.
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let svgURL = here.appendingPathComponent("AppIcon.svg")
let iconset = here.appendingPathComponent("AppIcon.iconset")
let icns = here.appendingPathComponent("AppIcon.icns")

guard let src = NSImage(contentsOf: svgURL) else { fatalError("cannot load \(svgURL.path)") }
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int, _ name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("bitmap ctx failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let out = iconset.appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
}

render(16, "icon_16x16.png");     render(32, "icon_16x16@2x.png")
render(32, "icon_32x32.png");     render(64, "icon_32x32@2x.png")
render(128, "icon_128x128.png");  render(256, "icon_128x128@2x.png")
render(256, "icon_256x256.png");  render(512, "icon_256x256@2x.png")
render(512, "icon_512x512.png");  render(1024, "icon_512x512@2x.png")

// Status-item version (18 pt @2x) — shown next to the live level in the menu bar.
render(36, "menubar.png")
try? FileManager.default.removeItem(at: here.appendingPathComponent("MenuBarIcon.png"))
try! FileManager.default.copyItem(at: iconset.appendingPathComponent("menubar.png"),
                                  to: here.appendingPathComponent("MenuBarIcon.png"))
try? FileManager.default.removeItem(at: iconset.appendingPathComponent("menubar.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icns.path)")
