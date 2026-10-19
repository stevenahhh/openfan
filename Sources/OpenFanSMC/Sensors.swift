import Foundation

// MARK: - Temperature inputs

/// Which sensor feeds a curve.
public enum FanControlInput: String, Codable, CaseIterable, Sendable {
    case max
    case cpu
    case gpu
    /// Mean of every battery temperature sensor.
    case battery
    /// The SMC's virtual system temperature TVS0, the value macOS Auto holds near 45 C.
    case system
}

// MARK: - Chip generation

/// The Apple silicon generation, from the chip's name (`Apple M3 Max` is 3). The temperature keys differ between
/// generations, while every model of one generation (MacBook Air and Pro, Mac mini, iMac, Mac Studio) shares them.
public struct ChipGeneration: Equatable, Sendable {
    /// Nil for a chip whose name carries no M generation.
    public let number: Int?

    public init(number: Int?) {
        self.number = number
    }

    public init(brand: String) {
        let words = brand.split(separator: " ")
        let model = words.first { $0.count > 1 && $0.first == "M" && $0.dropFirst().allSatisfy(\.isNumber) }
        number = model.flatMap { Int($0.dropFirst()) }
    }

    public static let current = ChipGeneration(brand: sysctlString("machdep.cpu.brand_string"))
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer)
}

// MARK: - Key catalogue

/// Temperature keys by generation. Discovery keeps only the keys this Mac has, so a key a smaller chip lacks costs one
/// probe at launch. M5 was verified on Mac17,9; M1 to M4 follow exelban/stats (MIT) and agoodkind/macos-smc-fan,
/// which agree on them, and were not verified here.
public enum SensorCatalog {
    static let cpuByGeneration: [Int: [String]] = [
        1: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
        2: ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        3: ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
            "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
        4: ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        // Super cores Tp00 to Tp0K, performance cores Tp0O to Tp0y; all 18 present on Mac17,9.
        5: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
            "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
            "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
    ]

    static let gpuByGeneration: [Int: [String]] = [
        1: ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
        2: ["Tg0f", "Tg0j"],
        3: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
        4: ["Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
        // Tg1g is absent on Mac17,9 (M5 Pro) and listed for the larger M5 GPUs.
        5: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
    ]

    /// A generation newer than the catalogue gets every known key, so it still finds the ones it kept.
    public static func cpuKeys(for generation: ChipGeneration) -> [String] {
        keys(cpuByGeneration, generation)
    }

    public static func gpuKeys(for generation: ChipGeneration) -> [String] {
        keys(gpuByGeneration, generation)
    }

    private static func keys(_ table: [Int: [String]], _ generation: ChipGeneration) -> [String] {
        if let number = generation.number, let known = table[number] { return known }
        var seen = Set<String>()
        return table.keys.sorted().flatMap { table[$0] ?? [] }.filter { seen.insert($0).inserted }
    }

    public static let cpuKeys = cpuKeys(for: .current)
    public static let gpuKeys = gpuKeys(for: .current)

    /// TB0T TB1T TB2T: the battery pack sensors (flt, Celsius), verified on Mac17,9. A desktop has none of them.
    public static let batteryKeys: [String] = ["TB0T", "TB1T", "TB2T"]

    /// Mean of the usable battery readings. A reading counts when it is finite, above 0 (a dead sensor reports
    /// 0.0) and not above the global ceiling; nil when none counts, so one bad sensor cannot skew the mean.
    public static func batteryMean(_ values: [Float]) -> Float? {
        let usable = values.filter { $0.isFinite && $0 > 0 && $0 <= temperatureCeiling }
        guard !usable.isEmpty else { return nil }
        return usable.reduce(0, +) / Float(usable.count)
    }

    /// Probed once at discovery so a Mac without it never pays the read cost.
    public static let systemKey = "TVS0"
    /// Plausible TVS0 values; a reading outside this window is a failed read, not a temperature.
    public static let systemRange: ClosedRange<Float> = 15...70

    /// Readings outside this window (or NaN) are discarded.
    public static let temperatureFloor: Float = 0
    public static let temperatureCeiling: Float = 130
}

// MARK: - Fan types

public struct FanInfo: Codable, Equatable, Sendable {
    public let index: Int
    public let minRPM: Float
    public let maxRPM: Float

    /// `F{n}md` on M5 (Mac17,9), `F{n}Md` on earlier Apple silicon and Intel. Telemetry finds out which one exists.
    public let modeKey: String

    public init(index: Int, minRPM: Float, maxRPM: Float, modeKey: String? = nil) {
        self.index = index
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.modeKey = modeKey ?? "F\(index)md"
    }

    public var targetKey: String { "F\(index)Tg" }
    public var actualKey: String { "F\(index)Ac" }

    /// Clamp a requested RPM into the fan's [Mn, Mx] range. Never returns a value outside it.
    public func clamp(_ rpm: Float) -> Float {
        min(max(rpm, minRPM), maxRPM)
    }

    /// Map a 0...100 percent of [Mn, Mx] to RPM. Out-of-band percents are clamped first.
    public func rpm(percent: Double) -> Float {
        let p = Float(min(max(percent, 0), 100))
        return clamp(minRPM + p / 100 * (maxRPM - minRPM))
    }
}

public struct FanReading: Equatable, Sendable {
    public let index: Int
    public let rpm: Float?
    public let targetRPM: Float?
    public let manual: Bool

    public init(index: Int, rpm: Float?, targetRPM: Float?, manual: Bool) {
        self.index = index
        self.rpm = rpm
        self.targetRPM = targetRPM
        self.manual = manual
    }
}

public struct SensorReading: Equatable, Sendable {
    public let cpu: Float?
    public let gpu: Float?
    /// Mean of the battery sensors.
    public let battery: Float?
    public let fans: [FanReading]
    /// TVS0, the filtered composite macOS Auto follows; it is not a die sensor.
    public let system: Float?

    public init(cpu: Float?, gpu: Float?, battery: Float? = nil, fans: [FanReading], system: Float? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
        self.fans = fans
        self.system = system
    }

    /// The temperature a preset's input selects.
    public func input(_ kind: FanControlInput) -> Float? {
        switch kind {
        case .cpu: return cpu
        case .gpu: return gpu
        case .battery: return battery
        case .system: return system
        case .max:
            switch (cpu, gpu) {
            case let (c?, g?): return max(c, g)
            case let (c?, nil): return c
            case let (nil, g?): return g
            default: return nil
            }
        }
    }
}

/// The groups of sensors one read covers. Every SMC key costs a kernel round trip, so a caller asks only for what it uses.
public struct SensorSet: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let cpu = SensorSet(rawValue: 1)
    public static let gpu = SensorSet(rawValue: 2)
    public static let battery = SensorSet(rawValue: 4)
    /// What the fans actually do: speed and mode.
    public static let fans = SensorSet(rawValue: 8)
    /// What the fans were told to do. Only a display wants it; the control loop watches the fans' real speed.
    public static let fanTargets = SensorSet(rawValue: 16)
    public static let system = SensorSet(rawValue: 32)
    public static let all: SensorSet = [.cpu, .gpu, .battery, .fans, .fanTargets, .system]
}

// MARK: - Reader

/// Discovers which sensor keys exist once, then reads them each tick.
public final class Telemetry {
    public private(set) var fans: [FanInfo] = []
    /// False on a desktop: no battery sensor exists.
    public let hasBattery: Bool
    public let hasSystem: Bool
    /// M3 and M4 MacBook Pros keep the fans in system mode until the force-test key `Ftst` is set.
    public let hasForceTest: Bool

    private let smc: SMC
    private let presentCPUKeys: [String]
    private let presentGPUKeys: [String]
    private let presentBatteryKeys: [String]

    /// Discovery happens exactly once here. A key that does not exist is probed once during init and
    /// then never read again (an absent key costs about 50x a present one), so the discovered lists
    /// are what every later tick reads.
    public init(smc: SMC) throws {
        self.smc = smc

        self.presentCPUKeys = SensorCatalog.cpuKeys.filter { smc.keyExists($0) }
        self.presentGPUKeys = SensorCatalog.gpuKeys.filter { smc.keyExists($0) }
        self.presentBatteryKeys = SensorCatalog.batteryKeys.filter { smc.keyExists($0) }
        self.hasBattery = !presentBatteryKeys.isEmpty
        self.hasSystem = smc.keyExists(SensorCatalog.systemKey)
        self.hasForceTest = smc.keyExists("Ftst")

        // FNum is a ui8 key on this platform; fall back to a ui32 variant if that is what is present.
        var fanCount = 0
        if let count = try? smc.readUInt8("FNum") {
            fanCount = Int(count)
        } else if let count = try? smc.readUInt32("FNum") {
            fanCount = Int(count)
        }

        var discovered: [FanInfo] = []
        for index in 0..<fanCount {
            // Read the real limits; never hardcode them. A fan whose limits cannot be read is not
            // usable (clamping to [0, 0] would stop it), so it is skipped rather than defaulted.
            guard let minRPM = try? smc.readFloat("F\(index)Mn"),
                  let maxRPM = try? smc.readFloat("F\(index)Mx"),
                  minRPM.isFinite, maxRPM.isFinite, minRPM > 0, maxRPM > minRPM else { continue }
            // A fan without a mode key cannot be handed back to the system, so it is never controlled.
            guard let modeKey = ["F\(index)md", "F\(index)Md"].first(where: { smc.keyExists($0) }) else { continue }
            discovered.append(FanInfo(index: index, minRPM: minRPM, maxRPM: maxRPM, modeKey: modeKey))
        }
        self.fans = discovered
    }

    /// Reads CPU max, GPU max, the battery mean and per-fan actual/target/manual, limited to `sensors`. A group that
    /// is left out reads as nil (no fan readings at all when `.fans` is left out). Failed or out-of-range values are nil.
    public func read(_ sensors: SensorSet = .all) -> SensorReading {
        let cpu = sensors.contains(.cpu) ? maxTemperature(presentCPUKeys) : nil
        let gpu = sensors.contains(.gpu) ? maxTemperature(presentGPUKeys) : nil

        var readings: [FanReading] = []
        if sensors.contains(.fans) {
            readings.reserveCapacity(fans.count)
            for fan in fans {
                let rpm = validRPM(try? smc.readFloat(fan.actualKey), fan: fan)
                let target = sensors.contains(.fanTargets) ? validRPM(try? smc.readFloat(fan.targetKey), fan: fan) : nil
                let manual = (try? smc.readUInt8(fan.modeKey)) == 1
                readings.append(FanReading(index: fan.index, rpm: rpm, targetRPM: target, manual: manual))
            }
        }

        let battery = sensors.contains(.battery)
            ? SensorCatalog.batteryMean(presentBatteryKeys.compactMap { try? smc.readFloat($0) })
            : nil
        let system = sensors.contains(.system) && hasSystem
            ? (try? smc.readFloat(SensorCatalog.systemKey)).flatMap(validSystem)
            : nil
        return SensorReading(cpu: cpu, gpu: gpu, battery: battery, fans: readings, system: system)
    }

    // MARK: Internals

    /// Highest valid reading among the keys, or nil when none is valid.
    private func maxTemperature(_ keys: [String]) -> Float? {
        var best: Float?
        for key in keys {
            guard let raw = try? smc.readFloat(key), let value = validTemperature(raw) else { continue }
            best = best.map { max($0, value) } ?? value
        }
        return best
    }

    private func validSystem(_ value: Float) -> Float? {
        guard value.isFinite, SensorCatalog.systemRange.contains(value) else { return nil }
        return value
    }

    private func validTemperature(_ value: Float) -> Float? {
        guard value.isFinite,
              value >= SensorCatalog.temperatureFloor,
              value <= SensorCatalog.temperatureCeiling else { return nil }
        return value
    }

    /// A fan RPM is valid when it is finite, non-negative and not absurdly above the fan's own maximum.
    private func validRPM(_ value: Float?, fan: FanInfo) -> Float? {
        guard let value, value.isFinite, value >= 0, value <= fan.maxRPM + 500 else { return nil }
        return value
    }
}
