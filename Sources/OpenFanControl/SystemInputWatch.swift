import Foundation

/// Watches the undocumented TVS0 system temperature for a frozen reading. A stuck value would make the
/// hold loop chase a fiction, so a stuck sensor yields nil and the caller hands the fans to macOS until it moves.
///
/// TVS0 is a heavily filtered value: on an idle Mac it can sit within a few hundredths of a degree for hours while
/// short background bursts spike the die. So the watch only judges while the loop holds the fans (released, macOS is
/// in charge and a flat value is harmless), follows a 20 s average of the die rather than single samples, and calls
/// the value stuck only when it stayed flat for `stuckAfter` seconds while that average swung by `dieSwing` degrees.
/// Once stuck, it stays stuck until the value moves again.
public struct SystemInputWatch: Sendable {
    private let stuckAfter: Double
    private let dieSwing: Double
    private let dieTau: Double
    private var lastValue: Double?
    private var lastChange: Double?
    private var lastNow: Double?
    private var dieAverage: Double?
    private var minDie: Double?
    private var maxDie: Double?
    public private(set) var isStuck = false

    public init(stuckAfter: Double = 600, dieSwing: Double = 15, dieTau: Double = 20) {
        self.stuckAfter = stuckAfter
        self.dieSwing = dieSwing
        self.dieTau = dieTau
    }

    /// The system value when it is trustworthy, nil while it is stuck. `engaged` is true while the loop holds the
    /// fans. Monotonic seconds in `now`.
    public mutating func check(system: Double, die: Double?, now: Double, engaged: Bool) -> Double? {
        if let die, die.isFinite {
            let dt = lastNow.map { min(max(now - $0, 0), 5) } ?? 0
            dieAverage = dieAverage.map { $0 + dt * (die - $0) / dieTau } ?? die
        }
        lastNow = now

        if lastValue == nil || abs(system - lastValue!) >= 0.05 {
            // The first sample and every real change restart the window and clear a stuck verdict.
            restartWindow(value: system, now: now)
            isStuck = false
            return system
        }
        if isStuck { return nil }
        guard engaged else {
            restartWindow(value: lastValue!, now: now)
            return system
        }

        if let average = dieAverage {
            minDie = minDie.map { min($0, average) } ?? average
            maxDie = maxDie.map { max($0, average) } ?? average
        }
        if let lastChange, let minDie, let maxDie, now - lastChange >= stuckAfter, maxDie - minDie >= dieSwing {
            isStuck = true
            return nil
        }
        return system
    }

    private mutating func restartWindow(value: Double, now: Double) {
        lastValue = value
        lastChange = now
        minDie = dieAverage
        maxDie = dieAverage
    }
}
