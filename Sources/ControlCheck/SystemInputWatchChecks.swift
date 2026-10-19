import CheckKit
import OpenFanControl
import OpenFanCore
import OpenFanSMC

func runSystemInputWatchChecks(_ check: Checker) {
    var watch = SystemInputWatch()
    check.expectEqual(watch.check(system: 45, die: 60, now: 0), Double?.some(45), "a moving system value passes through")
    check.expectEqual(watch.check(system: 45.06, die: 75, now: 100), Double?.some(45.06), "a >= 0.05 C change restarts the window")

    watch = SystemInputWatch()
    _ = watch.check(system: 45, die: 60, now: 0)
    check.expectEqual(watch.check(system: 45, die: 75, now: 301), Double?.none,
                      "frozen 301 s while the die swings 60->75 is stuck")
    check.expectEqual(watch.check(system: 45, die: 61, now: 310), Double?.none,
                      "a stuck sensor keeps returning nil")

    watch = SystemInputWatch()
    _ = watch.check(system: 45, die: 60, now: 0)
    check.expectEqual(watch.check(system: 45, die: 60, now: 301), Double?.some(45),
                      "frozen 301 s with a steady die is not stuck")

    watch = SystemInputWatch()
    _ = watch.check(system: 45, die: 60, now: 0)
    _ = watch.check(system: 45, die: 75, now: 301)
    check.expectEqual(watch.check(system: 45.03, die: 75, now: 305), Double?.none,
                      "a move below 0.05 C does not clear the stuck verdict")
    check.expectEqual(watch.check(system: 46, die: 75, now: 310), Double?.some(46),
                      "a changed value is accepted after a stuck verdict")

    watch = SystemInputWatch()
    check.expectEqual(watch.check(system: nil, die: 60, now: 0), Double?.none, "nil system yields nil")
    check.expectEqual(watch.check(system: .nan, die: 60, now: 1), Double?.none, "a non-finite system yields nil")

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
        _ = check.expectNoThrow("curve accepted before restart") { try controller.setCurve(steep, input: .max) }
        controller.noteApplied(controller.tick(temperature: 60, fans: fanList.map { _ in FanObservation(rpm: 3000, manual: false) }))
        check.expectEqual(controller.holdTarget, Double?.none, "holdTarget is nil outside hold")
        controller.restartHold()
        check.expectEqual(controller.mode, .curve, "restartHold in curve mode changes nothing")
        let after = controller.tick(temperature: 60, fans: fanList.map { _ in FanObservation(rpm: 3000, manual: true) })
        check.expectEqual(after, [], "curve ticks stay unchanged after restartHold")
    }
}
