import Foundation
import OpenFanSMC

public enum ProtocolError: Error, CustomStringConvertible, Equatable {
    case emptyLine
    case tooLong(max: Int)
    case unknownCommand(String)
    case malformed(String)
    case badValue(String)

    public var description: String {
        switch self {
        case .emptyLine: return "empty command"
        case .tooLong(let max): return "line longer than \(max) bytes"
        case .unknownCommand(let c): return "unknown command: \(c)"
        case .malformed(let d): return "malformed command: \(d)"
        case .badValue(let d): return "bad value: \(d)"
        }
    }
}

/// Fixed filesystem paths shared by the app, the helper and the install scripts.
public enum HelperPaths {
    public static let label = "com.stevenahhh.openfan.helper"
    public static let socketPath = "/var/run/com.stevenahhh.openfan.sock"
    public static let toolPath = "/Library/PrivilegedHelperTools/com.stevenahhh.openfan.helper"
    public static let revisionPath = "/Library/PrivilegedHelperTools/com.stevenahhh.openfan.helper.revision"
    public static let daemonPlistPath = "/Library/LaunchDaemons/com.stevenahhh.openfan.helper.plist"
    public static let logPath = "/var/log/com.stevenahhh.openfan.helper.log"
    public static let maxLineBytes = 512
}

/// One line-protocol command, newline terminated over the Unix socket.
///
/// PING | STATUS | AUTO | CURVE <max|cpu|gpu|battery> <t:p,t:p,...> | FIXED <percent> |
/// HOLD <max|cpu|gpu|system> <targetC>
public enum HelperCommand: Equatable, Sendable {
    case ping
    case status
    case auto
    case curve(input: FanControlInput, points: [CurvePoint])
    case fixed(percent: Double)
    case hold(input: FanControlInput, target: Double)

    /// Temperatures a hold targets. Below 20 C the fans would be inaudible anyway; above 110 C
    /// the machine is already throttling, so such a target is far more likely a typo than intent.
    public static let holdTargetRange: ClosedRange<Double> = 20...110

    /// Parses one wire line. Rejects empty lines, over-long lines, unknown verbs, malformed bodies and
    /// non-finite / out-of-range numeric values (see ProtocolError).
    public static func parse(_ line: String) throws -> HelperCommand {
        if line.utf8.count > HelperPaths.maxLineBytes {
            throw ProtocolError.tooLong(max: HelperPaths.maxLineBytes)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ProtocolError.emptyLine
        }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = parts.first else { throw ProtocolError.emptyLine }

        switch verb.uppercased() {
        case "PING":
            guard parts.count == 1 else { throw ProtocolError.malformed("PING takes no arguments") }
            return .ping
        case "STATUS":
            guard parts.count == 1 else { throw ProtocolError.malformed("STATUS takes no arguments") }
            return .status
        case "AUTO":
            guard parts.count == 1 else { throw ProtocolError.malformed("AUTO takes no arguments") }
            return .auto
        case "CURVE":
            guard parts.count == 3 else { throw ProtocolError.malformed("CURVE needs <input> <points>") }
            guard let input = FanControlInput(rawValue: parts[1]) else {
                throw ProtocolError.badValue("unknown curve input \(parts[1])")
            }
            let points = try parsePoints(parts[2])
            do {
                try FanCurve(points: points).validate()
            } catch let error as CurveError {
                throw ProtocolError.badValue(error.description)
            }
            return .curve(input: input, points: points)
        case "FIXED":
            guard parts.count == 2 else { throw ProtocolError.malformed("FIXED needs <percent>") }
            guard let percent = Double(parts[1]), percent.isFinite else {
                throw ProtocolError.badValue("fixed percent is not a finite number: \(parts[1])")
            }
            guard percent >= 0, percent <= 100 else {
                throw ProtocolError.badValue("fixed percent outside 0...100: \(parts[1])")
            }
            return .fixed(percent: percent)
        case "HOLD":
            guard parts.count == 3 else { throw ProtocolError.malformed("HOLD needs <input> <target>") }
            guard let input = FanControlInput(rawValue: parts[1]) else {
                throw ProtocolError.badValue("unknown hold input \(parts[1])")
            }
            // The battery reads far too slowly to steer a control loop.
            guard input != .battery else { throw ProtocolError.badValue("hold cannot follow the battery") }
            guard let target = Double(parts[2]), target.isFinite else {
                throw ProtocolError.badValue("hold target is not a finite number: \(parts[2])")
            }
            guard holdTargetRange.contains(target) else {
                throw ProtocolError.badValue("hold target outside \(number(holdTargetRange.lowerBound))...\(number(holdTargetRange.upperBound)): \(parts[2])")
            }
            return .hold(input: input, target: target)
        default:
            throw ProtocolError.unknownCommand(verb)
        }
    }

    /// Parses "t:p,t:p,..." into points, rejecting non-finite numbers and fewer than two points.
    private static func parsePoints(_ token: String) throws -> [CurvePoint] {
        let items = token.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var points: [CurvePoint] = []
        for item in items {
            let components = item.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard components.count == 2 else {
                throw ProtocolError.malformed("point is not t:p: \(item)")
            }
            guard let t = Double(components[0]), t.isFinite else {
                throw ProtocolError.badValue("non-finite temperature: \(components[0])")
            }
            guard let p = Double(components[1]), p.isFinite else {
                throw ProtocolError.badValue("non-finite percent: \(components[1])")
            }
            points.append(CurvePoint(t: t, p: p))
        }
        guard points.count >= FanCurve.minPoints else {
            throw ProtocolError.badValue("curve needs at least 2 points (has \(points.count))")
        }
        return points
    }

    public var serialized: String {
        switch self {
        case .ping: return "PING"
        case .status: return "STATUS"
        case .auto: return "AUTO"
        case .curve(let input, let points):
            let list = points.map { "\(Self.number($0.t)):\(Self.number($0.p))" }.joined(separator: ",")
            return "CURVE \(input.rawValue) \(list)"
        case .fixed(let percent):
            return "FIXED \(Self.number(percent))"
        case .hold(let input, let target):
            return "HOLD \(input.rawValue) \(Self.number(target))"
        }
    }

    /// Shortest decimal form: integers print without a fractional part.
    public static func number(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}

public enum HelperMode: String, Equatable, Sendable, CaseIterable {
    case auto
    case curve
    case fixed
    case hold
    case panic
    case monitor
}

/// Reply to STATUS; also carried as the tail of a PING reply when the app asks for it.
public struct HelperStatus: Equatable, Sendable {
    public var mode: HelperMode
    /// Temperature that drove the last decision (nil in auto/monitor).
    public var inputTemperature: Double?
    /// Per-fan target RPM in fan order.
    public var targetRPM: [Float]
    public var writes: Int
    /// e.g. "smc:0x82" when the helper degraded to monitor mode.
    public var error: String?

    public init(mode: HelperMode, inputTemperature: Double? = nil, targetRPM: [Float] = [], writes: Int = 0, error: String? = nil) {
        self.mode = mode
        self.inputTemperature = inputTemperature
        self.targetRPM = targetRPM
        self.writes = writes
        self.error = error
    }

    /// "OK mode=<mode> temp=<t|-> rpm=<r0,r1|-> writes=<n>" plus " err=<e>" when error is set.
    public var serialized: String {
        let temperature = inputTemperature.map { String($0) } ?? "-"
        let rpm = targetRPM.isEmpty ? "-" : targetRPM.map { String($0) }.joined(separator: ",")
        var line = "OK mode=\(mode.rawValue) temp=\(temperature) rpm=\(rpm) writes=\(writes)"
        if let error {
            line += " err=\(error)"
        }
        return line
    }

    /// Exact inverse of serialized; returns nil on missing/unknown mode, non-numeric rpm, or any junk.
    public static func parse(_ line: String) -> HelperStatus? {
        let tokens = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        guard tokens.count >= 5, tokens[0] == "OK" else { return nil }
        guard let modeName = value(of: "mode=", in: tokens[1]),
              let mode = HelperMode(rawValue: modeName) else { return nil }
        guard let temperatureToken = value(of: "temp=", in: tokens[2]) else { return nil }
        var temperature: Double? = nil
        if temperatureToken != "-" {
            guard let parsed = Double(temperatureToken), parsed.isFinite else { return nil }
            temperature = parsed
        }
        guard let rpmToken = value(of: "rpm=", in: tokens[3]) else { return nil }
        var rpm: [Float] = []
        if rpmToken != "-" {
            for component in rpmToken.split(separator: ",", omittingEmptySubsequences: false) {
                guard let parsed = Float(component), parsed.isFinite else { return nil }
                rpm.append(parsed)
            }
        }
        guard let writesToken = value(of: "writes=", in: tokens[4]),
              let writes = Int(writesToken) else { return nil }
        var error: String? = nil
        if tokens.count > 5 {
            let remainder = tokens[5...].joined(separator: " ")
            guard remainder.hasPrefix("err=") else { return nil }
            error = String(remainder.dropFirst(4))
        }
        return HelperStatus(mode: mode, inputTemperature: temperature, targetRPM: rpm, writes: writes, error: error)
    }

    /// Returns the text after `prefix` when `token` starts with it, otherwise nil.
    private static func value(of prefix: String, in token: String) -> String? {
        guard token.hasPrefix(prefix) else { return nil }
        return String(token.dropFirst(prefix.count))
    }
}
