import AppKit
import CoreGraphics
import Darwin

struct Palette: Codable, Equatable {
    var background: UInt32
    var text: UInt32
    var empty: UInt32
    var fill: UInt32

    static let light = Palette(background: 0xe2efea, text: 0x173631, empty: 0xb5d1cb, fill: 0x2e7968)
    static let dark = Palette(background: 0x14292e, text: 0xedf7f3, empty: 0x34525a, fill: 0x7dceb3)
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    var rgb: UInt32? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((min(1, max(0, value)) * 255).rounded())
        }
        return (channel(color.redComponent) << 16) | (channel(color.greenComponent) << 8) | channel(color.blueComponent)
    }
}

struct CountdownSettings: Codable, Equatable {
    static let hour: TimeInterval = 3_600
    static let day = 24 * hour
    static let maximumDays = 10_000

    var title = ""
    var start: Date
    var end: Date
    var palette: Palette = .light

    var validationError: String? {
        guard title.utf8.count <= 1024, title.count <= 120 else {
            return "Le titre est limité à 120 caractères et 1 024 octets."
        }
        return dateValidationError
    }

    fileprivate var dateValidationError: String? {
        let duration = end.timeIntervalSince(start)
        guard duration.isFinite, duration > 0 else { return "L’échéance doit suivre le début." }
        guard duration <= Double(Self.maximumDays) * Self.day else { return "La durée maximale est de 10 000 jours." }
        return nil
    }

    static func initial(now: Date = .now) -> Self {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let end = calendar.date(byAdding: .month, value: 6, to: start) ?? start.addingTimeInterval(184 * day)
        return Self(start: start, end: end)
    }
}

struct CountdownSnapshot: Equatable {
    let tileCount: Int
    let elapsedHours: Int
    let daysRemaining: Int
    let hoursRemaining: Int
    let progress: Double
    let isComplete: Bool

    init?(settings: CountdownSettings, now: Date) {
        guard settings.validationError == nil else { return nil }
        let duration = settings.end.timeIntervalSince(settings.start)
        let elapsed = min(duration, max(0, now.timeIntervalSince(settings.start)))
        let remaining = duration - elapsed
        tileCount = Int(ceil(duration / CountdownSettings.day))
        elapsedHours = Int(floor(elapsed / CountdownSettings.hour))
        daysRemaining = Int(floor(remaining / CountdownSettings.day))
        hoursRemaining = Int(ceil(remaining / CountdownSettings.hour))
        progress = elapsed / duration
        isComplete = remaining == 0
    }

    var percent: Int { Int(floor(progress * 100)) }
    var daysText: String { isComplete ? "Terminé" : quantity(daysRemaining, unit: "jour") }
    var hoursText: String { quantity(hoursRemaining, unit: "heure") }
    var percentText: String { "\(percent)\u{202f}%" }

    func fill(at index: Int) -> CGFloat {
        isComplete ? 1 : CGFloat(min(24, max(0, elapsedHours - index * 24))) / 24
    }

    private func quantity(_ count: Int, unit: String) -> String {
        let number = count.formatted(.number.locale(Locale(identifier: "fr_FR")))
        return "\(number) \(unit)\(count == 1 ? "" : "s")"
    }
}

extension NSScreen {
    @MainActor var displayIdentifier: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

struct CountdownPreferences {
    // macOS hosts legacy savers in a different preferences container. Both processes
    // can read this location under the same user ID without accessing that container.
    private let directory: URL
    private static let filename = "countdown.json"
    private static let maximumBytes = 16 * 1024

    init(sharedDirectory: URL = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)) {
        directory = sharedDirectory.appending(path: "fr.comptearebours.macos.\(getuid())", directoryHint: .isDirectory)
    }

    func load() -> CountdownSettings? {
        guard let settings = loadDraft(), settings.validationError == nil else { return nil }
        return settings
    }

    func loadDraft() -> CountdownSettings? {
        guard let data = read(),
              let settings = try? JSONDecoder().decode(CountdownSettings.self, from: data),
              settings.dateValidationError == nil else { return nil }
        return settings
    }

    func save(_ settings: CountdownSettings) throws {
        guard settings.validationError == nil else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONEncoder().encode(settings)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteUnknown) }
        try write(data)
    }

    var hasSavedFile: Bool {
        var info = stat()
        let path = directory.appending(path: Self.filename).path
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    private func read() -> Data? {
        guard let parent = try? openPrivateDirectory() else { return nil }
        defer { close(parent) }
        // Nonblocking open lets us inspect the descriptor without waiting on a FIFO.
        let descriptor = openat(parent, Self.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let info = privateStat(descriptor, type: S_IFREG),
              info.st_size > 0, info.st_size <= Self.maximumBytes,
              let data = try? file.read(upToCount: Self.maximumBytes + 1),
              data.count <= Self.maximumBytes else { return nil }
        return data
    }

    private func write(_ data: Data) throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw posixError()
        }
        let parent = try openPrivateDirectory()
        defer { close(parent) }
        let temporary = UUID().uuidString + ".tmp"
        let descriptor = openat(parent, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var renamed = false
        defer { if !renamed { unlinkat(parent, temporary, 0) } }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
        guard renameat(parent, temporary, parent, Self.filename) == 0 else {
            throw posixError()
        }
        renamed = true
    }

    private func openPrivateDirectory() throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        guard privateStat(descriptor, type: S_IFDIR) != nil else {
            close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        return descriptor
    }

    private func privateStat(_ descriptor: Int32, type: mode_t) -> stat? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == type, (info.st_mode & 0o077) == 0 else { return nil }
        return info
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
