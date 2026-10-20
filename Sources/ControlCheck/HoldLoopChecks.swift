import CheckKit
import OpenFanControl

/// Counts completed up/down swings of a percent series whose amplitude exceeds `threshold`.
private func reversalCount(_ values: [Double], threshold: Double) -> Int {
    guard let first = values.first else { return 0 }
    var count = 0
    var direction = 0
    var extreme = first
    var lastLow = first
    var lastHigh = first
    let epsilon = 1e-9

    for value in values.dropFirst() {
        if direction == 0 {
            if value > extreme + epsilon {
                direction = 1
                lastLow = extreme
                extreme = value
            } else if value < extreme - epsilon {
                direction = -1
                lastHigh = extreme
                extreme = value
            }
        } else if direction > 0 {
            if value > extreme {
                extreme = value
            } else if value < extreme - epsilon {
                if extreme - lastLow > threshold { count += 1 }
                lastHigh = extreme
                extreme = value
                direction = -1
            }
        } else {
            if value < extreme {
                extreme = value
            } else if value > extreme + epsilon {
                if lastHigh - extreme > threshold { count += 1 }
                lastLow = extreme
                extreme = value
                direction = 1
            }
        }
    }
    return count
}

func runHoldLoopChecks(_ check: Checker) {
    let n = 45.0

    // a. A cool Mac stays released and does not engage.
    do {
        var loop = HoldLoop(target: n)
        let decision = loop.tick(temperature: n - 5, die: 60, actualPercent: nil, dt: 1)
        check.expectEqual(decision, .none, "a: no engage five degrees below target")
        check.expect(loop.isReleased, "a: still released")
    }

    // b. Crossing the engage band engages immediately, seeded from the fan's actual percent.
    do {
        var loop = HoldLoop(target: n)
        let decision = loop.tick(temperature: n + 1, die: 60, actualPercent: 20, dt: 1)
        check.expectEqual(decision, .engage(percent: 20), "b: engage seeded at actual percent")
        let expected = min(max(20 - 6 * (1 + 2.5), -15), 100)
        check.expectClose(loop.integrator, expected, tolerance: 1e-9, "b: bumpless integrator seed")
        check.expect(!loop.isReleased, "b: not released after engage")
    }

    // c. The ramp never exceeds rateUp per second.
    do {
        var loop = HoldLoop(target: n)
        _ = loop.tick(temperature: n + 5, die: 60, actualPercent: 0, dt: 1)
        var previous = loop.commandedPercent
        var withinLimit = true
        for _ in 0..<30 {
            _ = loop.tick(temperature: n + 5, die: 60, actualPercent: nil, dt: 1)
            let increase = loop.commandedPercent - previous
            if increase > 0.2 * 1 + 1e-9 { withinLimit = false }
            previous = loop.commandedPercent
        }
        check.expect(withinLimit, "c: every ramp step within rateUp * dt")
    }

    // d. Anti-windup freezes the integrator only in the pinned direction.
    do {
        var loop = HoldLoop(target: n)
        _ = loop.tick(temperature: n + 1, die: 60, actualPercent: 100, dt: 1)
        _ = loop.tick(temperature: n + 10, die: 60, actualPercent: nil, dt: 1)
        let pinned = loop.integrator
        _ = loop.tick(temperature: n + 10, die: 60, actualPercent: nil, dt: 1)
        check.expectClose(loop.integrator, pinned, tolerance: 1e-12, "d: integrator frozen at 100 with positive error")
        _ = loop.tick(temperature: n - 1, die: 60, actualPercent: nil, dt: 1)
        check.expect(loop.integrator < pinned, "d: integrator moves down at 100 with negative error")
    }

    // e. The write dead band suppresses a second identical write.
    do {
        var loop = HoldLoop(target: n)
        _ = loop.tick(temperature: n + 1, die: 60, actualPercent: 50, dt: 1)
        let first = loop.tick(temperature: n + 1, die: 60, actualPercent: nil, dt: 1)
        let second = loop.tick(temperature: n + 1, die: 60, actualPercent: nil, dt: 1)
        guard case let .hold(firstPercent, firstWrite) = first,
              case let .hold(secondPercent, secondWrite) = second else {
            check.expect(false, "e: expected hold decisions")
            return
        }
        check.expect(firstWrite, "e: first write passes")
        check.expect(!secondWrite, "e: second write suppressed inside dead band")
        check.expect(abs(secondPercent - firstPercent) < 0.5, "e: outputs differ by less than the dead band")
        check.expectClose(secondPercent, firstPercent, tolerance: 1e-12, "e: suppressed write repeats the last output")
    }

    // f. Release needs the full dwell, then happens exactly once.
    do {
        var loop = HoldLoop(target: n)
        _ = loop.tick(temperature: n + 1, die: 60, actualPercent: nil, dt: 1)
        var earlyReleases = 0
        for _ in 0..<179 {
            if loop.tick(temperature: n - 6, die: 60, actualPercent: nil, dt: 1) == .release {
                earlyReleases += 1
            }
        }
        check.expectEqual(earlyReleases, 0, "f: no release during the 180 s dwell")
        check.expect(!loop.isReleased, "f: still holding just before the dwell expires")
        let release = loop.tick(temperature: n - 6, die: 60, actualPercent: nil, dt: 1)
        check.expectEqual(release, .release, "f: release at 180 s")
        check.expect(loop.isReleased, "f: released afterwards")
        let after = loop.tick(temperature: n - 6, die: 60, actualPercent: nil, dt: 1)
        check.expect(after != .release, "f: release is emitted only once")
    }

    // g. Closed-loop steady state on a first-order thermal plant.
    do {
        let tau = 600.0
        let ambient = 30.0
        let power = 40.0
        let gainPower = 0.8
        let gainFan = 0.004
        var temperature = ambient
        var loop = HoldLoop(target: n)
        var temperatures: [Double] = []
        var commanded: [Double] = []

        for _ in 0..<14400 {
            let fanPercent = loop.isReleased ? 0 : loop.commandedPercent
            let actual = loop.isReleased ? nil : loop.commandedPercent
            _ = loop.tick(temperature: temperature, die: nil, actualPercent: actual, dt: 1)
            let rpm = 2317 + 55.09 * fanPercent
            temperature += (ambient + gainPower * power - gainFan * rpm - temperature) / tau
            temperatures.append(temperature)
            commanded.append(loop.commandedPercent)
        }

        let lastHalfHour = temperatures.suffix(1800)
        let meanError = lastHalfHour.reduce(0) { $0 + abs($1 - n) } / Double(lastHalfHour.count)
        let lastTwoHours = commanded.suffix(7200)
        let reversals = reversalCount(Array(lastTwoHours), threshold: 2)
        check.expect(meanError <= 0.3, "g: mean |T - n| over last 30 min = \(meanError) <= 0.3")
        check.expect(reversals <= 3, "g: commanded-percent reversals over 2% in last 2 h = \(reversals) <= 3")
        print("g: final T = \(temperature), mean |T - n| = \(meanError), reversals > 2% = \(reversals), final percent = \(loop.commandedPercent)")
    }

    // h. The die guard engages and holds off a release, latches, then backs down in bounded steps.
    do {
        var loop = HoldLoop(target: n)
        var dieGuardHeld = true
        for _ in 0..<120 {
            let decision = loop.tick(temperature: n - 10, die: 104, actualPercent: nil, dt: 1)
            switch decision {
            case .engage, .hold:
                break
            case .none, .release:
                dieGuardHeld = false
            }
        }
        check.expect(loop.diePercent > 0, "h: die guard keeps a nonzero percent at 104 C")
        check.expect(dieGuardHeld, "h: die guard decisions engage or hold, never release")
        check.expect(!loop.isReleased, "h: die guard engaged the loop")

        var latched = false
        var latchedOutput = 0.0
        for _ in 0..<100 {
            let decision = loop.tick(temperature: n - 10, die: 106, actualPercent: nil, dt: 1)
            if loop.isLatched {
                latched = true
                switch decision {
                case let .engage(percent), let .hold(percent, _):
                    latchedOutput = percent
                case .none, .release:
                    latchedOutput = -1
                }
                break
            }
        }
        check.expect(latched, "h: die at 106 C latches")
        check.expectClose(latchedOutput, 100, tolerance: 1e-12, "h: latched output is 100 percent")

        var unlatched = false
        for _ in 0..<300 {
            _ = loop.tick(temperature: n - 10, die: 97, actualPercent: nil, dt: 1)
            if !loop.isLatched {
                unlatched = true
                break
            }
        }
        check.expect(unlatched, "h: die at 97 C unlatches")
        var previous = loop.diePercent
        var bounded = true
        for _ in 0..<50 {
            _ = loop.tick(temperature: n - 10, die: 97, actualPercent: nil, dt: 1)
            let drop = previous - loop.diePercent
            if drop > 0.1 * 1 + 1e-9 || drop < -1e-9 { bounded = false }
            previous = loop.diePercent
        }
        check.expect(bounded, "h: die percent falls no faster than rateDown per tick")
    }

    // i. Ftst machines get the stricter latch window.
    do {
        let config = HoldConfig.forFtstMachines()
        check.expectEqual(config.latchOn, 95, "i: Ftst latchOn")
        check.expectEqual(config.latchOff, 88, "i: Ftst latchOff")
    }

    /// A loop that has climbed to a high speed under load, as in the 2026-10-20 run (43 % at the end of the load).
    func loaded() -> HoldLoop {
        var loop = HoldLoop(target: n)
        _ = loop.tick(temperature: n + 5, die: 70, actualPercent: 0, dt: 1)
        for _ in 0..<600 { _ = loop.tick(temperature: n + 2, die: 70, actualPercent: nil, dt: 1) }
        return loop
    }

    // j. Cooled below the target, the integrator unwinds while the fans ramp down (1.10 froze it for 7 minutes).
    do {
        var loop = loaded()
        check.expect(loop.commandedPercent > 30, "j: the loaded loop runs the fans fast")
        let start = loop.integrator
        for _ in 0..<30 { _ = loop.tick(temperature: n - 6, die: 40, actualPercent: nil, dt: 1) }
        check.expect(loop.integrator < start - 1, "j: the integrator falls while ramping down below the target")
    }

    // k. Well below the target the fans fall at rateDownFast; within a degree of it, at rateDown.
    do {
        var loop = loaded()
        var previous = loop.commandedPercent
        var fastest = 0.0
        for _ in 0..<20 {
            _ = loop.tick(temperature: n - 6, die: 40, actualPercent: nil, dt: 1)
            fastest = max(fastest, previous - loop.commandedPercent)
            previous = loop.commandedPercent
        }
        check.expect(fastest > 0.1 + 1e-9, "k: more than 0.1 %/s when the Mac is 6 C under the target")
        check.expect(fastest <= 0.5 + 1e-9, "k: never more than rateDownFast")

        var near = loaded()
        previous = near.commandedPercent
        var nearFastest = 0.0
        for _ in 0..<20 {
            _ = near.tick(temperature: n - 0.5, die: 40, actualPercent: nil, dt: 1)
            nearFastest = max(nearFastest, previous - near.commandedPercent)
            previous = near.commandedPercent
        }
        check.expect(nearFastest <= 0.1 + 1e-9, "k: within a degree of the target the fans fall no faster than rateDown")
    }

    // l. After a load ends, the fans go back to macOS within about five minutes (1.10: about ten).
    do {
        var loop = loaded()
        var released: Int?
        for second in 1...900 where released == nil {
            if loop.tick(temperature: n - 6, die: 40, actualPercent: nil, dt: 1) == .release { released = second }
        }
        check.expect(released != nil, "l: the loop releases after cooling")
        check.expect((released ?? .max) <= 330, "l: released within 330 s of cooling (got \(released ?? -1) s)")
    }

    // m. A new target keeps the loop's state.
    do {
        var loop = loaded()
        let integrator = loop.integrator
        let percent = loop.commandedPercent
        loop.retarget(n + 1)
        check.expectEqual(loop.target, n + 1, "m: the target moves")
        check.expectEqual(loop.integrator, integrator, "m: the integrator is kept")
        check.expectEqual(loop.commandedPercent, percent, "m: the commanded speed is kept")
        check.expect(!loop.isReleased, "m: still holding")
        let decision = loop.tick(temperature: n + 2, die: 70, actualPercent: nil, dt: 1)
        check.expect(decision != .release, "m: the next tick does not hand the fans back")
    }
}
