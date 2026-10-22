// Renders the app icon: swift scripts/make-icon.swift <out.png>  (1024x1024)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
}

// Body: macOS icon grid (824pt squircle centred on a 1024 canvas) with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x15172A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([color(0x3A3F6B), color(0x1A1C33), color(0x0C0D18)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Faint top sheen.
ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)]),
                       startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 960), endRadius: 560, options: [])

// Screen.
let screen = CGRect(x: 214, y: 330, width: 600, height: 420)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 56, cornerHeight: 56, transform: nil)
ctx.addPath(screenPath); ctx.setFillColor(color(0xFFFFFF, 0.06)); ctx.fillPath()
ctx.addPath(screenPath); ctx.setStrokeColor(color(0xFFFFFF, 0.92)); ctx.setLineWidth(26); ctx.strokePath()
// Stand.
ctx.setFillColor(color(0xFFFFFF, 0.92))
ctx.fill(CGPath(roundedRect: CGRect(x: 452, y: 262, width: 120, height: 56), cornerWidth: 10, cornerHeight: 10, transform: nil).boundingBox)
ctx.addPath(CGPath(roundedRect: CGRect(x: 380, y: 236, width: 264, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
ctx.fillPath()

// Record dot with glow.
let dot = CGPoint(x: 560, y: 540), r: CGFloat = 92
ctx.drawRadialGradient(gradient([color(0xFF453A, 0.55), color(0xFF453A, 0)]),
                       startCenter: dot, startRadius: r * 0.8, endCenter: dot, endRadius: r * 2.1, options: [])
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)); ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFF7A6E), color(0xFF3B30), color(0xD9261C)]),
                       start: CGPoint(x: dot.x, y: dot.y + r), end: CGPoint(x: dot.x, y: dot.y - r), options: [])
ctx.restoreGState()

// Camera bubble overlapping the screen's bottom-left corner.
let cam = CGPoint(x: 300, y: 330), cr: CGFloat = 128
let camRect = CGRect(x: cam.x - cr, y: cam.y - cr, width: cr * 2, height: cr * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.5))
ctx.addEllipse(in: camRect); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: camRect.insetBy(dx: 16, dy: 16)); ctx.clip()
ctx.drawLinearGradient(gradient([color(0x7DD3FC), color(0x6366F1)]),
                       start: CGPoint(x: cam.x - cr, y: cam.y + cr), end: CGPoint(x: cam.x + cr, y: cam.y - cr), options: [])
// Person silhouette.
ctx.setFillColor(color(0xFFFFFF, 0.95))
ctx.addEllipse(in: CGRect(x: cam.x - 40, y: cam.y + 2, width: 80, height: 80)); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: cam.x - 92, y: cam.y - 150, width: 184, height: 150)); ctx.fillPath()
ctx.restoreGState()

ctx.restoreGState()
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
