import CheckKit
import OpenFanControl
import OpenFanCore
import OpenFanSMC

func runSystemInputWatchChecks(_ check: Checker) {
    /// Feeds one sample a second from `from` up to (not including) `to`; returns how many came back nil.
    func feed(_ watch: inout SystemInputWatch, system: Double, from: Int, to: Int, engaged: Bool,
              die: (Int) -> Double) -> Int {
        var nils = 0
        for t in from..<to where watch.check(system: system, die: die(t), now: Double(t), engaged: engaged) == nil {
            nils += 1
        }
        return nils
    }

    var watch = SystemInputWatch()
    check.expectEqual(watch.check(system: 45, die: 60, now: 0, engaged: true), Double?.some(45), "a moving system value passes through")
    check.expectEqual(watch.check(system: 45.06, die: 75, now: 1, engaged: true), Double?.some(45.06), "a >= 0.05 C change passes through")

    // The 2026-10-20 night: TVS0 flat at 32.05 C for two hours while background bursts spiked the die 35 -> 47 C for
    // ten seconds every five minutes. 1.10 called that stuck and dropped the cruise.
    let bursts: (Int) -> Double = { t in t % 300 < 10 ? 47 : 35 }
    watch = SystemInputWatch()
    check.expectEqual(feed(&watch, system: 32.05, from: 0, to: 7200, engaged: false, die: bursts), 0,
                      "an idle night with die bursts is never stuck while the fans are with macOS")
    watch = SystemInputWatch()
    check.expectEqual(feed(&watch, system: 32.05, from: 0, to: 7200, engaged: true, die: bursts), 0,
                      "short die bursts move the 20 s die average too little to call TVS0 stuck, even while holding")

    // A genuinely frozen TVS0 while the die works hard for minutes, with the fans held.
    let sustained: (Int) -> Double = { t in t < 100 ? 60 : 80 }
    watch = SystemInputWatch()
    check.expectEqual(feed(&watch, system: 45, from: 0, to: 600, engaged: true, die: sustained), 0,
                      "flat for less than 10 min is not stuck")
    check.expect(feed(&watch, system: 45, from: 600, to: 610, engaged: true, die: sustained) > 0,
                 "flat for 10 min while the die average swung 20 C is stuck")
    check.expect(watch.isStuck, "the verdict is exposed")
    check.expectEqual(watch.check(system: 45.03, die: 80, now: 611, engaged: false), Double?.none,
                      "a stuck verdict holds, released or not, until the value moves by 0.05 C")
    check.expectEqual(watch.check(system: 45.2, die: 80, now: 612, engaged: false), Double?.some(45.2),
                      "a moved value clears the verdict")
    check.expect(!watch.isStuck, "and the flag")

    watch = SystemInputWatch()
    check.expectEqual(feed(&watch, system: 45, from: 0, to: 600, engaged: false, die: sustained), 0,
                      "released, a flat value with a working die is not judged")
    check.expectEqual(feed(&watch, system: 45, from: 600, to: 700, engaged: true, die: sustained), 0,
                      "the window starts when the loop takes the fans, not before")

    let fanList = [
        FanInfo(index: 0, minRPM: 2317, maxRPM: 7826),
        FanInfo(index: 1, minRPM: 2317, maxRPM: 7826),
    ]
    let steep = FanCurve(points: [CurvePoint(t: 40, p: 0), CurvePoint(t: 100, p: 100)])

    do {
        let controller = FanController(fans: fanList)
        _ = check.expectNoThrow("hold accepted for restart") { try controller.setHold(target: 45, input: .max) }
        check.expectEqual(controller.holdTarget, Double?.some(45), "holdTarget exposes the active target")
        let engaged = controller.tick(temperature: 48, fans: fanList.map { _ in FanObservation(rpm: 3000, manual: false) })
        controller.noteApplied(engaged)

        controller.restartHold()
        check.expectEqual(controller.mode, .hold, "restartHold keeps mode .hold")
        check.expectEqual(controller.holdTarget, Double?.some(45), "restartHold keeps the target")

        let observed: Float = 5000
        let percent = Double(observed - fanList[0].minRPM) / Double(fanList[0].maxRPM - fanList[0].minRPM) * 100
        let seeded = controller.tick(temperature: 48, fans: fanList.map { _ in FanObservation(rpm: observed, manual: true) })
        check.expect(!seeded.isEmpty, "the first tick after restart re-seeds and writes")
        var wroteTarget = false
        for action in seeded {
            guard case let .setTarget(fan, rpm) = action else { continue }
            wroteTarget = true
            let expected = fanList.first { $0.index == fan }!.rpm(percent: percent)
            check.expectClose(Double(rpm), Double(expected), tolerance: 0.5, "fan \(fan) re-seeds at the observed rpm")
            check.expect(rpm < fanList[0].maxRPM, "fan \(fan) does not jump to Mx after restart")
        }
        check.expect(wroteTarget, "restart emits a target instead of applying the old integrator")
    }

    do {
        let controller = FanController(fans: fanList)
        _ = check.expectNoThrow("hold accepted for pause") { try controller.setHold(target: 45, input: .system) }
        controller.noteApplied(controller.tick(temperature: 48, fans: fanList.map { _ in FanObservation(rpm: 3000, manual: false) }))
        check.expectEqual(controller.holdState?.released, Bool?.some(false), "the hold engaged before the pause")
        let paused = controller.pauseHold(fans: fanList.map { _ in FanObservation(rpm: 3000, manual: true) })
        check.expectEqual(paused, fanList.map { FanAction.setManual(fan: $0.index, on: false) }, "a pause hands every manual fan back")
        check.expectEqual(controller.mode, .hold, "a pause keeps hold mode, so the cruise resumes by itself")
        check.expectEqual(controller.holdState?.released, Bool?.some(true), "the loop is released while paused")
        check.expectEqual(controller.pauseHold(fans: fanList.map { _ in FanObservation(rpm: 0, manual: false) }), [],
                          "a pause with the fans already with macOS writes nothing")
    }

    do {
        let controller = FanController(fans: fanList)
        let first = check.expectNoThrow("hold accepted for retarget") { try controller.setHold(target: 45, input: .system) }
        check.expectEqual(first, Bool?.some(false), "a first HOLD starts a loop")
        var observations = fanList.map { _ in FanObservation(rpm: 3000, manual: false) }
        for _ in 0..<60 {
            let actions = controller.tick(temperature: 48, fans: observations, dt: 1)
            controller.noteApplied(actions)
            observations = fanList.map { _ in FanObservation(rpm: 3000, manual: true) }
        }
        let before = controller.holdState
        let again = check.expectNoThrow("same input retargets") { try controller.setHold(target: 46, input: .system) }
        check.expectEqual(again, Bool?.some(true), "a new target on the same input keeps the loop")
        check.expectEqual(controller.holdTarget, Double?.some(46), "the target moved")
        check.expectEqual(controller.holdState?.integrator, before?.integrator, "the integrator is kept")
        check.expectEqual(controller.holdState?.released, Bool?.some(false), "the fans stay held")
        let next = controller.tick(temperature: 48, fans: observations, dt: 1)
        check.expect(!next.contains(.setManual(fan: 0, on: false)), "a retarget never hands the fans back")
        let other = check.expectNoThrow("another input starts over") { try controller.setHold(target: 85, input: .max) }
        check.expectEqual(other, Bool?.some(false), "a different input starts a fresh loop")
    }

    do {
        let controller = FanController(fans: fanList)
        _ = check.expectNoThrow("curve accepted before restart") { try controller.setCurve(steep, input: .max) }
        controller.noteApplied(controller.tick(temperature: 60, fans: fanList.map { _ in FanObservation(rpm: 3000, manual: false) }))
        check.expectEqual(controller.holdTarget, Double?.none, "holdTarget is nil outside hold")
        controller.restartHold()
        check.expectEqual(controller.mode, .curve, "restartHold in curve mode changes nothing")
        let after = controller.tick(temperature: 60, fans: fanList.map { _ in FanObservation(rpm: 3000, manual: true) })
        check.expectEqual(after, [], "curve ticks stay unchanged after restartHold")
    }
}
