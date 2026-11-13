import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
struct CountdownRenderer {
    struct VisualState: Codable, Equatable {
        let palette: Palette
        let title: String
        let size: CGSize
        let backingScale: CGFloat
        let insets: GridInsets
        let tiles: Int
        let elapsedHours: Int
        let daysRemaining: Int
        let hoursRemaining: Int
        let percent: Int
        let complete: Bool
        let barPixels: CGFloat
    }

    private struct GridKey: Equatable {
        let size: CGSize
        let panel: CGRect
        let count: Int
        let insets: GridInsets
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private static var grids: [(key: GridKey, tiles: [CGRect])] = []

    let settings: CountdownSettings
    let snapshot: CountdownSnapshot
    var insets = GridInsets()

    private var title: String { settings.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func panel(in size: CGSize, scale: CGFloat, heroFont: NSFont) -> CGRect {
        let heroWidth = (snapshot.daysText as NSString).size(withAttributes: [.font: heroFont]).width
        let width = min(size.width * 0.62, max(260 * scale, heroWidth + 54 * scale))
        let height = (snapshot.isComplete ? 133.0 : 175.0) * scale + (title.isEmpty ? 0 : 23 * scale)
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    func visualState(in size: CGSize, backingScale: CGFloat) -> VisualState {
        var barPixels: CGFloat = 0
        if snapshot.progress > 0, !snapshot.isComplete, size.width > 0, size.height > 0 {
            let scale = min(size.width / 900, size.height / 525)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 64 * scale, weight: .medium)
            let panel = panel(in: size, scale: scale, heroFont: font)
            barPixels = progressPixels(trackWidth: panel.width * 0.70, backingScale: backingScale)
        }
        return VisualState(palette: settings.palette, title: title, size: size, backingScale: backingScale, insets: insets,
                           tiles: snapshot.tileCount, elapsedHours: snapshot.isComplete ? 0 : snapshot.elapsedHours,
                           daysRemaining: snapshot.daysRemaining, hoursRemaining: snapshot.hoursRemaining,
                           percent: snapshot.percent, complete: snapshot.isComplete, barPixels: barPixels)
    }

    func pngVisualState(in size: CGSize, backingScale: CGFloat) -> VisualState {
        let scale = size.width > 0 ? (size.width * backingScale).rounded() / size.width : backingScale
        return visualState(in: size, backingScale: scale)
    }

    private func progressPixels(trackWidth: CGFloat, backingScale: CGFloat) -> CGFloat {
        (trackWidth * snapshot.progress * backingScale).rounded(.down)
    }

    private func tiles(in size: CGSize, around panel: CGRect) -> [CGRect] {
        let key = GridKey(size: size, panel: panel, count: snapshot.tileCount, insets: insets)
        if let index = Self.grids.firstIndex(where: { $0.key == key }) {
            let entry = Self.grids.remove(at: index)
            Self.grids.append(entry)
            return entry.tiles
        }
        let tiles = CountdownGrid.tiles(in: size, around: panel, count: snapshot.tileCount, insets: insets)
        if Self.grids.count == 8 { Self.grids.removeFirst() }
        Self.grids.append((key, tiles))
        return tiles
    }

    // The view and the PNG use the same top-left coordinate system.
    func draw(in size: CGSize, context: CGContext, backingScale: CGFloat = 1) {
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
        let title = self.title
        let heroFont = NSFont.monospacedDigitSystemFont(ofSize: 64 * scale, weight: .medium)
        let panel = panel(in: size, scale: scale, heroFont: heroFont)
        let rim = NSColor(rgb: lightBackground ? 0x0c1b1f : 0xf2fdff).withAlphaComponent(0.21)
        let tiles = tiles(in: size, around: panel)
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
        let fillWidth = snapshot.isComplete ? track.width :
            progressPixels(trackWidth: track.width, backingScale: backingScale) / backingScale
        context.fill(CGRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height))
        context.restoreGState()
    }

    func writePNG(to url: URL, size: CGSize, backingScale: CGFloat) throws {
        let width = Int((size.width * backingScale).rounded())
        let height = Int((size.height * backingScale).rounded())
        guard let space = Self.colorSpace,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(in: size, context: context, backingScale: CGFloat(width) / size.width)
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
        CGGradient(colorsSpace: Self.colorSpace,
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
