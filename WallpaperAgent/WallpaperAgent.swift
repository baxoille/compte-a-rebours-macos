import AppKit

@main
enum WallpaperAgent {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let wallpaper = WallpaperController(tracksStatus: false)
        withExtendedLifetime(wallpaper) { app.run() }
    }
}
