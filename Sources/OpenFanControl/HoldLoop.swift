import Foundation

/// Tuning for `HoldLoop`. Every gain is expressed in percent of a fan's `[Mn, Mx]` range, matching the
/// units Apple's thermalmonitord `PidComponent` uses, so one loop can drive every fan identically.
public struct HoldConfig: Equatable, Sendable {
    /// Proportional gain, percent per degree Celsius.
    public var kp: Double = 6
    /// Integral gain, percent per second per degree Celsius.
    public var ki: Double = 0.02
    /// Engage band in percent. The loop waits `band / kp` degrees above the target before taking the fans.
    public var band: Double = 15
    /// Maximum upward slew, percent per second.
    public var rateUp: Double = 0.2
    /// Maximum downward slew, percent per second.
    public var rateDown: Double = 0.1
    /// Absolute cap on any upward die-guard move, percent per second.
    public var rateUrgent: Double = 0.9
    /// A write is skipped while the output moved less than this since the last write, in percent.
    public var writeDeadband: Double = 0.5
    /// How long the release condition must hold before the fans go back to macOS, in seconds.
    public var releaseDwell: Double = 180
    /// Minimum time spent released before the loop may engage again, in seconds.
    public var minReleased: Double = 60
    /// Time constant of the integrator leak while released, in seconds.
    public var leakTau: Double = 1800
    /// Time constant of the die-temperature EMA, in seconds.
    public var dieEMATau: Double = 20
    /// Above this die EMA the guard starts ratcheting fan speed up, in Celsius.
    public var dieAssist: Double = 102
    /// Below this die EMA the guard lets its percent fall back, in Celsius.
    public var dieQuietFloor: Double = 100
    /// Die-guard raise rate above `dieAssist`, percent per second per degree Celsius.
    public var dieRatchetUp: Double = 0.05
    /// Die-guard fall rate below `dieQuietFloor`, percent per second.
    public var dieRatchetDown: Double = 0.03
    /// Die EMA at or above this latches the guard at full speed, in Celsius.
    public var latchOn: Double = 105
    /// Die EMA below this clears the latch, in Celsius.
    public var latchOff: Double = 98

    public init() {}

    /// M3/M4 machines need the force-test key for manual fan control, which stops Apple's LifetimeServo.
    /// Their die guard therefore has to act earlier and harder than the default one.
    public static func forFtstMachines() -> HoldConfig {
        var config = HoldConfig()
        config.latchOn = 95
        config.latchOff = 88
        config.dieAssist = 92
        config.dieQuietFloor = 90
        return config
    }
}

/// What `HoldLoop` wants the caller to do this tick.
public enum HoldDecision: Equatable, Sendable {
    /// Stay released: nothing is written.
    case none
    /// Take the fans, seeded at this percent (already maximized with the die guard).
    case engage(percent: Double)
    /// Keep the fans at this percent; `write` is false while inside the write dead band.
    case hold(percent: Double, write: Bool)
    /// Hand the fans back to macOS.
    case release
}

/// Pure hold-mode control engine for one target temperature `n`.
///
/// The loop is a positional PI controller in the shape of Apple's `PidComponent`: a clamped integrator
/// (`I` in percent) plus a proportional term over the error above the target. There is deliberately no
/// derivative term, because fan response is slow and noisy and a derivative would chase sensor jitter.
///
/// Outputs are percent of the fan range, not RPM: the caller maps them with `FanInfo.rpm(percent:)`.
/// The engine does not know which fans exist, and it never writes below `Mn` itself (percent 0 maps to
/// `Mn`); only a release returns the fans to macOS. Temperature validity is the caller's concern.
public struct HoldLoop: Sendable {
    public let target: Double
    public let config: HoldConfig

    /// Whether the loop is currently handing the fans back to macOS.
    public private(set) var isReleased: Bool = true
    /// Whether the die guard is latched at full speed.
    public private(set) var isLatched: Bool = false
    /// Commanded percent, `pCmd`.
    public private(set) var commandedPercent: Double = 0
    /// Die-guard percent, `pDie`.
    public private(set) var diePercent: Double = 0
    /// Clamped integral term, in percent.
    public private(set) var integrator: Double = 0

    private var dieFiltered: Double?
    private var slewDirection: Int = 0
    private var timeInState: Double = 0
    private var belowLine: Double = 0
    private var writtenPercent: Double?

    public init(target: Double, config: HoldConfig = HoldConfig()) {
        self.target = target
        self.config = config
        // A freshly set hold must not wait out the release dwell: a hot Mac engages on the first tick.
        self.timeInState = config.minReleased
    }

    private var integralMin: Double { -config.band }
    private var integralMax: Double { 100 }

    /// Advance one tick. `dt` is measured by the caller but clamped here to 0.5...3 s so a stalled or
    /// restarted loop cannot take an enormous step. The first call should pass 1.0.
    public mutating func tick(temperature: Double, die: Double?, actualPercent: Double?, dt rawDT: Double) -> HoldDecision {
        let dt = min(max(rawDT, 0.5), 3.0)
        updateDieGuard(die: die, dt: dt)

        let error = temperature - target
        let engageOffset = config.band / config.kp

        let decision: HoldDecision
        if isReleased {
            integrator *= exp(-dt / config.leakTau)
            let demand = integrator + config.kp * (error + engageOffset)
            commandedPercent = clamp(demand, 0, 100)

            if (demand > 0 && timeInState >= config.minReleased) || diePercent > 0 {
                isReleased = false
                timeInState = 0
                belowLine = 0
                // Bumpless transfer: start where the fan already is instead of jumping to the PI output.
                commandedPercent = actualPercent ?? 0
                integrator = clamp(commandedPercent - config.kp * (error + engageOffset),
                                   integralMin, integralMax)
                decision = .engage(percent: max(commandedPercent, diePercent))
            } else {
                decision = .none
            }
        } else {
            // Freeze the integrator while the output is pinned or still slewing in the direction of the error;
            // otherwise the integral would wind up during a rate-limited ramp.
            let frozen = (commandedPercent >= 100 && error > 0)
                || (slewDirection > 0 && error > 0)
                || (slewDirection < 0 && error < 0)
            if !frozen {
                integrator = clamp(integrator + config.ki * dt * error, integralMin, integralMax)
            }

            let demand = integrator + config.kp * (error + engageOffset)
            let desired = clamp(demand, 0, 100)
            let step = clamp(desired - commandedPercent, -config.rateDown * dt, config.rateUp * dt)
            slewDirection = abs(desired - commandedPercent) <= abs(step) + 1e-9
                ? 0
                : (step > 0 ? 1 : (step < 0 ? -1 : 0))
            commandedPercent += step

            let output = max(commandedPercent, diePercent)
            if demand <= -config.kp && commandedPercent <= 0 && diePercent <= 0 {
                belowLine += dt
            } else {
                belowLine = 0
            }

            if belowLine >= config.releaseDwell {
                isReleased = true
                timeInState = 0
                belowLine = 0
                writtenPercent = nil
                decision = .release
            } else if writtenPercent == nil || abs(output - writtenPercent!) >= config.writeDeadband {
                writtenPercent = output
                decision = .hold(percent: output, write: true)
            } else {
                decision = .hold(percent: writtenPercent!, write: false)
            }
        }

        timeInState += dt
        return decision
    }

    /// The die guard runs every tick in both states. It watches an EMA so a one-sample spike cannot latch,
    /// ratchets up only above `dieAssist`, glides back down below `dieQuietFloor`, and latches at full speed.
    private mutating func updateDieGuard(die: Double?, dt: Double) {
        if let die {
            if let filtered = dieFiltered {
                dieFiltered = filtered + dt * (die - filtered) / config.dieEMATau
            } else {
                dieFiltered = die
            }
        }

        if let filtered = dieFiltered {
            if isLatched {
                if filtered < config.latchOff { isLatched = false }
            } else if filtered >= config.latchOn {
                isLatched = true
            }
        }

        if isLatched {
            diePercent = 100
            return
        }

        guard let filtered = dieFiltered else { return }
        let want: Double
        if filtered > config.dieAssist {
            want = diePercent + config.dieRatchetUp * (filtered - config.dieAssist) * dt
        } else if filtered < config.dieQuietFloor {
            want = diePercent - config.dieRatchetDown * dt
        } else {
            want = diePercent
        }
        diePercent = clamp(diePercent + clamp(want - diePercent, -config.rateDown * dt, config.rateUrgent * dt),
                           0, 100)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
