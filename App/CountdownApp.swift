import AppKit
import Combine
import SwiftUI

@main
struct CountdownApp: App {
    @StateObject private var wallpaper = WallpaperController()
    @NSApplicationDelegateAdaptor(CountdownAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Compte à rebours", id: "countdown") {
            CountdownWindow(wallpaper: wallpaper)
                .frame(minWidth: 680, minHeight: 490)
        }
        .defaultSize(width: 960, height: 720)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private final class CountdownAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Dock can keep the generic icon for a rebuilt Xcode product.
        guard let app = notification.object as? NSApplication,
              let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        app.applicationIconImage = icon
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private enum ScreenSaverInstallation: Equatable {
    case missing, updateRequired, available

    private static let minimumVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        .flatMap(Int.init) ?? 6

    static func detect(
        userLibraries: [URL] = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask),
        localLibraries: [URL] = FileManager.default.urls(for: .libraryDirectory, in: .localDomainMask)
    ) -> Self {
        // An outdated user installation can coexist with a newer system installation.
        // Prefer the newest user copy, then consider the system library if there is none.
        guard let latest = newestVersion(in: userLibraries) ?? newestVersion(in: localLibraries) else { return .missing }
        return latest >= minimumVersion ? .available : .updateRequired
    }

    private static func newestVersion(in libraries: [URL]) -> Int? {
        var versions: [Int] = []
        for library in libraries {
            let folder = library.appending(path: "Screen Savers", directoryHint: .isDirectory)
            let modules = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for module in modules where module.pathExtension.lowercased() == "saver" {
                if let version = version(of: module) { versions.append(version) }
            }
        }
        return versions.max()
    }

    static func compiledModule(in app: Bundle = .main) -> URL? {
        guard let plugins = app.builtInPlugInsURL else { return nil }
        let module = plugins.appending(path: "CompteAReboursSaver.saver", directoryHint: .isDirectory)
        let expected = app.bundleURL.resolvingSymlinksInPath().appending(path: "Contents/PlugIns/CompteAReboursSaver.saver")
        guard module.resolvingSymlinksInPath().path == expected.path,
              let appVersion = (app.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init),
              let version = version(of: module), version == appVersion else { return nil }
        return module
    }

    private static func version(of module: URL) -> Int? {
        // Bundle caches Info.plist by URL, even if the module is replaced at that path.
        let infoURL = module.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "fr.comptearebours.macos.saver" else { return nil }
        return (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
    }
}

@MainActor
private final class CountdownEditor: ObservableObject {
    enum PreviewMode: String, CaseIterable {
        case desktop = "Bureau"
        case saver = "Économiseur"
    }

    @Published var mode = PreviewMode.desktop
    @Published var showSettings = false
    @Published private(set) var stored: CountdownSettings?
    @Published var draft: CountdownSettings
    @Published private(set) var saveError: String?
    @Published private(set) var screenSaverInstallation = ScreenSaverInstallation.detect()
    @Published private(set) var screenSaverError: String?
    @Published private(set) var isLaunchingScreenSaver = false
    private var didLoad = false
    private let preferences = CountdownPreferences()
    private var screenSaverPreview: ScreenSaverPreviewWindow?
    var previewSettings: CountdownSettings {
        draft.validationError == nil ? draft : (stored ?? .initial())
    }

    init() {
        let settings = preferences.loadDraft()
        stored = settings.flatMap { $0.validationError == nil ? $0 : nil }
        draft = settings ?? .initial()
    }

    func load(colorScheme: ColorScheme) -> CountdownSettings? {
        if !didLoad {
            didLoad = true
            // Keep a legacy title editable along with its dates and palette.
            if stored == nil, draft.validationError == nil {
                if preferences.hasSavedFile {
                    saveError = "Les réglages existants ne sont pas lisibles. Enregistrez pour les remplacer."
                } else {
                    draft.palette = colorScheme == .dark ? .dark : .light
                    _ = save()
                }
            }
        }
        return stored
    }

    func save() -> Bool {
        guard draft.validationError == nil else { return false }
        if stored == draft { return true }
        do {
            try preferences.save(draft)
            stored = draft
            saveError = nil
            return true
        } catch {
            saveError = "Impossible d’enregistrer les réglages. \(error.localizedDescription)"
            return false
        }
    }

    func refreshScreenSaverInstallation() {
        screenSaverInstallation = .detect()
    }

    func previewScreenSaver(on display: WallpaperDisplay) {
        screenSaverError = nil
        guard let screen = NSScreen.screens.first(where: { $0.displayIdentifier == display.id }) else {
            screenSaverError = "Cet écran est déconnecté."
            return
        }
        let settings = previewSettings
        guard let snapshot = CountdownSnapshot(settings: settings, now: .now) else { return }
        screenSaverPreview?.close()
        let window = ScreenSaverPreviewWindow(screen: screen,
                                               renderer: CountdownRenderer(settings: settings, snapshot: snapshot))
        window.onClose = { [weak self] in self?.screenSaverPreview = nil }
        screenSaverPreview = window
        window.makeKeyAndOrderFront(nil)
    }

    func launchScreenSaver() async {
        guard !isLaunchingScreenSaver else { return }
        isLaunchingScreenSaver = true
        screenSaverError = nil
        defer { isLaunchingScreenSaver = false }

        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: engine, configuration: configuration)
        } catch {
            screenSaverError = "Impossible de lancer l’économiseur. Utilisez Aperçu dans Réglages Système."
        }
    }
}

private struct CountdownWindow: View {
    @ObservedObject var wallpaper: WallpaperController
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var editor = CountdownEditor()

    private var display: WallpaperDisplay? {
        wallpaper.displays.first { $0.id == wallpaper.selected } ?? wallpaper.displays.first
    }

    private var configuresScreenSaverByDisplay: Bool {
        if #available(macOS 26, *) { return wallpaper.displays.count > 1 }
        return false
    }

    private static let wallpaperSettings = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!
    private static let screenSaverSettings: URL = {
        if #available(macOS 26, *) {
            return URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                preview
                controls
                if editor.showSettings { settingsForm }
            }
            .padding(18)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let settings = editor.load(colorScheme: colorScheme) { wallpaper.use(settings: settings) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            editor.refreshScreenSaverInstallation()
        }
        .onChange(of: editor.mode) { _, mode in
            if mode == .saver { editor.refreshScreenSaverInstallation() }
        }
    }

    private var preview: some View {
        let screenSize = display?.size ?? CGSize(width: 1440, height: 1000)
        let insets = editor.mode == .desktop ? (display?.insets ?? GridInsets()) : GridInsets()
        let settings = editor.previewSettings
        return GeometryReader { proxy in
            let scale = min(proxy.size.width / screenSize.width, proxy.size.height / screenSize.height)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                if let snapshot = CountdownSnapshot(settings: settings, now: timeline.date) {
                    CountdownPreview(renderer: CountdownRenderer(settings: settings, snapshot: snapshot,
                                                                   insets: GridInsets(horizontal: insets.horizontal * scale,
                                                                                      vertical: insets.vertical * scale)))
                        .frame(width: screenSize.width * scale, height: screenSize.height * scale)
                        .clipShape(.rect(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.10)) }
                        .accessibilityLabel(settings.title.isEmpty ? "Compte à rebours" : settings.title)
                        .accessibilityValue(snapshot.isComplete ? "Terminé, \(snapshot.percentText)" :
                                                "Restant, \(snapshot.daysText), \(snapshot.hoursText), \(snapshot.percentText)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 396)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Aperçu", selection: $editor.mode) {
                    ForEach(CountdownEditor.PreviewMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 325)
                Spacer()
                Button {
                    editor.showSettings.toggle()
                } label: {
                    Label("Réglages", systemImage: editor.showSettings ? "chevron.up" : "slider.horizontal.3")
                }
            }
            Divider()
            HStack {
                Text(editor.mode == .desktop ? "Fonds d’écran" : "Économiseur d’écran")
                    .font(.headline)
                Spacer()
                if editor.mode == .saver {
                    Button("Tester l’économiseur macOS") {
                        Task { await editor.launchScreenSaver() }
                    }
                    .disabled(editor.isLaunchingScreenSaver)
                    .help("Lancer l’économiseur actuellement choisi dans macOS")
                } else {
                    Text("Bureau actif de chaque écran")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if editor.mode == .saver {
                screenSaverControls
            } else if wallpaper.displays.count > 1 {
                wallpaperSharingControls
            }
            if wallpaper.displays.isEmpty {
                Text("Aucun écran détecté").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(wallpaper.displays) { display in displayCard(display) }
                }
            }
            if editor.mode == .desktop, wallpaper.hasDisconnectedDisplay {
                Label("Un écran avec un compte à rebours est déconnecté.", systemImage: "display.trianglebadge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = editor.draft.validationError, !editor.showSettings {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let saveError = editor.saveError { Text(saveError).foregroundStyle(.red).font(.callout) }
        }
    }

    private var screenSaverControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.screenSaverInstallation != .available {
                let needsUpdate = editor.screenSaverInstallation == .updateRequired
                Label(needsUpdate ? "Module à mettre à jour" : "Module non installé", systemImage: "info.circle")
                    .fontWeight(.medium)
                Text("Installez le fichier CompteAReboursSaver.saver une seule fois pour votre compte.")
                    .foregroundStyle(.secondary)
                if needsUpdate {
                    Text("Après la mise à jour, les choix dans macOS s’appliquent sur chaque écran.")
                        .foregroundStyle(.secondary)
                }
                if let module = ScreenSaverInstallation.compiledModule() {
                    Button(needsUpdate ? "Ouvrir la mise à jour" : "Ouvrir l’installateur") {
                        if !NSWorkspace.shared.open(module) {
                            NSWorkspace.shared.activateFileViewerSelecting([module])
                        }
                    }
                } else {
                    Text("Le module intégré est introuvable. Recompilez l’application dans Xcode.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Module installé · Choix de l’économiseur dans macOS", systemImage: "checkmark.circle")
            }
            if #available(macOS 26, *) {
                if configuresScreenSaverByDisplay {
                    Link("Ouvrir Fond d’écran dans macOS", destination: Self.wallpaperSettings)
                    Text("Choisissez le moniteur dans le menu en haut, puis cliquez sur **Économiseur d’écran…**.")
                        .foregroundStyle(.secondary)
                } else {
                    Link("Ouvrir les réglages de l’économiseur", destination: Self.screenSaverSettings)
                }
                Text("Sous **Personnalisé**, vérifiez que **Compte à rebours** est affiché. Pour le choisir, ouvrez **Autre › Tout afficher**.")
                    .foregroundStyle(.secondary)
                Text("Pour retirer le compteur, sélectionnez Automatique ou resélectionnez votre ancien économiseur pour l’écran concerné.")
                    .foregroundStyle(.secondary)
            } else {
                Link("Ouvrir les réglages de l’économiseur", destination: Self.screenSaverSettings)
                Text("Choisissez Compte à rebours dans les réglages de l’économiseur. Pour le retirer, resélectionnez votre ancien économiseur.")
                    .foregroundStyle(.secondary)
            }
            if let error = editor.screenSaverError { Text(error).foregroundStyle(.red) }
        }
        .font(.callout)
    }

    private var wallpaperSharingControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if wallpaper.hasSharedWallpaper {
                Label("La même image du compte à rebours est affichée sur plusieurs écrans.", systemImage: "display.2")
                    .font(.callout.weight(.medium))
            }
            HStack {
                Text("Pour un cadrage par écran, désactivez « Afficher sur tous les espaces » dans macOS.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Link("Réglages du fond d’écran", destination: Self.wallpaperSettings)
            }
            .font(.caption)
        }
    }

    private func displayCard(_ monitor: WallpaperDisplay) -> some View {
        let selected = display?.id == monitor.id
        let status = wallpaper.statuses[monitor.id] ?? .unavailable
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                wallpaper.select(monitor.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: monitor.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 24))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.isMain ? "Écran principal" : "Écran secondaire")
                            .font(.subheadline.weight(.semibold))
                        Text("\(monitor.name) · \(monitor.resolution)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "eye")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Afficher l’aperçu sur \(monitor.name)")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if editor.mode == .desktop {
                HStack {
                    wallpaperStatus(status)
                    Spacer(minLength: 4)
                    if status == .applied || status == .pendingRestore {
                        Button("Rétablir") { wallpaper.restore(on: monitor) }
                            .help("Rétablir le fond précédent de \(monitor.name) ou le fond par défaut de macOS")
                    } else if status == .shared || status == .unmanaged {
                        Menu("Actions") {
                            Button(status == .shared ? "Adapter à cet écran" : "Réactiver") { apply(to: monitor) }
                                .disabled(editor.draft.validationError != nil)
                            Button("Remettre le fond par défaut") { wallpaper.restore(on: monitor) }
                        }
                    } else {
                        Button("Appliquer") { apply(to: monitor) }
                        .buttonStyle(.borderedProminent)
                        .disabled(editor.draft.validationError != nil)
                    }
                }
                if let error = wallpaper.errors[monitor.id] {
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("Ouvrir Réglages Système", destination: Self.wallpaperSettings).font(.caption)
                }
            } else {
                Button("Aperçu dans l’app") { editor.previewScreenSaver(on: monitor) }
                    .font(.callout)
                    .accessibilityLabel("Aperçu plein écran dans l’app sur \(monitor.name)")
                    .help("Afficher le compteur sur \(monitor.name), indépendamment du choix de macOS.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.36), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
    }

    private func apply(to monitor: WallpaperDisplay) {
        if editor.save() { wallpaper.apply(to: monitor, settings: editor.draft) }
    }

    private func wallpaperStatus(_ status: WallpaperController.DisplayStatus) -> some View {
        let label: String
        let symbol: String
        switch status {
        case .applied: (label, symbol) = ("Appliqué", "checkmark.circle.fill")
        case .notApplied: (label, symbol) = ("Non appliqué", "circle")
        case .unavailable: (label, symbol) = ("Fond indéterminé", "questionmark.circle")
        case .unmanaged: (label, symbol) = ("Visible, figé", "pause.circle")
        case .pendingRestore: (label, symbol) = ("À rétablir", "arrow.uturn.backward.circle")
        case .shared: (label, symbol) = ("Image partagée", "display.2")
        }
        return Label(label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(status == .applied ? Color.green : Color.secondary)
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Titre facultatif", text: $editor.draft.title, prompt: Text("Départ au Japon"))
            HStack(spacing: 16) {
                DatePicker("Début", selection: $editor.draft.start)
                DatePicker("Échéance", selection: $editor.draft.end)
            }
            if let error = editor.draft.validationError { Text(error).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack(spacing: 18) {
                colorPicker("Fond", keyPath: \.background)
                colorPicker("Texte", keyPath: \.text)
                colorPicker("Rectangles vides", keyPath: \.empty)
                colorPicker("Remplissage", keyPath: \.fill)
            }
            HStack {
                Menu("Palettes") {
                    Button("Claire") { editor.draft.palette = .light }
                    Button("Sombre") { editor.draft.palette = .dark }
                }
                .fixedSize()
                Spacer()
                Button("Enregistrer") {
                    if editor.save() { wallpaper.use(settings: editor.draft) }
                }
                .disabled(editor.draft.validationError != nil || editor.stored == editor.draft)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.36), in: .rect(cornerRadius: 12))
    }

    private func colorPicker(_ label: String, keyPath: WritableKeyPath<Palette, UInt32>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(nsColor: NSColor(rgb: editor.draft.palette[keyPath: keyPath])) },
            set: { if let rgb = NSColor($0).rgb { editor.draft.palette[keyPath: keyPath] = rgb } }
        ), supportsOpacity: false)
    }
}

private final class ScreenSaverPreviewWindow: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, renderer: CountdownRenderer) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        title = "Aperçu du compte à rebours"
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        level = .popUpMenu
        collectionBehavior = [.fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
        contentView = NSHostingView(rootView:
            CountdownPreview(renderer: renderer)
                .overlay(alignment: .bottomTrailing) {
                    Button("Fermer l’aperçu") { [weak self] in self?.close() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
        )
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        let didClose = onClose
        onClose = nil
        didClose?()
    }
}

private struct CountdownPreview: NSViewRepresentable {
    let renderer: CountdownRenderer

    func makeNSView(context: Context) -> RenderView { RenderView() }

    func updateNSView(_ view: RenderView, context: Context) {
        view.update(renderer)
    }

    final class RenderView: NSView {
        private var renderer: CountdownRenderer?
        private var visualState: CountdownRenderer.VisualState?
        private var backingScale: CGFloat { window?.backingScaleFactor ?? 1 }
        override var isFlipped: Bool { true }

        func update(_ renderer: CountdownRenderer) {
            self.renderer = renderer
            let next = renderer.visualState(in: bounds.size, backingScale: backingScale)
            if next != visualState {
                visualState = next
                needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let renderer, let context = NSGraphicsContext.current?.cgContext else { return }
            renderer.draw(in: bounds.size, context: context, backingScale: backingScale)
        }
    }
}
