import AppKit

/// Builds the **dynamic** Dock icon: a frosted-glass squircle with the favicons
/// of the added services composited into an adaptive grid (max 4, 2×2).
///
/// Set via `NSApplication.applicationIconImage`, which overrides the bundled
/// `AppIcon.icns` at runtime. The grid adapts to count: 1 big, 2 side-by-side,
/// 3 as 2-over-1, 4 as a full 2×2, and 5+ shows the first 3 plus a "+N" tile.
/// Tiles fill the interior like fluid — their outer corners hug the squircle rim
/// — over a translucent wasabi-green backdrop with a light-catching glass rim.
enum AppIconRenderer {
    static let size: CGFloat = 1024

    /// Render the dynamic icon for the given favicons (in sidebar order).
    /// `nil` entries are services whose favicon hasn't resolved yet — skipped.
    static func render(favicons: [NSImage?]) -> NSImage {
        let icons = favicons.compactMap { $0 }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        // macOS icon grid: content in ~83% center square, squircle corners.
        let margin = size * 0.085
        let plate = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
        let radius = plate.width * 0.225
        let squircle = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

        drawFrostedBackdrop(squircle, plate: plate)

        squircle.addClip()
        // Tiles fill the interior like fluid: each tile's corners that sit near the
        // squircle's corners take a large radius (concentric with the shape); the
        // corners facing siblings/center take a small radius. So the tile block
        // hugs the outer contour and meets tightly in the middle.
        let geom = TileGeometry(plate: plate, outerRadius: radius)
        let cells = layout(count: icons.count, in: geom.inner)
        for (i, cell) in cells.enumerated() {
            if i < icons.count {
                drawFavicon(icons[i], in: cell, geom: geom)
            }
        }
        // 5+ services: last cell becomes a "+N more" tile.
        if icons.count > 4, let last = cells.last {
            drawOverflow(icons.count - 3, in: last, geom: geom)
        }

        return image
    }

    /// Geometry shared by every tile: the inner content rect (where tiles live),
    /// plus the radii used to make tiles hug the squircle's corners.
    private struct TileGeometry {
        let plate: CGRect          // the squircle's bounding box
        let inner: CGRect          // padded interior where tiles are laid out
        let pad: CGFloat           // gap between the rim and the tile block
        let outerR: CGFloat        // large radius for corners hugging the rim
        let innerR: CGFloat        // small radius for corners facing the center

        init(plate: CGRect, outerRadius: CGFloat) {
            self.plate = plate
            self.pad = plate.width * 0.055
            self.inner = plate.insetBy(dx: pad, dy: pad)
            // Concentric with the squircle: a corner inset by `pad` from a rim of
            // radius R reads cleanest at radius (R - pad).
            self.outerR = max(0, outerRadius - pad)
            self.innerR = plate.width * 0.05
        }

        /// Per-corner radii for a tile: a corner gets the large (rim-hugging) radius
        /// if it lies near the plate's corresponding corner, else the small radius.
        func corners(for cell: CGRect) -> Corners {
            let tol = pad * 1.5    // "near the rim" tolerance
            let nearLeft   = cell.minX - inner.minX < tol
            let nearRight  = inner.maxX - cell.maxX < tol
            let nearBottom = cell.minY - inner.minY < tol
            let nearTop    = inner.maxY - cell.maxY < tol
            return Corners(
                topLeft:     (nearTop && nearLeft)     ? outerR : innerR,
                topRight:    (nearTop && nearRight)    ? outerR : innerR,
                bottomRight: (nearBottom && nearRight) ? outerR : innerR,
                bottomLeft:  (nearBottom && nearLeft)  ? outerR : innerR
            )
        }
    }

    private struct Corners {
        let topLeft, topRight, bottomRight, bottomLeft: CGFloat
    }

    /// A rounded-rect path with independent per-corner radii (AppKit's built-in
    /// `roundedRect:` only does a uniform radius). Built clockwise from top-left.
    private static func tilePath(_ r: CGRect, _ c: Corners) -> NSBezierPath {
        let p = NSBezierPath()
        // Clamp radii so they never exceed half the smaller side.
        let lim = min(r.width, r.height) / 2
        let tl = min(c.topLeft, lim), tr = min(c.topRight, lim)
        let br = min(c.bottomRight, lim), bl = min(c.bottomLeft, lim)

        p.move(to: CGPoint(x: r.minX + tl, y: r.maxY))
        p.line(to: CGPoint(x: r.maxX - tr, y: r.maxY))
        p.appendArc(withCenter: CGPoint(x: r.maxX - tr, y: r.maxY - tr), radius: tr, startAngle: 90, endAngle: 0, clockwise: true)
        p.line(to: CGPoint(x: r.maxX, y: r.minY + br))
        p.appendArc(withCenter: CGPoint(x: r.maxX - br, y: r.minY + br), radius: br, startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: CGPoint(x: r.minX + bl, y: r.minY))
        p.appendArc(withCenter: CGPoint(x: r.minX + bl, y: r.minY + bl), radius: bl, startAngle: 270, endAngle: 180, clockwise: true)
        p.line(to: CGPoint(x: r.minX, y: r.maxY - tl))
        p.appendArc(withCenter: CGPoint(x: r.minX + tl, y: r.maxY - tl), radius: tl, startAngle: 180, endAngle: 90, clockwise: true)
        p.close()
        return p
    }

    // MARK: - Backdrop

    private static func drawFrostedBackdrop(_ squircle: NSBezierPath, plate: CGRect) {
        NSGraphicsContext.current?.cgContext.saveGState()
        squircle.addClip()
        // Branded frosted glass: translucent wasabi tint with a soft vertical lift.
        NSGradient(colors: [
            NSColor(srgbRed: 0.90, green: 0.96, blue: 0.78, alpha: 0.88),
            NSColor(srgbRed: 0.70, green: 0.84, blue: 0.42, alpha: 0.90),
        ])!.draw(in: plate, angle: -90)
        // top sheen
        NSGradient(colors: [
            NSColor(srgbRed: 1.00, green: 1.00, blue: 0.92, alpha: 0.42),
            NSColor(srgbRed: 1.00, green: 1.00, blue: 0.92, alpha: 0),
        ])!
            .draw(in: CGRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
        NSGraphicsContext.current?.cgContext.restoreGState()

        // A translucent green glass rim that "catches light": instead of a flat
        // painted stroke, the rim is a thin band (stroke → clip → fill) lit by a
        // vertical gradient — brighter/lighter green up top where light hits,
        // deeper green at the bottom — plus a faint white specular highlight on the
        // upper edge. Reads as a refractive glass bevel, greener than the backdrop
        // but still see-through.
        let radius = plate.width * 0.225
        let lw = size * 0.018
        let rimInset = lw / 2
        let rim = NSBezierPath(roundedRect: plate.insetBy(dx: rimInset, dy: rimInset),
                               xRadius: max(0, radius - rimInset),
                               yRadius: max(0, radius - rimInset))
        rim.lineWidth = lw

        NSGraphicsContext.current?.cgContext.saveGState()
        rim.setClip()                       // confine the gradient to the rim band
        NSGradient(colors: [
            NSColor(srgbRed: 0.55, green: 0.74, blue: 0.34, alpha: 0.55),   // top — lit
            NSColor(srgbRed: 0.38, green: 0.60, blue: 0.20, alpha: 0.45),   // mid
            NSColor(srgbRed: 0.28, green: 0.50, blue: 0.14, alpha: 0.62),   // bottom — deeper
        ])!.draw(in: plate, angle: -90)
        NSGraphicsContext.current?.cgContext.restoreGState()

        // Specular "catch": a thin bright highlight tracing the upper edge of the
        // rim, fading toward the sides — the glint of light on a glass lip.
        let specular = NSBezierPath(roundedRect: plate.insetBy(dx: rimInset, dy: rimInset),
                                    xRadius: max(0, radius - rimInset),
                                    yRadius: max(0, radius - rimInset))
        specular.lineWidth = lw * 0.4
        NSGraphicsContext.current?.cgContext.saveGState()
        specular.setClip()
        NSGradient(colors: [
            NSColor(white: 1.0, alpha: 0.0),
            NSColor(white: 1.0, alpha: 0.55),   // bright near the top
        ])!.draw(in: CGRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: 90)
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    // MARK: - Adaptive grid layout

    /// Cell rects (in draw order) for `count` favicons inside `inner` (the padded
    /// interior). Tiles meet with a thin `gap`; their outer corners hug the rim.
    private static func layout(count: Int, in inner: CGRect) -> [CGRect] {
        let gap = inner.width * 0.05              // thin gap between tiles

        func grid2x2() -> [CGRect] {
            let w = (inner.width - gap) / 2, h = (inner.height - gap) / 2
            return [
                CGRect(x: inner.minX, y: inner.maxY - h, width: w, height: h),          // TL
                CGRect(x: inner.maxX - w, y: inner.maxY - h, width: w, height: h),       // TR
                CGRect(x: inner.minX, y: inner.minY, width: w, height: h),               // BL
                CGRect(x: inner.maxX - w, y: inner.minY, width: w, height: h),           // BR
            ]
        }

        switch count {
        case 0, 1:
            return [inner]                                                              // one big, centered
        case 2:
            let w = (inner.width - gap) / 2
            return [
                CGRect(x: inner.minX, y: inner.minY, width: w, height: inner.height),
                CGRect(x: inner.maxX - w, y: inner.minY, width: w, height: inner.height),
            ]
        case 3:
            let w = (inner.width - gap) / 2, h = (inner.height - gap) / 2
            let bottomW = inner.width * 0.5
            return [
                CGRect(x: inner.minX, y: inner.maxY - h, width: w, height: h),           // top-left
                CGRect(x: inner.maxX - w, y: inner.maxY - h, width: w, height: h),       // top-right
                CGRect(x: inner.midX - bottomW / 2, y: inner.minY, width: bottomW, height: h), // bottom-centered
            ]
        default:
            return grid2x2()                                                            // 4 and 5+ (last = overflow)
        }
    }

    // MARK: - Cell drawing

    private static func drawFavicon(_ icon: NSImage, in cell: CGRect, geom: TileGeometry) {
        // Tile shape: outer corners hug the squircle rim, inner corners stay tight.
        let tile = tilePath(cell, geom.corners(for: cell))

        NSGraphicsContext.current?.cgContext.saveGState()
        tile.addClip()
        // Frosted white tile — translucent so the green backdrop reads through it,
        // while still lifting the favicon off the background for contrast.
        NSColor(white: 1.0, alpha: 0.72).setFill()
        cell.fill()
        // aspect-fit the favicon with a little inset
        let inset = cell.width * 0.16
        let fit = aspectFit(icon.size, into: cell.insetBy(dx: inset, dy: inset))
        icon.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.cgContext.restoreGState()

        // subtle tile border
        tile.lineWidth = size * 0.004
        NSColor(srgbRed: 0.24, green: 0.52, blue: 0.08, alpha: 0.20).setStroke()
        tile.stroke()
    }

    private static func drawOverflow(_ n: Int, in cell: CGRect, geom: TileGeometry) {
        let tile = tilePath(cell, geom.corners(for: cell))
        NSGraphicsContext.current?.cgContext.saveGState()
        tile.addClip()
        NSColor(srgbRed: 0.30, green: 0.55, blue: 0.10, alpha: 0.72).setFill()
        cell.fill()
        let text = "+\(n)" as NSString
        let fontSize = cell.height * 0.42
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ]
        let bounds = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: cell.midX - bounds.width / 2, y: cell.midY - bounds.height / 2), withAttributes: attrs)
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private static func aspectFit(_ src: NSSize, into rect: CGRect) -> CGRect {
        guard src.width > 0, src.height > 0 else { return rect }
        let scale = min(rect.width / src.width, rect.height / src.height)
        let w = src.width * scale, h = src.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
