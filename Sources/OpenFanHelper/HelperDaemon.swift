import Foundation
import IOKit
import IOKit.pwr_mgt
import OpenFanSMC
import OpenFanCore
import OpenFanControl

/// IOKit power message codes. They are C macros Swift cannot import, so the numeric values live here.
private enum PowerMessage {
    static let canSystemSleep: UInt32 = 0xe000_0270
    static let systemWillSleep: UInt32 = 0xe000_0280
    static let systemWillNotSleep: UInt32 = 0xe000_0290
    static let systemHasPoweredOn: UInt32 = 0xe000_0300
    static let systemWillPowerOn: UInt32 = 0xe000_0320
}

/// C-compatible callback: no captures, the daemon travels through refcon.
private let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
    guard let refcon else { return }
    let daemon = Unmanaged<HelperDaemon>.fromOpaque(refcon).takeUnretainedValue()
    daemon.handlePower(message: messageType, argument: messageArgument)
}

/// A refusal raised by the daemon's own write guards (not by the SMC).
private enum WriteGuardError: Error, CustomStringConvertible {
    case unknownFan(Int)
    case invalidTarget(fan: Int)
    case manualBeforeTarget(fan: Int)

    var description: String {
        switch self {
        case .unknownFan(let fan): return "no such fan: \(fan)"
        case .invalidTarget(let fan): return "refusing a target outside [Mn, Mx] for fan \(fan)"
        case .manualBeforeTarget(let fan): return "refusing md=1 before any target was written for fan \(fan)"
        }
    }

    var code: String {
        switch self {
        case .unknownFan: return "nofan"
        case .invalidTarget: return "target"
        case .manualBeforeTarget: return "order"
        }
    }
}

/// The daemon: owns the SMC connection, the controller, the socket server, the tick timer, the lease
/// and the sleep/signal handling. Everything after start() runs on `queue`.
final class HelperDaemon {
    /// The app pings every 5 s while it controls; this much silence means the app is gone.
    private static let leaseNanoseconds: UInt64 = 12_000_000_000

    private let options: HelperOptions
    private let queue = DispatchQueue(label: "com.stevenahhh.openfan.helper")
    private let smc: SMC
    private let telemetry: Telemetry
    private let fans: [FanInfo]
    private let controller: FanController
    private var server: SocketServer?
    private var tickTimer: DispatchSourceTimer?

    private var controlling: ClientConnection?
    private var lastRenewal: UInt64 = 0
    private var activeInput: FanControlInput = .max
    private var monitorOnly = false
    private var asleep = false
    /// True once an md=1 write was attempted and no release has succeeded since. While set, a release
    /// writes md=0 unconditionally, because the readback of md can lag the write.
    private var engaged = false
    /// Fans whose F{n}Tg was written at least once. md=1 on any other fan would stop it (target 0).
    private var targetWritten: Set<Int> = []
    /// True while this helper holds `Ftst` = 1. Every release clears it: left set, macOS's thermal management stays off.
    private var forceTestSet = false
    private var manualFans: Set<Int> = []
    private var lastTemperature: Double?
    private var lastTargets: [Int: Float] = [:]
    private var loggedMode: HelperMode = .auto
    private var systemInputWatch = SystemInputWatch()
    private var systemInputStuck = false
    /// Monotonic timestamp of the previous hold tick; nil starts a new hold session at dt 1.0.
    private var lastControlTick: UInt64?

    private var powerRoot: io_connect_t = 0
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: Boot

    /// Startup steps 2-4: open SMC and telemetry, reset fans left manual by a crashed instance, build
    /// the controller in .auto. Exits 1 when the SMC cannot be opened.
    static func make(options: HelperOptions) -> HelperDaemon {
        let smc: SMC
        let telemetry: Telemetry
        do {
            smc = try SMC()
            telemetry = try Telemetry(smc: smc)
        } catch {
            logLine("fatal: cannot open SMC: \(error)")
            exit(1)
        }
        let fans = telemetry.fans
        if fans.isEmpty {
            logLine("WARNING: no usable fans found; the helper will run but has nothing to control")
        } else {
            let table = fans.map { "F\($0.index) \(Int($0.minRPM))...\(Int($0.maxRPM)) rpm" }.joined(separator: ", ")
            logLine("fans: \(table)")
        }
        bootReset(smc: smc, fans: fans, forceTest: telemetry.hasForceTest)
        return HelperDaemon(options: options, smc: smc, telemetry: telemetry)
    }

    /// A crashed previous instance must never leave the fans under manual control.
    private static func bootReset(smc: SMC, fans: [FanInfo], forceTest: Bool) {
        if forceTest, let value = try? smc.readUInt8(Self.forceTestKey), value != 0 {
            do {
                try smc.writeUInt8(Self.forceTestKey, 0)
                logLine("boot reset: Ftst was \(value), wrote 0")
            } catch {
                logLine("boot reset: cannot write Ftst: \(error)")
            }
        }
        var reset = 0
        for fan in fans {
            let mode = try? smc.readUInt8(fan.modeKey)
            if mode == 0 { continue }
            do {
                try smc.writeUInt8(fan.modeKey, 0)
                reset += 1
                logLine("boot reset: \(fan.modeKey) was \(mode.map(String.init) ?? "unreadable"), wrote 0")
            } catch {
                logLine("boot reset: cannot write \(fan.modeKey): \(error)")
            }
        }
        if reset == 0 { logLine("boot reset: no fan was under manual control") }
    }

    private init(options: HelperOptions, smc: SMC, telemetry: Telemetry) {
        self.options = options
        self.smc = smc
        self.telemetry = telemetry
        self.fans = telemetry.fans
        self.controller = FanController(fans: telemetry.fans)
    }

    /// Startup steps 5-6: socket, signals, power notifications. Throws when the socket cannot be created.
    func start() throws {
        let server = SocketServer(path: options.socketPath, allowedUIDs: options.allowedUIDs, queue: queue)
        server.onCommand = { [unowned self] connection, command in self.handle(command, from: connection) }
        server.onClose = { [unowned self] connection, _ in self.connectionClosed(connection) }
        try server.start()
        self.server = server
        logLine("listening on \(options.socketPath)")
        registerSignals()
        registerPower()
    }

    // MARK: Commands

    private func handle(_ command: HelperCommand, from connection: ClientConnection) {
        if connection === controlling { lastRenewal = nowNanos() }
        switch command {
        case .ping:
            connection.send("OK")
        case .status:
            connection.send(currentStatus().serialized)
        case .auto:
            logLine("command AUTO from connection \(connection.id)")
            let released = releaseAllFans(context: "AUTO")
            stopControl()
            if released {
                connection.send("OK")
            } else {
                failToMonitor(reason: "smc:release", detail: "AUTO could not release every fan")
                connection.send("ERR release failed")
            }
        case .curve(let input, let points):
            guard !monitorOnly else { connection.send("ERR monitor"); return }
            do {
                try controller.setCurve(FanCurve(points: points), input: input)
            } catch {
                connection.send("ERR \(error)")
                return
            }
            logLine("command CURVE \(input.rawValue) (\(points.count) points) from connection \(connection.id)")
            beginControl(connection, input: input)
            connection.send("OK")
        case .fixed(let percent):
            guard !monitorOnly else { connection.send("ERR monitor"); return }
            do {
                try controller.setFixed(percent: percent)
            } catch {
                connection.send("ERR \(error)")
                return
            }
            logLine("command FIXED \(HelperCommand.number(percent)) from connection \(connection.id)")
            beginControl(connection, input: .max)
            connection.send("OK")
        case let .hold(input, target):
            guard !monitorOnly else { connection.send("ERR monitor"); return }
            if input == .system && !telemetry.hasSystem {
                connection.send("ERR no system sensor")
                return
            }
            do {
                try controller.setHold(target: target, input: input,
                                       config: telemetry.hasForceTest ? .forFtstMachines() : HoldConfig())
            } catch {
                connection.send("ERR \(error)")
                return
            }
            logLine("command HOLD \(input.rawValue) \(HelperCommand.number(target)) from connection \(connection.id)")
            systemInputWatch = SystemInputWatch()
            systemInputStuck = false
            lastControlTick = nil
            beginControl(connection, input: input)
            connection.send("OK")
        }
    }

    private func connectionClosed(_ connection: ClientConnection) {
        guard connection === controlling else { return }
        releaseControl(reason: "controlling connection closed")
    }

    private func beginControl(_ connection: ClientConnection, input: FanControlInput) {
        if let previous = controlling, previous !== connection {
            logLine("control taken over by connection \(connection.id) (was connection \(previous.id))")
        }
        controlling = connection
        activeInput = input
        lastRenewal = nowNanos()
        startTimerIfNeeded()
        runTick()
    }

    // MARK: Tick

    private func startTimerIfNeeded() {
        guard tickTimer == nil else { return }
        let interval = options.tick
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .nanoseconds(Int(interval * 0.2 * 1_000_000_000))
        )
        timer.setEventHandler { [unowned self] in self.runTick() }
        timer.resume()
        tickTimer = timer
    }

    private func stopTimer() {
        tickTimer?.cancel()
        tickTimer = nil
    }

    private func runTick() {
        guard controlling != nil else { return }
        if nowNanos() &- lastRenewal > HelperDaemon.leaseNanoseconds {
            releaseControl(reason: "no traffic for 12 s")
            return
        }
        guard !asleep else { return }

        // The panic latch always needs the hottest CPU/GPU sensor; the battery only matters to a battery curve.
        var sensors: SensorSet = [.cpu, .gpu, .fans]
        if activeInput == .battery { sensors = [.cpu, .gpu, .battery, .fans] }
        if activeInput == .system { sensors = [.cpu, .gpu, .system, .fans] }
        let reading = telemetry.read(sensors)
        let inputs = reading.controlInputs(for: activeInput)

        let now = nowNanos()
        var dt: Double?
        if controller.mode == .hold {
            if let last = lastControlTick {
                dt = Double(now &- last) / 1_000_000_000
            }
            lastControlTick = now
        } else {
            lastControlTick = nil
        }

        var temperature = inputs.temperature
        if controller.mode == .hold, activeInput == .system {
            let watched = systemInputWatch.check(system: temperature.map { Double($0) },
                                                 die: inputs.safety.map { Double($0) },
                                                 now: Double(now) / 1_000_000_000)
            if watched == nil {
                if !systemInputStuck {
                    logLine("system temperature stuck or missing")
                    systemInputStuck = true
                }
                temperature = nil
            } else {
                systemInputStuck = false
            }
        }

        let observations = reading.fans.map { FanObservation(rpm: $0.rpm, manual: $0.manual) }
        let actions = controller.tick(temperature: temperature, safetyTemperature: inputs.safety, fans: observations, dt: dt)

        // Strictly in the order returned: a fan's setTarget always precedes its setManual.
        for action in actions {
            do {
                try apply(action)
            } catch {
                failToMonitor(reason: shortReason(for: error), detail: "\(error)")
                return
            }
            controller.noteApplied([action])
        }

        if controller.mode == .auto {
            // The controller dropped control itself (no valid temperature reading).
            logLine("no valid temperature; control dropped, fans released")
            if !releaseAllFans(context: "sensor loss") {
                failToMonitor(reason: "smc:release", detail: "could not release fans after sensor loss")
                return
            }
            stopControl()
            return
        }
        lastTemperature = temperature.map { (Double($0) * 100).rounded() / 100 }
        noteModeChange()
    }

    /// One SMC write. Every guard here backs a hard safety rule, whatever the controller returned.
    private func apply(_ action: FanAction) throws {
        switch action {
        case let .setTarget(fan, rpm):
            let info = try fanInfo(fan)
            let target = info.clamp(rpm)
            guard target.isFinite, target >= info.minRPM, target <= info.maxRPM else {
                throw WriteGuardError.invalidTarget(fan: fan)
            }
            try smc.writeFloat(info.targetKey, target)
            targetWritten.insert(fan)
            lastTargets[fan] = target
        case let .setManual(fan, on):
            let info = try fanInfo(fan)
            if on {
                guard targetWritten.contains(fan) else { throw WriteGuardError.manualBeforeTarget(fan: fan) }
                engaged = true
                try enterManual(info)
                manualFans.insert(fan)
            } else {
                try smc.writeUInt8(info.modeKey, 0)
                lastTargets[fan] = 0
                manualFans.remove(fan)
                // A curve's zero-fan zone hands every fan back; macOS only manages them again once Ftst is 0.
                if manualFans.isEmpty && forceTestSet {
                    try smc.writeUInt8(Self.forceTestKey, 0)
                    forceTestSet = false
                }
            }
        }
    }

    static let forceTestKey = "Ftst"

    /// M5 and M1 accept `md` = 1 directly. M3 and M4 refuse it while macOS holds the fans; there `Ftst` = 1 unlocks
    /// manual mode after about half a second (agoodkind/macos-smc-fan, garyhooi/AutoFansMac). A Mac without `Ftst`
    /// that refuses the write fails as before.
    private func enterManual(_ info: FanInfo) throws {
        do {
            try smc.writeUInt8(info.modeKey, 1)
            return
        } catch {
            guard telemetry.hasForceTest else { throw error }
        }
        if !forceTestSet {
            try smc.writeUInt8(Self.forceTestKey, 1)
            forceTestSet = true
            logLine("\(info.modeKey) refused manual mode; Ftst set to 1")
            usleep(500_000)
        }
        var lastError: Error?
        for _ in 0..<20 {
            do {
                try smc.writeUInt8(info.modeKey, 1)
                return
            } catch {
                lastError = error
                usleep(100_000)
            }
        }
        throw lastError ?? WriteGuardError.unknownFan(info.index)
    }

    private func fanInfo(_ index: Int) throws -> FanInfo {
        guard let info = fans.first(where: { $0.index == index }) else { throw WriteGuardError.unknownFan(index) }
        return info
    }

    // MARK: Release and degrade

    /// Writes md=0 on every fan. While `engaged` (or when a fan reads manual or unreadable) the write is
    /// unconditional, so an idle daemon on an idle machine writes nothing. Returns false when any write failed.
    @discardableResult
    private func releaseAllFans(context: String) -> Bool {
        var written = 0
        var failed = 0
        for fan in fans {
            let mode = try? smc.readUInt8(fan.modeKey)
            guard engaged || mode != 0 else { continue }
            do {
                try smc.writeUInt8(fan.modeKey, 0)
                written += 1
            } catch {
                failed += 1
                logLine("release: cannot write \(fan.modeKey): \(error)")
            }
        }
        if failed == 0 { manualFans = [] }
        if forceTestSet {
            do {
                try smc.writeUInt8(Self.forceTestKey, 0)
                forceTestSet = false
            } catch {
                failed += 1
                logLine("release: cannot write Ftst: \(error)")
            }
        }
        if failed == 0 { engaged = false }
        logLine("release (\(context)): md=0 written on \(written) of \(fans.count) fan(s), \(failed) failed")
        return failed == 0
    }

    /// Forgets the active control: controller back to auto, no timer, no controlling connection.
    private func stopControl() {
        if !monitorOnly { controller.setAuto() }
        stopTimer()
        controlling = nil
        lastTemperature = nil
        lastTargets = [:]
        noteModeChange()
    }

    private func releaseControl(reason: String) {
        logLine("lease expired: \(reason)")
        let released = releaseAllFans(context: "lease")
        stopControl()
        if !released {
            failToMonitor(reason: "smc:release", detail: "lease release could not free every fan")
        }
    }

    /// A write failed: record it, release the fans as well as possible, stop controlling for good.
    private func failToMonitor(reason: String, detail: String) {
        logLine("SMC write failed (\(reason)): \(detail)")
        if !monitorOnly { controller.noteWriteFailure(reason) }
        monitorOnly = true
        releaseAllFans(context: "write failure")
        stopTimer()
        controlling = nil
        lastTemperature = nil
        lastTargets = [:]
        noteModeChange()
    }

    private func shortReason(for error: Error) -> String {
        if let smcError = error as? SMCError {
            switch smcError {
            case .notPrivileged:
                return "smc:notPrivileged"
            case let .writeFailed(_, kern, result):
                return result != 0
                    ? String(format: "smc:0x%02x", result)
                    : String(format: "smc:kern0x%08x", UInt32(bitPattern: kern))
            case .keyNotFound:
                return "smc:nokey"
            default:
                return "smc:error"
            }
        }
        if let guardError = error as? WriteGuardError { return "smc:\(guardError.code)" }
        return "smc:error"
    }

    // MARK: Status

    private var effectiveMode: HelperMode {
        monitorOnly ? .monitor : controller.mode
    }

    private func currentStatus() -> HelperStatus {
        let mode = effectiveMode
        let active = mode == .curve || mode == .fixed || mode == .panic
        let targets = fans.compactMap { lastTargets[$0.index] }
        return HelperStatus(
            mode: mode,
            inputTemperature: active ? lastTemperature : nil,
            targetRPM: active && targets.count == fans.count ? targets : [],
            writes: controller.writes,
            error: controller.lastError
        )
    }

    /// One log line per mode change, never per tick.
    private func noteModeChange() {
        let mode = effectiveMode
        guard mode != loggedMode else { return }
        logLine("mode \(loggedMode.rawValue) -> \(mode.rawValue)")
        loggedMode = mode
    }

    private func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // MARK: Signals

    private func registerSignals() {
        let handled: [(Int32, String)] = [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP")]
        for (number, name) in handled {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [unowned self] in self.shutdown(signalName: name) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown(signalName: String) {
        logLine("\(signalName) received: shutting down")
        releaseAllFans(context: "shutdown")
        stopTimer()
        server?.stop()
        logLine("socket removed, exiting")
        exit(0)
    }

    // MARK: Power

    private func registerPower() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let root = IORegisterForSystemPower(refcon, &port, powerCallback, &notifier)
        guard root != 0, let port else {
            logLine("WARNING: cannot register for power notifications; fans will not be released on sleep")
            return
        }
        powerRoot = root
        powerPort = port
        powerNotifier = notifier
        IONotificationPortSetDispatchQueue(port, queue)
    }

    fileprivate func handlePower(message: UInt32, argument: UnsafeMutableRawPointer?) {
        switch message {
        case PowerMessage.canSystemSleep, PowerMessage.systemWillSleep:
            logLine("sleep: releasing fans")
            asleep = true
            if !releaseAllFans(context: "sleep") {
                failToMonitor(reason: "smc:release", detail: "could not release fans before sleep")
            }
            IOAllowPowerChange(powerRoot, Int(bitPattern: argument))
        case PowerMessage.systemHasPoweredOn, PowerMessage.systemWillPowerOn, PowerMessage.systemWillNotSleep:
            // systemWillNotSleep matters: canSystemSleep alone does not mean the machine sleeps.
            if asleep {
                asleep = false
                controller.restartHold()
                lastControlTick = nil
                logLine("wake: the next tick re-applies control")
            }
        default:
            break
        }
    }
}
