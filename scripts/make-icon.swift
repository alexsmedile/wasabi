import AppKit
import Foundation

// Renders Wasabi's app icon → a 1024×1024 PNG.
// Design: kawaii white wasabi-paste dollop (curled peak + smiling face) on a
// modern vibrant mesh gradient (lime → wasabi-green → teal). Concept "E2".
// Usage: make-icon <outPath>   (default: icon-1024.png)

let size: CGFloat = 1024

let wMid  = NSColor(srgbRed: 0.52, green: 0.71, blue: 0.27, alpha: 1)
let wDeep = NSColor(srgbRed: 0.38, green: 0.57, blue: 0.16, alpha: 1)
let wShade = NSColor(srgbRed: 0.27, green: 0.43, blue: 0.10, alpha: 1)
let lime  = NSColor(srgbRed: 0.74, green: 0.90, blue: 0.42, alpha: 1)
let teal  = NSColor(srgbRed: 0.30, green: 0.74, blue: 0.55, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: content in ~83% center square, squircle corners.
let margin = size * 0.085
let plate = CGRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
func squircle(_ r: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: r.width*0.225, yRadius: r.width*0.225)
}

squircle(plate).addClip()

// ── Mesh gradient background ──
NSGradient(colors: [lime, wMid, teal], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: plate, angle: -55)
ctx.saveGState()
squircle(plate).addClip()
// lime bloom top-left
NSGradient(colors: [lime.withAlphaComponent(0.9), lime.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: plate.minX + plate.width*0.25, y: plate.maxY - plate.height*0.20), radius: 0,
          toCenter:   NSPoint(x: plate.minX + plate.width*0.25, y: plate.maxY - plate.height*0.20), radius: plate.width*0.6, options: [])
// teal bloom bottom-right
NSGradient(colors: [teal.withAlphaComponent(0.85), teal.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: plate.maxX - plate.width*0.20, y: plate.minY + plate.height*0.20), radius: 0,
          toCenter:   NSPoint(x: plate.maxX - plate.width*0.20, y: plate.minY + plate.height*0.20), radius: plate.width*0.6, options: [])
ctx.restoreGState()

// ── Kawaii white wasabi dollop ──
let box = CGRect(x: plate.minX + plate.width*0.20, y: plate.minY + plate.height*0.16,
                 width: plate.width*0.60, height: plate.height*0.62)
func dollopPath(in box: CGRect) -> NSBezierPath {
    let p = NSBezierPath(); let w = box.width, h = box.height; let cx = box.midX; let baseY = box.minY
    p.move(to: NSPoint(x: box.minX, y: baseY + h*0.20))
    p.curve(to: NSPoint(x: cx - w*0.05, y: box.maxY - h*0.04),
            controlPoint1: NSPoint(x: box.minX + w*0.02, y: baseY + h*0.72),
            controlPoint2: NSPoint(x: cx - w*0.34, y: box.maxY - h*0.10))
    p.curve(to: NSPoint(x: cx + w*0.18, y: box.maxY - h*0.20),
            controlPoint1: NSPoint(x: cx + w*0.10, y: box.maxY + h*0.02),
            controlPoint2: NSPoint(x: cx + w*0.30, y: box.maxY - h*0.04))
    p.curve(to: NSPoint(x: box.maxX, y: baseY + h*0.20),
            controlPoint1: NSPoint(x: cx + w*0.46, y: box.maxY - h*0.42),
            controlPoint2: NSPoint(x: box.maxX - w*0.02, y: baseY + h*0.60))
    p.curve(to: NSPoint(x: box.minX, y: baseY + h*0.20),
            controlPoint1: NSPoint(x: box.maxX - w*0.10, y: baseY - h*0.06),
            controlPoint2: NSPoint(x: box.minX + w*0.10, y: baseY - h*0.06))
    p.close(); return p
}
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size*0.012), blur: size*0.04,
              color: wShade.withAlphaComponent(0.35).cgColor)
NSColor(white: 0.98, alpha: 1).setFill()
dollopPath(in: box).fill()
ctx.restoreGState()
// soft inner shading on blob
ctx.saveGState(); dollopPath(in: box).addClip()
NSGradient(colors: [NSColor(white:1, alpha:0.0), NSColor(white:0, alpha:0.05)])!.draw(in: box, angle: -90)
ctx.restoreGState()

// ── Face: (^ ^) eyes, smile, rosy cheeks — in deep green ──
let eyeY = box.minY + box.height*0.40
wDeep.setStroke()
for ex in [box.midX - box.width*0.17, box.midX + box.width*0.17] {
    let eye = NSBezierPath(); eye.lineWidth = size*0.018; eye.lineCapStyle = .round
    eye.move(to: NSPoint(x: ex - box.width*0.07, y: eyeY))
    eye.line(to: NSPoint(x: ex, y: eyeY + box.height*0.06))
    eye.line(to: NSPoint(x: ex + box.width*0.07, y: eyeY)); eye.stroke()
}
let smile = NSBezierPath(); smile.lineWidth = size*0.018; smile.lineCapStyle = .round
smile.appendArc(withCenter: NSPoint(x: box.midX, y: eyeY - box.height*0.02),
                radius: box.width*0.12, startAngle: 200, endAngle: 340, clockwise: false)
wDeep.setStroke(); smile.stroke()
NSColor(srgbRed:0.96, green:0.62, blue:0.52, alpha:0.55).setFill()
for cx in [box.midX - box.width*0.26, box.midX + box.width*0.26] {
    let cr = box.width*0.05
    NSBezierPath(ovalIn: CGRect(x: cx-cr, y: eyeY-box.height*0.12-cr, width: cr*2, height: cr*2)).fill()
}

// ── Outer edge highlight (macOS app-icon polish) ──
let rim = squircle(plate.insetBy(dx: size*0.006, dy: size*0.006))
rim.lineWidth = size*0.009; NSColor(white:1, alpha:0.30).setStroke(); rim.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render\n".data(using: .utf8)!); exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
