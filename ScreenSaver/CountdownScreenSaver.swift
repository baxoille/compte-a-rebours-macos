import ScreenSaver

@objc(CountdownScreenSaver)
final class CountdownScreenSaver: ScreenSaverView {
    private let preferences = CountdownPreferences()
    private var settings: CountdownSettings?
    private var snapshot: CountdownSnapshot?
    private var visualState: CountdownRenderer.VisualState?
    private var lastRead: Date?

    override var isFlipped: Bool { true }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1
        update(now: .now)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1
        update(now: .now)
    }

    override func startAnimation() {
        super.startAnimation()
        lastRead = nil
        update(now: .now)
    }

    override func animateOneFrame() {
        guard isAnimating else { return }
        update(now: .now)
    }

    override func draw(_ dirtyRect: NSRect) {
        // macOS selects which displays host this module. Every hosted view renders the countdown.
        if let settings, let snapshot,
           let context = NSGraphicsContext.current?.cgContext {
            CountdownRenderer(settings: settings, snapshot: snapshot)
                .draw(in: bounds.size, context: context, backingScale: window?.backingScaleFactor ?? 1)
            return
        }
        NSColor(rgb: Palette.dark.background).setFill()
        dirtyRect.fill()
        let message = "Configurez le compte à rebours dans l’application."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(20, bounds.width / 29)),
            .foregroundColor: NSColor(rgb: Palette.dark.text),
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        (message as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    private func update(now: Date) {
        if lastRead.map({ abs(now.timeIntervalSince($0)) >= 5 }) ?? true {
            settings = preferences.load()
            lastRead = now
        }
        snapshot = settings.flatMap { CountdownSnapshot(settings: $0, now: now) }
        let next = settings.flatMap { settings in
            snapshot.map {
                CountdownRenderer(settings: settings, snapshot: $0)
                    .visualState(in: bounds.size, backingScale: window?.backingScaleFactor ?? 1)
            }
        }
        if next != visualState {
            visualState = next
            needsDisplay = true
        }
    }
}
