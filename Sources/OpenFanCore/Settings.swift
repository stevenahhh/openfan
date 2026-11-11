import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultTemplate = "{max}\u{00B0} {rpm}"
    public static let maxTemplateLength = 120
    /// How fast a gradual cool-down lets the fans fall, percent of their range per second: full speed reaches the
    /// minimum in 100 s, long enough to hear no step and short enough not to outlast the heat.
    public static let gradualCooldownRate: Double = 1

    public var version: Int
    public var menuBarTemplate: String
    public var showPressureDot: Bool
    /// Header fan values: rpm when true, percent of the fan's range when false.
    public var fanUnitsRPM: Bool
    /// Curves slow the fans gradually as the Mac cools; false follows the curve down at once, as before the option.
    public var gradualCooldown: Bool

    public init(
        version: Int = AppSettings.currentVersion,
        menuBarTemplate: String = AppSettings.defaultTemplate,
        showPressureDot: Bool = true,
        fanUnitsRPM: Bool = false,
        gradualCooldown: Bool = false
    ) {
        self.version = version
        self.menuBarTemplate = menuBarTemplate
        self.showPressureDot = showPressureDot
        self.fanUnitsRPM = fanUnitsRPM
        self.gradualCooldown = gradualCooldown
    }

    private enum CodingKeys: String, CodingKey {
        case version, menuBarTemplate, showPressureDot, fanUnitsRPM, gradualCooldown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? AppSettings.currentVersion
        menuBarTemplate = try container.decodeIfPresent(String.self, forKey: .menuBarTemplate) ?? AppSettings.defaultTemplate
        showPressureDot = try container.decodeIfPresent(Bool.self, forKey: .showPressureDot) ?? true
        fanUnitsRPM = try container.decodeIfPresent(Bool.self, forKey: .fanUnitsRPM) ?? false
        gradualCooldown = try container.decodeIfPresent(Bool.self, forKey: .gradualCooldown) ?? false
    }

    static func clamped(_ template: String) -> String {
        String(template.prefix(maxTemplateLength))
    }

    fileprivate mutating func sanitize() {
        menuBarTemplate = AppSettings.clamped(menuBarTemplate)
    }
}

/// ~/Library/Application Support/OpenFan/settings.json. Loading never fails and never writes: a missing file
/// means defaults, an unreadable one is moved to settings.json.bak.
public final class SettingsStore {
    public static var defaultURL: URL {
        PresetStore.defaultURL.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    public let url: URL
    public private(set) var settings = AppSettings()

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
    }

    @discardableResult
    public func load() -> AppSettings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            settings = AppSettings()
            return settings
        }
        do {
            var decoded = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
            decoded.sanitize()
            settings = decoded
        } catch {
            let backup = URL(fileURLWithPath: url.path + ".bak")
            try? fileManager.removeItem(at: backup)
            try? fileManager.moveItem(at: url, to: backup)
            settings = AppSettings()
        }
        return settings
    }

    public func setTemplate(_ template: String) {
        settings.menuBarTemplate = AppSettings.clamped(template)
    }

    public func setShowPressureDot(_ show: Bool) {
        settings.showPressureDot = show
    }

    public func setFanUnitsRPM(_ showsRPM: Bool) {
        settings.fanUnitsRPM = showsRPM
    }

    public func setGradualCooldown(_ gradual: Bool) {
        settings.gradualCooldown = gradual
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: [.atomic])
    }
}
