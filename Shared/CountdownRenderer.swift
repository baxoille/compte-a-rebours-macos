import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
struct CountdownRenderer {
    let settings: CountdownSettings
    let snapshot: CountdownSnapshot
    var insets = GridInsets()

    // The view and the PNG use the same top-left coordinate system.
    func draw(in size: CGSize, context: CGContext) {
        guard size.width > 0, size.height > 0 else { return }
        let palette = settings.palette
        let background = NSColor(rgb: palette.background)
        let fill = NSColor(rgb: palette.fill)
        let empty = NSColor(rgb: palette.empty)
        let ink = NSColor(rgb: palette.text)
        let lightBackground = 0.213 * background.redComponent + 0.715 * background.greenComponent +
            0.072 * background.blueComponent > 0.53
        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        drawGlow(fill, opacity: 0.12, at: CGPoint(x: size.width * 0.13, y: size.height * 0.06), in: size, context: context)
        drawGlow(empty, opacity: 0.26, at: CGPoint(x: size.width * 0.76, y: size.height * 0.95), in: size, context: context)

        let scale = min(size.width / 900, size.height / 525)
        let title = settings.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let heroFont = NSFont.monospacedDigitSystemFont(ofSize: 64 * scale, weight: .medium)
        let heroWidth = (snapshot.daysText as NSString).size(withAttributes: [.font: heroFont]).width
        let panelWidth = min(size.width * 0.62, max(260 * scale, heroWidth + 54 * scale))
        let panelHeight = (snapshot.isComplete ? 133.0 : 175.0) * scale + (title.isEmpty ? 0 : 23 * scale)
        let panel = CGRect(x: (size.width - panelWidth) / 2, y: (size.height - panelHeight) / 2,
                           width: panelWidth, height: panelHeight)
        let rim = NSColor(rgb: lightBackground ? 0x0c1b1f : 0xf2fdff).withAlphaComponent(0.21)
        let tiles = CountdownGrid.tiles(in: size, around: panel, count: snapshot.tileCount, insets: insets)
        for (index, tile) in tiles.enumerated() {
            let fraction = snapshot.fill(at: index)
            let radius = min(6 * scale, tile.width * 0.22)
            let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor((fraction == 1 ? fill : empty).cgColor)
            context.fillPath()
            if fraction > 0, fraction < 1 {
                context.saveGState()
                context.addPath(path)
                context.clip()
                context.setFillColor(fill.cgColor)
                context.fill(CGRect(x: tile.minX, y: tile.maxY - tile.height * fraction,
                                    width: tile.width, height: tile.height * fraction))
                context.restoreGState()
            }
            if fraction < 1, tile.width >= 3 * scale {
                context.addPath(path)
                context.setLineWidth(0.8 * scale)
                context.setStrokeColor(rim.cgColor)
                context.strokePath()
            }
        }

        let glass = CGPath(roundedRect: panel, cornerWidth: 33 * scale, cornerHeight: 33 * scale, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10 * scale), blur: 24 * scale,
                          color: NSColor(rgb: 0x101d27).withAlphaComponent(0.16).cgColor)
        context.addPath(glass)
        context.setFillColor(background.withAlphaComponent(0.77).cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(glass)
        context.clip()
        if let reflection = gradient(.white, opacity: lightBackground ? 0.60 : 0.14) {
            context.drawLinearGradient(reflection, start: panel.origin,
                                       end: CGPoint(x: panel.maxX, y: panel.maxY), options: [])
        }
        context.restoreGState()
        context.addPath(glass)
        context.setLineWidth(max(0.5, scale))
        context.setStrokeColor(NSColor.white.withAlphaComponent(lightBackground ? 0.74 : 0.28).cgColor)
        context.strokePath()

        var y = panel.minY + 16 * scale
        let textWidth = panel.width - 24 * scale
        if !title.isEmpty {
            drawText(title, at: y, width: textWidth, midX: panel.midX,
                     font: .systemFont(ofSize: 15 * scale, weight: .medium), color: ink)
            y += 23 * scale
        }
        if !snapshot.isComplete {
            drawText("RESTANT", at: y, width: textWidth, midX: panel.midX,
                     font: .systemFont(ofSize: 13 * scale, weight: .medium), color: ink, tracking: 1.3 * scale)
            y += 15 * scale
        }
        drawText(snapshot.daysText, at: y, width: textWidth, midX: panel.midX, font: heroFont,
                 color: ink, tracking: -3.4 * scale)
        y += 74 * scale
        if !snapshot.isComplete {
            drawText(snapshot.hoursText, at: y, width: textWidth, midX: panel.midX,
                     font: .monospacedDigitSystemFont(ofSize: 16 * scale, weight: .regular), color: ink)
            y += 27 * scale
        } else {
            y += 6 * scale
        }
        drawText(snapshot.percentText, at: y, width: textWidth, midX: panel.midX,
                 font: .monospacedDigitSystemFont(ofSize: 13 * scale, weight: .regular), color: ink)
        let track = CGRect(x: panel.minX + panel.width * 0.15, y: y + 20 * scale,
                           width: panel.width * 0.70, height: 5 * scale)
        let trackPath = CGPath(roundedRect: track, cornerWidth: track.height / 2,
                               cornerHeight: track.height / 2, transform: nil)
        context.saveGState()
        context.addPath(trackPath)
        context.clip()
        context.setFillColor(empty.cgColor)
        context.fill(track)
        context.setFillColor(fill.cgColor)
        context.fill(CGRect(x: track.minX, y: track.minY, width: track.width * snapshot.progress, height: track.height))
        context.restoreGState()
    }

    func writePNG(to url: URL, size: CGSize, backingScale: CGFloat) throws {
        let width = Int((size.width * backingScale).rounded())
        let height = Int((size.height * backingScale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(in: size, context: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func drawText(_ text: String, at y: CGFloat, width: CGFloat, midX: CGFloat,
                          font: NSFont, color: NSColor, tracking: CGFloat = 0) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let rect = CGRect(x: midX - width / 2, y: y, width: width, height: font.pointSize * 1.25)
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style, .kern: tracking,
        ])
    }

    private func gradient(_ color: NSColor, opacity: CGFloat) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: [color.withAlphaComponent(opacity).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                   locations: [0, 1])
    }

    private func drawGlow(_ color: NSColor, opacity: CGFloat, at point: CGPoint, in size: CGSize, context: CGContext) {
        guard let glow = gradient(color, opacity: opacity) else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: size.width, y: size.height)
        context.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                   endRadius: 0.63, options: [])
        context.restoreGState()
    }
}
