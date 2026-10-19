import Foundation
import OpenFanSMC

func numericValue(_ smc: SMC, key: String) -> Float? {
    if let value = try? smc.readFloat(key), value.isFinite { return value }
    if let value = try? smc.readUInt8(key) { return Float(value) }
    if let value = try? smc.readUInt32(key) { return Float(value) }
    return nil
}

func logColumns(smc: SMC, telemetry: Telemetry) -> [String] {
    var columns: [String] = []
    for fan in telemetry.fans {
        columns.append(fan.actualKey)
        columns.append(fan.targetKey)
        columns.append(fan.modeKey)
    }
    let count = (try? smc.keyCount()) ?? 0
    for index in 0..<count {
        guard let key = try? smc.key(at: index) else { continue }
        if key.hasPrefix("T") {
            guard let value = try? smc.readFloat(key),
                  value.isFinite, value >= SensorCatalog.temperatureFloor, value <= SensorCatalog.temperatureCeiling
            else { continue }
            columns.append(key)
        } else if key.hasPrefix("P") {
            guard let value = try? smc.readFloat(key),
                  value.isFinite, value >= powerFloorWatts, value <= powerCeilingWatts
            else { continue }
            columns.append(key)
        }
    }
    return columns
}

func durationSeconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

func csvNumber(_ value: Double) -> String {
    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
}

func runLog(smc: SMC, telemetry: Telemetry, duration: Int, interval: Double, path: String) {
    let columns = logColumns(smc: smc, telemetry: telemetry)
    let expandedPath = (path as NSString).expandingTildeInPath
    FileManager.default.createFile(atPath: expandedPath, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: expandedPath) else {
        FileHandle.standardError.write(Data("OpenFanProbe: cannot open \(expandedPath) for writing\n".utf8))
        exit(1)
    }
    defer { try? handle.close() }

    do {
        try handle.write(contentsOf: Data(("t," + columns.joined(separator: ",") + "\n").utf8))
        try handle.synchronize()

        let clock = ContinuousClock()
        let start = clock.now
        var rows = 0
        var tick = 0
        while Double(tick) * interval < Double(duration) {
            let deadline = start + .seconds(Double(tick) * interval)
            if clock.now < deadline {
                let remaining = durationSeconds(deadline - clock.now)
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            }
            let elapsed = durationSeconds(clock.now - start)
            let cells = columns.map { key in
                numericValue(smc, key: key).map { csvNumber(Double($0)) } ?? ""
            }
            let row = csvNumber(elapsed) + (cells.isEmpty ? "" : "," + cells.joined(separator: ",")) + "\n"
            try handle.write(contentsOf: Data(row.utf8))
            try handle.synchronize()
            rows += 1
            tick += 1
        }
        FileHandle.standardError.write(Data("OpenFanProbe: wrote \(columns.count) columns and \(rows) rows to \(expandedPath)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("OpenFanProbe: CSV write failed: \(error)\n".utf8))
        exit(1)
    }
}
