import Foundation
import CheckKit
import OpenFanControl
import OpenFanSMC
import OpenFanCore

let check = Checker("ControlCheck")

let fans = [
    FanInfo(index: 0, minRPM: 2317, maxRPM: 7826),
    FanInfo(index: 1, minRPM: 2317, maxRPM: 7826),
]
let steep = FanCurve(points: [CurvePoint(t: 40, p: 0), CurvePoint(t: 100, p: 100)])

func obs(manual: Bool) -> [FanObservation] {
    fans.map { _ in FanObservation(rpm: 3000, manual: manual) }
}

func targets(_ actions: [FanAction]) -> [Float] {
    actions.compactMap { if case let .setTarget(_, rpm) = $0 { return rpm } else { return nil } }
}

func assertInRange(_ label: String, _ actions: [FanAction]) {
    for action in actions {
        guard case let .setTarget(fan, rpm) = action else { continue }
        if let info = fans.first(where: { $0.index == fan }) {
            check.expect(rpm >= info.minRPM && rpm <= info.maxRPM, "\(label): fan \(fan) rpm \(rpm) inside [Mn, Mx]")
        }
    }
}

// 1. First tick engages every fan: setTarget precedes setManual; mode becomes .curve.
do {
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .max) }
    let a = c.tick(temperature: 60, fans: obs(manual: false))
    check.expectEqual(c.mode, .curve, "first tick keeps mode .curve")
    check.expectEqual(a.count, fans.count * 2, "first tick emits target+manual for each fan")
    for (i, fan) in fans.enumerated() {
        check.expectEqual(a[i * 2], .setTarget(fan: fan.index, rpm: fan.rpm(percent: steep.percent(at: 60))), "fan \(fan.index) target first")
        check.expectEqual(a[i * 2 + 1], .setManual(fan: fan.index, on: true), "fan \(fan.index) manual second")
    }
    assertInRange("first tick", a)
    c.noteApplied(a)
    check.expectEqual(c.writes, a.count, "noteApplied counts every action")

    // 2. Same temperature, fans already manual -> dead band suppresses the write.
    let a2 = c.tick(temperature: 60, fans: obs(manual: true))
    check.expectEqual(a2, [], "repeat at same temperature is inside the dead band")

    // 3. 0.5 C drop stays inside hysteresis -> no change.
    let a3 = c.tick(temperature: 59.5, fans: obs(manual: true))
    check.expectEqual(a3, [], "0.5 C drop is held by hysteresis")

    // 4. 3 C drop is adopted and moves the target down.
    let a4 = c.tick(temperature: 57, fans: obs(manual: true))
    check.expectEqual(a4.count, fans.count, "3 C drop emits a target per fan")
    let newTargets = targets(a4)
    let oldTarget = fans[0].rpm(percent: steep.percent(at: 60))
    for t in newTargets {
        check.expect(t < oldTarget, "3 C drop lowers the target (got \(t) < \(oldTarget))")
    }
    assertInRange("3 C drop", a4)
}

// 5. A reclaimed fan (manual == false) re-emits setTarget then setManual inside the dead band.
do {
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .max) }
    let a = c.tick(temperature: 60, fans: obs(manual: false))
    c.noteApplied(a)
    let again = c.tick(temperature: 60, fans: obs(manual: false))
    check.expectEqual(again.count, fans.count * 2, "re-engagement emits target+manual even inside the dead band")
    for (i, fan) in fans.enumerated() {
        check.expectEqual(again[i * 2], .setTarget(fan: fan.index, rpm: fan.rpm(percent: steep.percent(at: 60))), "fan \(fan.index) re-engage target first")
        check.expectEqual(again[i * 2 + 1], .setManual(fan: fan.index, on: true), "fan \(fan.index) re-engage manual second")
    }
}

// 6. A dead sensor releases exactly the manual fans and switches to .auto.
do {
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .max) }
    let mixed = [FanObservation(rpm: 3000, manual: false), FanObservation(rpm: 3000, manual: true)]
    let a = c.tick(temperature: nil, fans: mixed)
    check.expectEqual(a, [.setManual(fan: 1, on: false)], "nil temperature releases only the manual fan")
    check.expectEqual(c.mode, .auto, "nil temperature switches to .auto")

    let c2 = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c2.setCurve(steep, input: .max) }
    let a2 = c2.tick(temperature: Float.nan, fans: obs(manual: true))
    check.expectEqual(a2, [.setManual(fan: 0, on: false), .setManual(fan: 1, on: false)], "non-finite temperature releases every manual fan")
    check.expectEqual(c2.mode, .auto, "non-finite temperature switches to .auto")

    let c3 = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c3.setCurve(steep, input: .max) }
    let a3 = c3.tick(temperature: 200, fans: obs(manual: true))
    check.expectEqual(a3.count, fans.count, "out-of-range temperature releases every manual fan")
    check.expectEqual(c3.mode, .auto, "out-of-range temperature switches to .auto")
}

// 7. Panic latches at 95, holds at 90, clears below 88 back to the curve.
do {
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .max) }
    let p1 = c.tick(temperature: 95, fans: obs(manual: false))
    check.expectEqual(c.mode, .panic, "panic latches at 95")
    for (i, fan) in fans.enumerated() {
        check.expectEqual(p1[i * 2], .setTarget(fan: fan.index, rpm: fan.maxRPM), "panic fan \(fan.index) target is Mx")
        check.expectEqual(p1[i * 2 + 1], .setManual(fan: fan.index, on: true), "panic fan \(fan.index) engaged")
    }
    c.noteApplied(p1)

    let p2 = c.tick(temperature: 90, fans: obs(manual: true))
    check.expectEqual(c.mode, .panic, "panic survives 90")
    check.expectEqual(p2, [], "panic steady state inside the dead band")
    for t in targets(p2) {
        check.expect(t == fans[0].maxRPM || t == fans[1].maxRPM, "panic steady target stays at Mx")
    }

    let p3 = c.tick(temperature: 87, fans: obs(manual: true))
    check.expectEqual(c.mode, .curve, "panic clears below 88 back to the curve")
    for fan in fans {
        check.expect(p3.contains(.setTarget(fan: fan.index, rpm: fan.rpm(percent: steep.percent(at: 87)))), "fan \(fan.index) forced back to the curve target on exit")
    }
    assertInRange("panic exit", p3)
}

// 8. Fixed percent maps to Mn + p/100 * (Mx - Mn); 0 never goes below Mn.
do {
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid fixed percent accepted") { try c.setFixed(percent: 50) }
    let a = c.tick(temperature: 60, fans: obs(manual: false))
    check.expectEqual(c.mode, .fixed, "fixed mode set")
    for (i, fan) in fans.enumerated() {
        let expected = fan.minRPM + Float(50.0 / 100.0) * (fan.maxRPM - fan.minRPM)
        check.expectEqual(a[i * 2], .setTarget(fan: fan.index, rpm: expected), "fan \(fan.index) fixed 50 percent maps to the midpoint")
    }

    let c0 = FanController(fans: fans)
    _ = check.expectNoThrow("valid fixed percent accepted") { try c0.setFixed(percent: 0) }
    let a0 = c0.tick(temperature: 60, fans: obs(manual: false))
    for (i, fan) in fans.enumerated() {
        check.expectEqual(a0[i * 2], .setTarget(fan: fan.index, rpm: fan.minRPM), "fan \(fan.index) fixed 0 percent stays at Mn")
    }
    assertInRange("fixed", a0)

    let cNeg = FanController(fans: fans)
    check.expectThrows("fixed percent -1 throws") { try cNeg.setFixed(percent: -1) }
    check.expectThrows("fixed percent 101 throws") { try cNeg.setFixed(percent: 101) }
    check.expectThrows("fixed percent NaN throws") { try cNeg.setFixed(percent: .nan) }
    check.expectThrows("fixed percent infinity throws") { try cNeg.setFixed(percent: .infinity) }
    check.expectEqual(cNeg.mode, .auto, "rejected fixed percent leaves the mode untouched")
}

// 9. A curve that fails validate() throws and leaves the mode untouched.
do {
    let c = FanController(fans: fans)
    let tooFew = FanCurve(points: [CurvePoint(t: 40, p: 0)])
    check.expectThrows("curve with one point throws") { try c.setCurve(tooFew, input: .max) }
    check.expectEqual(c.mode, .auto, "failed validation from auto leaves mode .auto")

    _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .max) }
    let decreasing = FanCurve(points: [CurvePoint(t: 40, p: 50), CurvePoint(t: 80, p: 20)])
    check.expectThrows("constant/reverse curve throws") { try c.setCurve(decreasing, input: .max) }
    check.expectEqual(c.mode, .curve, "failed validation from curve leaves mode .curve")
}

// 10. noteWriteFailure degrades to .monitor; the next tick is empty.
do {
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .max) }
    c.noteWriteFailure("smc:0x82")
    check.expectEqual(c.mode, .monitor, "write failure switches to .monitor")
    check.expectEqual(c.lastError, "smc:0x82", "write failure records the reason")
    check.expectEqual(c.tick(temperature: 60, fans: obs(manual: true)), [], "tick in monitor mode returns no actions")
}

// 11. Auto mode never emits.
do {
    let c = FanController(fans: fans)
    c.setAuto()
    check.expectEqual(c.mode, .auto, "setAuto sets mode .auto")
    check.expectEqual(c.tick(temperature: 60, fans: obs(manual: true)), [], "tick in auto mode returns no actions")
}

// 12. The panic latch watches the hottest CPU/GPU sensor, not only the curve's input.
do {
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .cpu) }
    let g1 = c.tick(temperature: 50, safetyTemperature: 96, fans: obs(manual: false))
    check.expectEqual(c.mode, .panic, "a hot SoC latches panic although the input reads 50")
    for fan in fans {
        check.expect(g1.contains(.setTarget(fan: fan.index, rpm: fan.maxRPM)), "fan \(fan.index) forced to Mx by the guard")
    }
    assertInRange("guard panic", g1)

    _ = c.tick(temperature: 50, safetyTemperature: 90, fans: obs(manual: true))
    check.expectEqual(c.mode, .panic, "panic holds while the SoC stays at or above 88")

    let g3 = c.tick(temperature: 50, safetyTemperature: 80, fans: obs(manual: true))
    check.expectEqual(c.mode, .curve, "panic clears once the SoC drops below 88")
    for fan in fans {
        check.expect(g3.contains(.setTarget(fan: fan.index, rpm: fan.rpm(percent: steep.percent(at: 50)))), "fan \(fan.index) returns to the curve at the input temperature")
    }
}

// 13. A SoC reading below the panic threshold, nil, or invalid never changes what the curve does.
do {
    for (label, safety) in [("warm", Float(94)), ("nil", nil), ("NaN", Float.nan), ("infinite", Float.infinity), ("above ceiling", Float(500)), ("negative", Float(-5))] as [(String, Float?)] {
        let c = FanController(fans: fans)
        _ = check.expectNoThrow("valid curve accepted") { try c.setCurve(steep, input: .cpu) }
        let a = c.tick(temperature: 50, safetyTemperature: safety, fans: obs(manual: false))
        check.expectEqual(c.mode, .curve, "safety \(label) does not latch panic")
        for (i, fan) in fans.enumerated() {
            check.expectEqual(a[i * 2], .setTarget(fan: fan.index, rpm: fan.rpm(percent: steep.percent(at: 50))), "safety \(label): fan \(fan.index) follows the input")
        }
    }
}

// 14. controlInputs pairs the curve input with the hottest SoC sensor and refuses to run blind.
do {
    let hotGPU = SensorReading(cpu: 50, gpu: 97, fans: [])
    check.expectEqual(hotGPU.controlInputs(for: .max).temperature, Float?.some(97), "max input is the hottest die")
    check.expectEqual(hotGPU.controlInputs(for: .max).safety, Float?.some(97), "max safety is the hottest die")
    check.expectEqual(hotGPU.controlInputs(for: .cpu).temperature, Float?.some(50), "cpu input is the CPU reading")
    check.expectEqual(hotGPU.controlInputs(for: .cpu).safety, Float?.some(97), "cpu input is still guarded by the hot GPU")
    check.expectEqual(hotGPU.controlInputs(for: .gpu).temperature, Float?.some(97), "gpu input is the GPU reading")

    let noGPU = SensorReading(cpu: 60, gpu: nil, fans: [])
    check.expectEqual(noGPU.controlInputs(for: .gpu).temperature, Float?.none, "a missing GPU reading is no temperature")
    check.expectEqual(noGPU.controlInputs(for: .gpu).safety, Float?.some(60), "the CPU still guards a gpu curve")

    let blind = SensorReading(cpu: nil, gpu: nil, fans: [])
    for kind in FanControlInput.allCases {
        check.expectEqual(blind.controlInputs(for: kind).temperature, Float?.none, "\(kind.rawValue): no SoC reading, no temperature")
        check.expectEqual(blind.controlInputs(for: kind).safety, Float?.none, "\(kind.rawValue): no SoC reading, no safety")
    }
}

// 15. A battery curve follows the battery, stays guarded by the SoC, and never feeds the max input.
do {
    let warm = SensorReading(cpu: 55, gpu: 60, battery: 70, fans: [])
    check.expectEqual(warm.input(.battery), Float?.some(70), "battery input is the battery mean")
    check.expectEqual(warm.input(.max), Float?.some(60), "the battery never feeds the max input")
    check.expectEqual(warm.controlInputs(for: .battery).temperature, Float?.some(70), "battery curve follows the battery")
    check.expectEqual(warm.controlInputs(for: .battery).safety, Float?.some(60), "battery curve is guarded by the hottest die")

    let noBattery = SensorReading(cpu: 55, gpu: 60, battery: nil, fans: [])
    check.expectEqual(noBattery.controlInputs(for: .battery).temperature, Float?.none, "an unreadable battery is no temperature")

    let c = FanController(fans: fans)
    _ = check.expectNoThrow("battery curve accepted") { try c.setCurve(steep, input: .battery) }
    let cool = warm.controlInputs(for: .battery)
    let a = c.tick(temperature: cool.temperature, safetyTemperature: cool.safety, fans: obs(manual: false))
    check.expectEqual(c.mode, .curve, "a cool SoC leaves the battery curve in charge")
    for (i, fan) in fans.enumerated() {
        check.expectEqual(a[i * 2], .setTarget(fan: fan.index, rpm: fan.rpm(percent: steep.percent(at: 70))), "fan \(fan.index) follows the battery temperature")
    }

    let hot = SensorReading(cpu: 50, gpu: 97, battery: 31, fans: []).controlInputs(for: .battery)
    let h = FanController(fans: fans)
    _ = check.expectNoThrow("battery curve accepted") { try h.setCurve(steep, input: .battery) }
    let ha = h.tick(temperature: hot.temperature, safetyTemperature: hot.safety, fans: obs(manual: false))
    check.expectEqual(h.mode, .panic, "a hot GPU panics a cool battery curve")
    for fan in fans {
        check.expect(ha.contains(.setTarget(fan: fan.index, rpm: fan.maxRPM)), "fan \(fan.index) runs at Mx while the die is hot")
    }
}

// 15. One fan (Mac mini, Mac Studio, a MacBook Pro with one fan) and no fan at all (a MacBook Air).
do {
    let single = [FanInfo(index: 0, minRPM: 1000, maxRPM: 4900, modeKey: "F0Md")]
    let c = FanController(fans: single)
    _ = check.expectNoThrow("one-fan curve accepted") { try c.setCurve(steep, input: .max) }
    let a = c.tick(temperature: 70, fans: [FanObservation(rpm: 1200, manual: false)])
    check.expectEqual(a, [.setTarget(fan: 0, rpm: single[0].rpm(percent: steep.percent(at: 70))), .setManual(fan: 0, on: true)],
                      "one fan: target, then manual, and nothing for a fan that does not exist")
    let p = c.tick(temperature: 97, fans: [FanObservation(rpm: 3000, manual: true)])
    check.expectEqual(p, [.setTarget(fan: 0, rpm: 4900)], "one fan in panic runs at its own Mx")
    let cold = c.tick(temperature: 20, fans: [FanObservation(rpm: 4900, manual: true)])
    check.expectEqual(c.mode, .curve, "the cold zero-fan zone keeps the curve")
    check.expectEqual(cold, [.setManual(fan: 0, on: false)], "one fan leaving panic into the zero-fan zone goes back to macOS")
    check.expectEqual(single[0].modeKey, "F0Md", "the probed mode key is kept")
    check.expectEqual(FanInfo(index: 1, minRPM: 1, maxRPM: 2).modeKey, "F1md", "the default mode key is the M5 one")

    let none = FanController(fans: [])
    _ = check.expectNoThrow("a curve on a fanless Mac is accepted") { try none.setCurve(steep, input: .max) }
    check.expectEqual(none.tick(temperature: 70, fans: []), [], "a fanless Mac never gets an SMC write")
    check.expectEqual(none.tick(temperature: 99, fans: []), [], "not even in panic")
}

// 16. Hold mode.
do {
    let n = 45.0

    let invalid = FanController(fans: fans)
    check.expectThrows("hold target 200 throws") { try invalid.setHold(target: 200, input: .max) }
    check.expectThrows("hold target NaN throws") { try invalid.setHold(target: .nan, input: .max) }
    check.expectEqual(invalid.mode, .auto, "rejected hold targets leave the mode untouched")

    // A hot Mac engages both fans target-first on the first tick.
    let c = FanController(fans: fans)
    _ = check.expectNoThrow("valid hold accepted") { try c.setHold(target: n, input: .max) }
    check.expectEqual(c.mode, .hold, "setHold sets mode .hold")
    check.expectEqual(c.holdInput, FanControlInput.max, "hold input is exposed")
    let actualPercent = (3000.0 - Double(fans[0].minRPM)) / Double(fans[0].maxRPM - fans[0].minRPM) * 100
    let engaged = c.tick(temperature: Float(n + 3), fans: obs(manual: false))
    check.expectEqual(c.mode, .hold, "hold stays .hold after engaging")
    check.expectEqual(engaged.count, fans.count * 2, "hold engage emits target+manual for each fan")
    for (i, fan) in fans.enumerated() {
        check.expectEqual(engaged[i * 2], .setTarget(fan: fan.index, rpm: fan.rpm(percent: actualPercent)), "fan \(fan.index) hold target first")
        check.expectEqual(engaged[i * 2 + 1], .setManual(fan: fan.index, on: true), "fan \(fan.index) hold manual second")
    }
    assertInRange("hold engage", engaged)
    c.noteApplied(engaged)

    // While holding, the first written tick emits targets and the next inside the dead band emits nothing.
    let written = c.tick(temperature: Float(n + 3), fans: obs(manual: true))
    check.expectEqual(written.count, fans.count, "a writing hold tick emits a target per fan")
    assertInRange("hold write", written)
    let quiet = c.tick(temperature: Float(n + 3), fans: obs(manual: true))
    check.expectEqual(quiet, [], "a non-write hold tick emits no actions")

    // macOS reclaiming a fan re-engages target-first even inside the dead band.
    let reclaimed = c.tick(temperature: Float(n + 3), fans: obs(manual: false))
    check.expectEqual(reclaimed.count, fans.count * 2, "a reclaimed fan re-engages target+manual")
    for (i, fan) in fans.enumerated() {
        if case let .setTarget(targetFan, _) = reclaimed[i * 2] {
            check.expectEqual(targetFan, fan.index, "fan \(fan.index) re-engage target first")
        } else {
            check.expect(false, "fan \(fan.index) re-engage starts with a target")
        }
        check.expectEqual(reclaimed[i * 2 + 1], .setManual(fan: fan.index, on: true), "fan \(fan.index) re-engage manual second")
    }
    assertInRange("hold re-engage", reclaimed)

    // A dead input releases manual fans and drops to auto.
    let released = c.tick(temperature: nil, fans: obs(manual: true))
    check.expectEqual(released, fans.map { .setManual(fan: $0.index, on: false) }, "nil temperature releases every manual fan while holding")
    check.expectEqual(c.mode, .auto, "nil temperature drops hold to .auto")
    check.expectEqual(c.holdInput, nil, "hold input is cleared with the mode")

    // The die guard runs inside hold; a warm die does not panic or force Mx.
    let die99 = FanController(fans: fans)
    _ = check.expectNoThrow("valid hold accepted") { try die99.setHold(target: n, input: .max) }
    let warm = die99.tick(temperature: Float(n - 10), safetyTemperature: 99, fans: obs(manual: true))
    check.expectEqual(warm, [], "a 99 C die does not force Mx or panic")
    check.expectEqual(die99.mode, .hold, "a 99 C die keeps hold mode")

    // A fresh loop seeds its die EMA at 106 C and latches at Mx within one tick, without panic.
    let die106 = FanController(fans: fans)
    _ = check.expectNoThrow("valid hold accepted") { try die106.setHold(target: n, input: .max) }
    let latched = die106.tick(temperature: Float(n - 10), safetyTemperature: 106, fans: obs(manual: true))
    check.expectEqual(die106.mode, .hold, "a 106 C die keeps hold mode, not panic")
    for fan in fans {
        check.expect(latched.contains(.setTarget(fan: fan.index, rpm: fan.maxRPM)), "fan \(fan.index) forced to Mx by the hold die guard")
    }
    assertInRange("hold die guard", latched)

    // setCurve leaves hold and returns to curve behaviour.
    let back = FanController(fans: fans)
    _ = check.expectNoThrow("valid hold accepted") { try back.setHold(target: n, input: .max) }
    _ = back.tick(temperature: Float(n + 3), fans: obs(manual: true))
    _ = check.expectNoThrow("curve after hold accepted") { try back.setCurve(steep, input: .max) }
    check.expectEqual(back.mode, .curve, "setCurve after setHold returns to curve mode")
    check.expectEqual(back.holdInput, nil, "setCurve clears the hold input")
    let curveTick = back.tick(temperature: 60, fans: obs(manual: true))
    check.expectEqual(back.mode, .curve, "curve ticks stay in curve mode")
    for fan in fans {
        check.expect(curveTick.contains(.setTarget(fan: fan.index, rpm: fan.rpm(percent: steep.percent(at: 60)))), "fan \(fan.index) follows the curve again")
    }
    assertInRange("curve after hold", curveTick)
}

runHoldLoopChecks(check)

exit(check.summary())
