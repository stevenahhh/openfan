import Foundation
import OpenFanSMC
import OpenFanCore

public struct ControllerConfig: Equatable, Sendable {
    /// Downward hysteresis in Celsius: the used temperature only follows a drop after it exceeds this.
    public var hysteresis: Float = 2.0
    /// Write a new target only when it differs from the last written value by at least this many RPM.
    public var deadbandRPM: Float = 100
    /// At or above this input the fans go to Mx.
    public var panicOn: Float = 95
    /// Below this input the panic state clears.
    public var panicOff: Float = 88

    public init() {}
}

/// One write the helper must perform. Emitted in order: a fan's setTarget always precedes its setManual.
public enum FanAction: Equatable, Sendable {
    case setTarget(fan: Int, rpm: Float)
    case setManual(fan: Int, on: Bool)
}

public struct FanObservation: Equatable, Sendable {
    public var rpm: Float?
    /// Whether F{n}md currently reads 1 (the system may take control back at any time).
    public var manual: Bool

    public init(rpm: Float?, manual: Bool) {
        self.rpm = rpm
        self.manual = manual
    }
}

/// Pure decision engine: temperature plus per-fan observation in, ordered fan writes out.
/// It owns hysteresis, the write dead band, the panic override and re-engagement after a reclaim.
public final class FanController {
    public let fans: [FanInfo]
    public let config: ControllerConfig
    public private(set) var mode: HelperMode = .auto
    public private(set) var writes: Int = 0
    public private(set) var lastError: String?

    private var curve: FanCurve?
    private var input: FanControlInput?
    private var fixedPercent: Double?
    private var holdLoop: HoldLoop?
    private var panicked = false
    private var usedTemperature: Float?
    private var lastTargets: [Float?]

    /// Input the active hold follows; nil unless hold is the current mode.
    public var holdInput: FanControlInput? { mode == .hold ? input : nil }

    /// Target the active hold follows; nil unless hold is the current mode.
    public var holdTarget: Double? { mode == .hold ? holdLoop?.target : nil }

    /// The hold loop's internal state for the helper log; nil unless hold is the current mode.
    public var holdState: HoldState? {
        guard mode == .hold, let loop = holdLoop else { return nil }
        return HoldState(released: loop.isReleased, latched: loop.isLatched, percent: loop.commandedPercent,
                         diePercent: loop.diePercent, integrator: loop.integrator)
    }

    public init(fans: [FanInfo], config: ControllerConfig = ControllerConfig()) {
        self.fans = fans
        self.config = config
        self.lastTargets = Array(repeating: nil, count: fans.count)
    }

    public func setAuto() {
        mode = .auto
        clearControl()
    }

    public func setCurve(_ curve: FanCurve, input: FanControlInput) throws {
        try curve.validate()
        self.curve = curve
        self.input = input
        self.fixedPercent = nil
        self.holdLoop = nil
        self.panicked = false
        self.usedTemperature = nil
        self.lastTargets = Array(repeating: nil, count: fans.count)
        self.mode = .curve
    }

    public func setFixed(percent: Double) throws {
        guard percent.isFinite, percent >= 0, percent <= 100 else {
            throw ProtocolError.badValue("fixed percent must be finite and within 0...100")
        }
        self.fixedPercent = percent
        self.curve = nil
        self.input = nil
        self.holdLoop = nil
        self.panicked = false
        self.usedTemperature = nil
        self.lastTargets = Array(repeating: nil, count: fans.count)
        self.mode = .fixed
    }

    public func setHold(target: Double, input: FanControlInput, config: HoldConfig = HoldConfig()) throws {
        guard target.isFinite,
              target >= Double(SensorCatalog.temperatureFloor),
              target <= Double(SensorCatalog.temperatureCeiling) else {
            throw ProtocolError.badValue("hold target must be finite and within \(SensorCatalog.temperatureFloor)...\(SensorCatalog.temperatureCeiling)")
        }
        self.holdLoop = HoldLoop(target: target, config: config)
        self.input = input
        self.curve = nil
        self.fixedPercent = nil
        self.panicked = false
        self.usedTemperature = nil
        self.lastTargets = Array(repeating: nil, count: fans.count)
        self.mode = .hold
    }

    /// Starts the hold loop over as a fresh released loop. The next tick re-seeds from the fan's actual
    /// speed instead of applying the integrator accumulated before sleep, which would be stale.
    public func restartHold() {
        guard mode == .hold, let loop = holdLoop else { return }
        holdLoop = HoldLoop(target: loop.target, config: loop.config)
    }

    public func noteWriteFailure(_ reason: String) {
        lastError = reason
        mode = .monitor
    }

    /// - Parameters:
    ///   - temperature: what the curve follows (the preset's input).
    ///   - safetyTemperature: the hottest CPU/GPU sensor. The panic latch watches the larger of the two, so an
    ///     input that runs cool (battery, a single die) can never hide an overheating SoC. Nil or an invalid
    ///     value leaves the latch on `temperature` alone.
    ///   - dt: seconds since the previous hold tick; nil uses 1.0. Ignored outside hold mode.
    public func tick(temperature: Float?, safetyTemperature: Float? = nil, fans observations: [FanObservation], dt: Double? = nil) -> [FanAction] {
        guard mode == .curve || mode == .fixed || mode == .panic || mode == .hold else {
            return []
        }

        guard let t = temperature,
              t.isFinite,
              t >= SensorCatalog.temperatureFloor,
              t <= SensorCatalog.temperatureCeiling else {
            var actions: [FanAction] = []
            for i in self.fans.indices where observation(at: i, in: observations).manual {
                actions.append(.setManual(fan: self.fans[i].index, on: false))
            }
            mode = .auto
            clearControl()
            return actions
        }

        if mode == .hold, var loop = holdLoop {
            let die: Double?
            if let safety = safetyTemperature, safety.isFinite,
               safety >= SensorCatalog.temperatureFloor, safety <= SensorCatalog.temperatureCeiling {
                die = Double(safety)
            } else {
                die = nil
            }
            let decision = loop.tick(temperature: Double(t),
                                     die: die,
                                     actualPercent: holdActualPercent(observations),
                                     dt: dt ?? 1.0)
            holdLoop = loop
            return holdActions(decision, observations: observations)
        }

        var hottest = t
        if let safety = safetyTemperature, safety.isFinite,
           safety >= SensorCatalog.temperatureFloor, safety <= SensorCatalog.temperatureCeiling {
            hottest = max(t, safety)
        }

        let wasPanicked = panicked
        if panicked {
            if hottest < config.panicOff { panicked = false }
        } else if hottest >= config.panicOn {
            panicked = true
        }
        let enteringPanic = panicked && !wasPanicked
        let leavingPanic = !panicked && wasPanicked

        updateUsedTemperature(t)

        var actions: [FanAction] = []
        for i in self.fans.indices {
            let fan = self.fans[i]
            let observation = observation(at: i, in: observations)

            let target: Float
            if panicked {
                target = fan.maxRPM
            } else if let curve {
                let percent = curve.percent(at: Double(usedTemperature ?? t))
                // Zero fan: a curve at 0 % hands the fan back to macOS, which keeps it stopped while the Mac is
                // cool. No target below Mn is ever written; leaving the zone re-engages target-first below.
                if percent <= 0 {
                    if observation.manual { actions.append(.setManual(fan: fan.index, on: false)) }
                    continue
                }
                target = fan.rpm(percent: percent)
            } else if let fixedPercent {
                target = fan.rpm(percent: fixedPercent)
            } else {
                continue
            }

            // Re-engagement after a reclaim: setTarget MUST precede setManual(on: true),
            // even when the target sits inside the dead band. Writing md = 1 before a target
            // has ever been written stops the fan.
            let reEngage = !observation.manual
            let force = reEngage || enteringPanic || leavingPanic
            if force || exceedsDeadband(target, fan: i) {
                actions.append(.setTarget(fan: fan.index, rpm: target))
            }
            if reEngage {
                actions.append(.setManual(fan: fan.index, on: true))
            }
        }

        mode = panicked ? .panic : (curve != nil ? .curve : .fixed)
        return actions
    }

    public func noteApplied(_ actions: [FanAction]) {
        for action in actions {
            writes += 1
            if case let .setTarget(fan, rpm) = action,
               let i = fans.firstIndex(where: { $0.index == fan }) {
                lastTargets[i] = rpm
            }
        }
    }

    private func clearControl() {
        curve = nil
        input = nil
        fixedPercent = nil
        holdLoop = nil
        panicked = false
        usedTemperature = nil
        lastTargets = Array(repeating: nil, count: fans.count)
    }

    /// Fan 0's observed rpm as a percent of its own range. Nil below `Mn` or when the reading is missing.
    private func holdActualPercent(_ observations: [FanObservation]) -> Double? {
        guard let fan = fans.first else { return nil }
        let observation = observation(at: 0, in: observations)
        guard let rpm = observation.rpm, rpm.isFinite, rpm >= fan.minRPM else { return nil }
        let span = fan.maxRPM - fan.minRPM
        guard span > 0 else { return 0 }
        let percent = Double(rpm - fan.minRPM) / Double(span) * 100
        return min(max(percent, 0), 100)
    }

    private func holdActions(_ decision: HoldDecision, observations: [FanObservation]) -> [FanAction] {
        var actions: [FanAction] = []
        switch decision {
        case .none:
            break
        case .engage(let percent):
            for fan in fans {
                actions.append(.setTarget(fan: fan.index, rpm: fan.rpm(percent: percent)))
                actions.append(.setManual(fan: fan.index, on: true))
            }
        case .hold(let percent, let write):
            for (i, fan) in fans.enumerated() {
                let observation = observation(at: i, in: observations)
                if !observation.manual {
                    actions.append(.setTarget(fan: fan.index, rpm: fan.rpm(percent: percent)))
                    actions.append(.setManual(fan: fan.index, on: true))
                } else if write {
                    actions.append(.setTarget(fan: fan.index, rpm: fan.rpm(percent: percent)))
                }
            }
        case .release:
            for (i, fan) in fans.enumerated() where observation(at: i, in: observations).manual {
                actions.append(.setManual(fan: fan.index, on: false))
            }
        }
        return actions
    }

    private func observation(at index: Int, in observations: [FanObservation]) -> FanObservation {
        index < observations.count ? observations[index] : FanObservation(rpm: nil, manual: false)
    }

    private func updateUsedTemperature(_ raw: Float) {
        guard let used = usedTemperature else {
            usedTemperature = raw
            return
        }
        if raw > used {
            usedTemperature = raw
        } else if raw < used - config.hysteresis {
            usedTemperature = raw
        }
    }

    private func exceedsDeadband(_ target: Float, fan index: Int) -> Bool {
        guard let last = lastTargets[index] else { return true }
        return abs(target - last) >= config.deadbandRPM
    }
}

extension SensorReading {
    /// The two temperatures `FanController.tick` needs for a curve driven by `kind`: the curve's own input and
    /// the hottest CPU/GPU sensor for the panic latch. A non-max input without any CPU/GPU reading yields no
    /// temperature at all, so control drops back to Auto instead of running with nothing watching the die.
    public func controlInputs(for kind: FanControlInput) -> (temperature: Float?, safety: Float?) {
        let soc = input(.max)
        if kind == .max { return (soc, soc) }
        guard soc != nil else { return (nil, nil) }
        return (input(kind), soc)
    }
}
