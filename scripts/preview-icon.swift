// Renders the dynamic app icon to PNGs for visual inspection.
// Compiled together with AppIconRenderer.swift so it uses the real renderer.
import AppKit

func loadFavicon(_ name: String) -> NSImage? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/app.wasabi.Wasabi/favicons/\(name).img")
    return NSImage(contentsOf: url)
}

func swatch(_ color: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 256, height: 256))
    img.lockFocus()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 208, height: 208), xRadius: 40, yRadius: 40).fill()
    img.unlockFocus()
    return img
}

func write(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

@main
struct Preview {
    static func main() {
        let wa = loadFavicon("whatsapp")
        let tg = loadFavicon("telegram")

        // Real case: WhatsApp + Telegram (2 icons)
        write(AppIconRenderer.render(favicons: [wa, tg]), to: "/tmp/wasabi-icon-2.png")

        // 4-icon grid (real two + two synthetic swatches)
        write(AppIconRenderer.render(favicons: [
            wa, tg, swatch(.systemBlue), swatch(.systemOrange),
        ]), to: "/tmp/wasabi-icon-4.png")

        // 5-icon overflow (+N tile)
        write(AppIconRenderer.render(favicons: [
            wa, tg, swatch(.systemBlue), swatch(.systemPurple), swatch(.systemRed),
        ]), to: "/tmp/wasabi-icon-5.png")
    }
}
