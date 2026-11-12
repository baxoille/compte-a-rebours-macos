import AppKit
import Combine
import CoreGraphics
import ImageIO

struct WallpaperDisplay: Equatable, Identifiable {
    let id: String
    let name: String
    let size: CGSize
    let scale: CGFloat
    let insets: GridInsets
    let isMain: Bool
    let isBuiltIn: Bool

    var resolution: String { "\(Int(size.width)) × \(Int(size.height))" }
}

@MainActor
protocol WallpaperSystem {
    var displays: [WallpaperDisplay] { get }
    func image(on id: String) -> URL?
    func options(on id: String) -> [NSWorkspace.DesktopImageOptionKey: Any]
    func setImage(_ url: URL, on id: String, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws
}

@MainActor
private struct MacWallpaperSystem: WallpaperSystem {
    var displays: [WallpaperDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let id = screen.displayIdentifier else { return nil }
            let frame = screen.frame
            let visible = screen.visibleFrame
            let side = max(visible.minX - frame.minX, frame.maxX - visible.maxX)
            let bottom = visible.minY - frame.minY
            let top = frame.maxY - visible.maxY
            let insets = GridInsets(horizontal: side > 4 ? side + 8 : 0, vertical: max(bottom, top) + 8)
            return WallpaperDisplay(id: id, name: screen.localizedName, size: frame.size,
                                    scale: screen.backingScaleFactor, insets: insets,
                                    isMain: CGDisplayIsMain(number.uint32Value) != 0,
                                    isBuiltIn: CGDisplayIsBuiltin(number.uint32Value) != 0)
        }
        .sorted { $0.isMain && !$1.isMain }
    }

    func image(on id: String) -> URL? {
        screen(id).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    func options(on id: String) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        screen(id).flatMap { NSWorkspace.shared.desktopImageOptions(for: $0) } ?? [:]
    }

    func setImage(_ url: URL, on id: String, options: [NSWorkspace.DesktopImageOptionKey: Any]) throws {
        guard let screen = screen(id) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "L’écran est déconnecté."])
        }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private func screen(_ id: String) -> NSScreen? {
        NSScreen.screens.first { $0.displayIdentifier == id }
    }
}

@MainActor
final class WallpaperController: ObservableObject {
    enum DisplayStatus: Equatable {
        case applied, notApplied, unavailable, unmanaged, pendingRestore, shared
    }

    private struct OriginalImage: Codable {
        let url: URL
        let scaling: Int?
        let clipping: Bool?
        let fillColor: UInt32?
        let backupName: String?

        init(url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any], backupName: String?) {
            self.url = url
            scaling = (options[.imageScaling] as? NSNumber)?.intValue
            clipping = (options[.allowClipping] as? NSNumber)?.boolValue
            fillColor = (options[.fillColor] as? NSColor)?.rgb
            self.backupName = backupName
        }

        var options: [NSWorkspace.DesktopImageOptionKey: Any] {
            var result: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling { result[.imageScaling] = NSNumber(value: scaling) }
            if let clipping { result[.allowClipping] = NSNumber(value: clipping) }
            if let fillColor { result[.fillColor] = NSColor(rgb: fillColor) }
            return result
        }
    }

    private struct Installation: Codable {
        let displayID: String
        let folder: UUID
        var slot: Int
        let original: OriginalImage?
    }

    private struct StoredState: Codable {
        var selected: String?
        var installations: [Installation] = []
        var pending: [Installation] = []

        private enum CodingKeys: String, CodingKey {
            case selected, installations, active, pending
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            selected = try values.decodeIfPresent(String.self, forKey: .selected)
            pending = try values.decodeIfPresent([Installation].self, forKey: .pending) ?? []
            if let installations = try values.decodeIfPresent([Installation].self, forKey: .installations) {
                self.installations = installations
            } else if let previous = try values.decodeIfPresent(Installation.self, forKey: .active) {
                installations = [previous]
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(selected, forKey: .selected)
            try values.encode(installations, forKey: .installations)
            try values.encode(pending, forKey: .pending)
        }
    }

    @Published private(set) var displays: [WallpaperDisplay]
    @Published private(set) var selected: String?
    @Published private(set) var statuses: [String: DisplayStatus] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var hasDisconnectedDisplay = false
    @Published private(set) var hasSharedWallpaper = false

    private let system: any WallpaperSystem
    private let defaults: UserDefaults
    private let stateKey = "wallpaperState"
    private let directory: URL
    private var state: StoredState
    private var rendered: [UUID: CountdownRenderer.VisualState] = [:]
    private var settings: CountdownSettings?
    private var observations: Set<AnyCancellable> = []

    init(system: (any WallpaperSystem)? = nil, defaults: UserDefaults = .standard,
         directory: URL = URL.applicationSupportDirectory.appending(path: "CompteARebours/Fonds", directoryHint: .isDirectory)) {
        let system = system ?? MacWallpaperSystem()
        self.system = system
        self.defaults = defaults
        self.directory = directory
        displays = system.displays
        let data = defaults.data(forKey: stateKey)
        state = data.flatMap { try? JSONDecoder().decode(StoredState.self, from: $0) } ?? StoredState()
        selected = state.selected ?? displays.first?.id
        updateStatuses()
        observeChanges()
    }

    func use(settings: CountdownSettings) {
        self.settings = settings
        refresh()
    }

    func select(_ id: String) {
        selected = id
        state.selected = id
        persist()
    }

    func apply(to display: WallpaperDisplay, settings: CountdownSettings, now: Date = .now) {
        guard let snapshot = CountdownSnapshot(settings: settings, now: now) else { return }
        self.settings = settings
        let current = system.image(on: display.id)
        let existing = installation(on: display.id, matching: current, in: state.installations + state.pending)
        let folder = existing?.folder ?? UUID()
        var unpublishedFolder = existing == nil
        defer {
            // Only a new folder never handed to macOS is known to be unused by every Space.
            if unpublishedFolder { try? FileManager.default.removeItem(at: installationDirectory(folder)) }
            updateStatuses()
        }
        let original = existing?.original ?? captureOriginal(current, on: display.id, in: folder)
        var next = Installation(displayID: display.id, folder: folder, slot: existing?.slot ?? 1, original: original)
        do {
            let renderer = CountdownRenderer(settings: settings, snapshot: snapshot, insets: display.insets)
            let signature = renderer.pngVisualState(in: display.size, backingScale: display.scale)
            next.slot = 1 - next.slot
            try write(next, renderer: renderer, display: display)
            guard sameImage(system.image(on: display.id), current) else {
                report("Le bureau ou son fond a changé. Cliquez à nouveau sur Appliquer.", on: display.id)
                return
            }
            unpublishedFolder = false
            try set(next)
            state.installations.removeAll { $0.folder == folder }
            state.installations.append(next)
            state.pending.removeAll { $0.folder == folder }
            rendered[folder] = signature
            persist()
            report(nil, on: display.id)
        } catch {
            report("Impossible d’appliquer le fond. \(error.localizedDescription)", on: display.id)
        }
    }

    func restore(on display: WallpaperDisplay) {
        defer { updateStatuses() }
        guard let current = system.image(on: display.id) else { return }
        do {
            if let active = installation(on: display.id, matching: current, in: state.installations + state.pending) {
                guard try restore(active, allowDefault: true) else { return }
                remove(active)
            } else {
                guard isGenerated(current), try restoreDefault(on: display.id, replacing: current) else { return }
            }
            report(nil, on: display.id)
        } catch {
            report("Impossible de rétablir le fond. \(error.localizedDescription)", on: display.id)
        }
    }

    func refresh(now: Date = .now) {
        let connected = system.displays
        if displays != connected { displays = connected }
        if selected == nil { selected = connected.first?.id }
        let snapshot = settings.flatMap { CountdownSnapshot(settings: $0, now: now) }
        for display in connected {
            let current = system.image(on: display.id)
            if let pending = installation(on: display.id, matching: current, in: state.pending) {
                do {
                    if try restore(pending) {
                        remove(pending)
                        report(nil, on: display.id)
                    }
                } catch {
                    report("Impossible de rétablir le fond. \(error.localizedDescription)", on: display.id)
                }
                continue
            }
            guard let settings, let snapshot,
                  var active = installation(on: display.id, matching: current, in: state.installations) else { continue }
            let renderer = CountdownRenderer(settings: settings, snapshot: snapshot, insets: display.insets)
            let signature = renderer.pngVisualState(in: display.size, backingScale: display.scale)
            guard signature != rendered[active.folder] else { continue }
            do {
                let previous = active
                active.slot = 1 - active.slot
                try write(active, renderer: renderer, display: display)
                // The active Space or its wallpaper may have changed during rendering.
                guard owns(system.image(on: display.id), previous) else { continue }
                try set(active)
                if let index = state.installations.firstIndex(where: { $0.folder == active.folder }) {
                    state.installations[index] = active
                }
                rendered[active.folder] = signature
                persist()
            } catch {
                report("Actualisation du fond impossible. \(error.localizedDescription)", on: display.id)
            }
        }
        updateStatuses()
    }

    private func updateStatuses() {
        let currentImages = displays.compactMap { display in
            system.image(on: display.id).map { (display.id, $0) }
        }
        let images = Dictionary(currentImages, uniquingKeysWith: { first, _ in first })
        let generated = images.filter { isGenerated($0.value) }
        let paths = generated.mapValues { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let sharedPaths = Set(Dictionary(grouping: paths.values, by: { $0 }).filter { $0.value.count > 1 }.keys)
        var next: [String: DisplayStatus] = [:]
        for display in displays {
            let current = images[display.id]
            if installation(on: display.id, matching: current, in: state.installations) != nil {
                next[display.id] = .applied
            } else if installation(on: display.id, matching: current, in: state.pending) != nil {
                next[display.id] = .pendingRestore
            } else if let path = paths[display.id] {
                next[display.id] = sharedPaths.contains(path) ? .shared : .unmanaged
            } else {
                next[display.id] = current == nil ? .unavailable : .notApplied
            }
        }
        if next != statuses { statuses = next }
        let sharing = !sharedPaths.isEmpty
        if hasSharedWallpaper != sharing { hasSharedWallpaper = sharing }
        let connected = Set(displays.map(\.id))
        let disconnected = (state.installations + state.pending).contains { !connected.contains($0.displayID) }
        if hasDisconnectedDisplay != disconnected { hasDisconnectedDisplay = disconnected }
    }

    private func installation(on id: String, matching url: URL?, in installations: [Installation]) -> Installation? {
        installations.first { $0.displayID == id && owns(url, $0) }
    }

    private func captureOriginal(_ url: URL?, on id: String, in folder: UUID) -> OriginalImage? {
        guard let url, !isGenerated(url), isRestorableImage(url) else { return nil }
        let destination = installationDirectory(folder)
        let name = "Fond-précédent" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        var backupName: String?
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: destination.appending(path: name))
            backupName = name
        } catch {
            // The original URL can still be used when an optional backup is unavailable.
        }
        return OriginalImage(url: url, options: system.options(on: id), backupName: backupName)
    }

    private func restore(_ installation: Installation, allowDefault: Bool = false) throws -> Bool {
        if let original = installation.original, let url = previousImage(original, in: installation.folder) {
            guard owns(system.image(on: installation.displayID), installation) else { return false }
            do {
                try system.setImage(url, on: installation.displayID, options: original.options)
                return true
            } catch {
                if !allowDefault { throw error }
            }
        }
        guard allowDefault else { throw missingOriginal() }
        return try restoreDefault(on: installation.displayID, replacing: imageURL(for: installation))
    }

    private func previousImage(_ original: OriginalImage, in folder: UUID) -> URL? {
        let backup = original.backupName.map { installationDirectory(folder).appending(path: $0) }
            .flatMap { isRestorableImage($0) ? $0 : nil }
        if !isGenerated(original.url), isRestorableImage(original.url),
           backup.map({ FileManager.default.contentsEqual(atPath: original.url.resolvingSymlinksInPath().path, andPath: $0.path) }) ?? true {
            return original.url
        }
        return backup
    }

    private func restoreDefault(on id: String, replacing current: URL) throws -> Bool {
        let resources = URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        let defaultImage = ["DefaultDesktop.heic", "DefaultDesktop.jpg"]
            .map { resources.appending(path: $0).resolvingSymlinksInPath() }
            .first(where: isImage)
        guard let defaultImage else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                "L’image par défaut de macOS est introuvable. Choisissez un fond dans Réglages Système."])
        }
        guard sameImage(system.image(on: id), current) else { return false }
        try system.setImage(defaultImage, on: id, options: [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true,
        ])
        return true
    }

    private func missingOriginal() -> CocoaError {
        CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
            "macOS n’a pas fourni d’image précédente réutilisable. Choisissez votre fond dans Réglages Système."])
    }

    private func isRestorableImage(_ url: URL) -> Bool {
        !isSystemFallback(url) && isImage(url)
    }

    private func isImage(_ url: URL) -> Bool {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    private func isSystemFallback(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // AppKit can expose a system default alias or its resolved target.
        let names = ["defaultdesktop.heic", "defaultdesktop.jpg", "defaultbackground.jpg"]
        return [url.standardizedFileURL, url.resolvingSymlinksInPath()].contains { path in
            path.path.hasPrefix("/System/Library/Wallpapers/.default/") ||
                (path.path.hasPrefix("/System/Library/") && names.contains(path.lastPathComponent.lowercased()))
        }
    }

    private func remove(_ installation: Installation) {
        state.installations.removeAll { $0.folder == installation.folder }
        state.pending.removeAll { $0.folder == installation.folder }
        rendered.removeValue(forKey: installation.folder)
        persist()
    }

    private func isGenerated(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL
        return path.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/") &&
            path.lastPathComponent.hasPrefix("Compte-à-rebours-") && path.pathExtension == "png"
    }

    private func owns(_ current: URL?, _ installation: Installation) -> Bool {
        sameImage(current, imageURL(for: installation))
    }

    private func sameImage(_ first: URL?, _ second: URL?) -> Bool {
        if let first, let second, first.isFileURL, second.isFileURL {
            return first.resolvingSymlinksInPath().standardizedFileURL.path ==
                second.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return first == second
    }

    private func installationDirectory(_ folder: UUID) -> URL {
        directory.appending(path: folder.uuidString, directoryHint: .isDirectory)
    }

    private func imageURL(for installation: Installation) -> URL {
        installationDirectory(installation.folder).appending(path: "Compte-à-rebours-\(installation.slot).png")
    }

    private func write(_ installation: Installation, renderer: CountdownRenderer, display: WallpaperDisplay) throws {
        let url = imageURL(for: installation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appending(path: UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try renderer.writePNG(to: temporary, size: display.size, backingScale: display.scale)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private func set(_ installation: Installation) throws {
        try system.setImage(imageURL(for: installation), on: installation.displayID, options: [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: false,
        ])
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }

    private func report(_ message: String?, on id: String) {
        if errors[id] != message { errors[id] = message }
    }

    private func observeChanges() {
        Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)
        let notifications = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.MergeMany(
            notifications.publisher(for: NSApplication.didChangeScreenParametersNotification),
            notifications.publisher(for: .NSSystemClockDidChange),
            workspace.publisher(for: NSWorkspace.didWakeNotification),
            workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &observations)
    }
}
