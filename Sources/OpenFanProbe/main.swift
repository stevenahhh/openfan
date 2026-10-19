import Foundation
import OpenFanCore
import OpenFanSMC

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

func number(_ value: Float?, digits: Int = 1) -> String {
    guard let value, value.isFinite else { return "n/a" }
    return String(format: "%.\(digits)f", value)
}

let powerFloorWatts: Float = 0
let powerCeilingWatts: Float = 500

let usageLine = "usage: OpenFanProbe [log <seconds> <output.csv> [--interval <s>]]\n"

func exitWithUsage() -> Never {
    FileHandle.standardError.write(Data(usageLine.utf8))
    exit(2)
}

enum Mode {
    case report
    case log(duration: Int, interval: Double, path: String)
}

func parseMode(_ arguments: [String]) -> Mode {
    guard let command = arguments.first else { return .report }
    guard command == "log" else { exitWithUsage() }

    var positionals: [String] = []
    var interval: Double = 1
    var sawInterval = false
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--interval" {
            guard !sawInterval,
                  index + 1 < arguments.count,
                  let value = Double(arguments[index + 1]),
                  value.isFinite, value > 0
            else { exitWithUsage() }
            interval = value
            sawInterval = true
            index += 2
        } else if argument.hasPrefix("--") {
            exitWithUsage()
        } else {
            positionals.append(argument)
            index += 1
        }
    }
    guard positionals.count == 2,
          let duration = Int(positionals[0]),
          duration > 0
    else { exitWithUsage() }
    return .log(duration: duration, interval: interval, path: positionals[1])
}

func report(smc: SMC, telemetry: Telemetry) {
    print("""
    # OpenFanProbe report

    Read-only: nothing here writes to the SMC. Paste it into your pull request as it is.

    ## Machine

    | | |
    |---|---|
    | Model identifier | \(sysctlString("hw.model")) |
    | Chip | \(sysctlString("machdep.cpu.brand_string")) |
    | macOS | \(ProcessInfo.processInfo.operatingSystemVersionString) |
    | SMC keys listed | \((try? smc.keyCount()).map(String.init) ?? "n/a") |
    | Chip generation | \(ChipGeneration.current.number.map { "M\($0)" } ?? "unknown: every catalogued key is tried") |
    | Force-test key `Ftst` | \(telemetry.hasForceTest ? "present (M3/M4 style: manual mode is unlocked through it)" : "absent (manual mode is written directly)") |
    | Battery sensors | \(telemetry.hasBattery ? "present" : "none (a desktop Mac)") |

    ## Fans

    | fan | min rpm | max rpm | now rpm | mode key | mode (0 = system) |
    |---|---|---|---|---|---|
    """)

    let reading = telemetry.read(.all)
    if telemetry.fans.isEmpty {
        print("| none found | | | | | |")
    }
    for fan in telemetry.fans {
        let now = reading.fans.first { $0.index == fan.index }
        print("| F\(fan.index) | \(Int(fan.minRPM)) | \(Int(fan.maxRPM)) | \(number(now?.rpm, digits: 0)) | `\(fan.modeKey)` | \(now.map { $0.manual ? "1" : "0" } ?? "n/a") |")
    }

    let groups: [(String, [String])] = [
        ("CPU", SensorCatalog.cpuKeys),
        ("GPU", SensorCatalog.gpuKeys),
        ("battery", SensorCatalog.batteryKeys),
    ]
    print("""

    ## Catalogued sensors

    A group with nothing present reads as `--` in OpenFan: add your Mac's keys to `SensorCatalog`.

    | group | present | missing |
    |---|---|---|
    """)
    for (name, keys) in groups {
        let found = keys.filter { smc.keyExists($0) }
        let missing = keys.filter { !smc.keyExists($0) }
        print("| \(name) | \(found.count) of \(keys.count) | \(missing.isEmpty ? "none" : missing.joined(separator: " ")) |")
    }

    print("""

    ## Readings now

    | | |
    |---|---|
    | CPU (hottest sensor) | \(number(reading.cpu)) °C |
    | GPU (hottest sensor) | \(number(reading.gpu)) °C |
    | Battery (mean) | \(number(reading.battery)) °C |
    | Memory pressure | \(MemoryPressure.read()?.label ?? "n/a") |

    ## Temperature keys the SMC lists

    Keys that start with `T`, hold a 4-byte float and read between 0 and 130. A key that is not catalogued yet is a
    candidate for `SensorCatalog`; which group it belongs to is for you to judge from its position and behaviour under load.

    | key | °C | catalogued |
    |---|---|---|
    """)
    let catalogued = Set(groups.flatMap { $0.1 })
    let count = (try? smc.keyCount()) ?? 0
    for index in 0..<count {
        guard let key = try? smc.key(at: index), key.hasPrefix("T"),
              let value = try? smc.readFloat(key), value.isFinite, value > 0, value <= SensorCatalog.temperatureCeiling
        else { continue }
        print("| \(key) | \(number(value)) | \(catalogued.contains(key) ? "yes" : "no") |")
    }

    print("""

    ## Virtual and power keys

    `TV` keys are virtual temperatures in °C; `P` keys are power readings in W. Only finite readings in range are listed.

    | key | value | kind |
    |---|---|---|
    """)
    for index in 0..<count {
        guard let key = try? smc.key(at: index) else { continue }
        if key.hasPrefix("TV"),
           let value = try? smc.readFloat(key),
           value.isFinite, value >= SensorCatalog.temperatureFloor, value <= SensorCatalog.temperatureCeiling {
            print("| \(key) | \(number(value)) | virtual temperature |")
        } else if key.hasPrefix("P"),
                  let value = try? smc.readFloat(key),
                  value.isFinite, value >= powerFloorWatts, value <= powerCeilingWatts {
            print("| \(key) | \(number(value)) | power |")
        }
    }
}

let mode = parseMode(Array(CommandLine.arguments.dropFirst()))

let smc: SMC
let telemetry: Telemetry
do {
    smc = try SMC()
    telemetry = try Telemetry(smc: smc)
} catch {
    FileHandle.standardError.write(Data("OpenFanProbe: cannot open the SMC: \(error)\n".utf8))
    exit(1)
}

switch mode {
case .report:
    report(smc: smc, telemetry: telemetry)
case let .log(duration, interval, path):
    runLog(smc: smc, telemetry: telemetry, duration: duration, interval: interval, path: path)
}
