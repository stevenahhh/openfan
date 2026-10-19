import Foundation

/// Watches the undocumented TVS0 system temperature for a frozen reading. A stuck value would make the
/// hold loop chase a fiction, so a stuck sensor yields nil and the caller drops control to Auto.
///
/// A value counts as stuck when it has not moved by 0.05 C for `stuckAfter` seconds while the hottest die
/// swung at least `dieSwing` degrees in that window: the die is clearly working, so the system sensor
/// should have moved too. Until the die swings, a flat value is indistinguishable from a steady machine.
public struct SystemInputWatch: Sendable {
    private let stuckAfter: Double
    private let dieSwing: Double
    private var lastValue: Double?
    private var lastChange: Double?
    private var minDie: Double?
    private var maxDie: Double?
    private var stalled = false

    public init(stuckAfter: Double = 300, dieSwing: Double = 10) {
        self.stuckAfter = stuckAfter
        self.dieSwing = dieSwing
    }

    /// The system value when it is trustworthy, nil otherwise. Monotonic seconds in `now`.
    public mutating func check(system: Double?, die: Double?, now: Double) -> Double? {
        guard let system, system.isFinite else { return nil }

        if lastValue == nil || abs(system - lastValue!) >= 0.05 {
            // The first sample and every real change restart the stuck window and its die swing.
            lastValue = system
            lastChange = now
            minDie = die
            maxDie = die
            stalled = false
            return system
        }

        if let die {
            minDie = minDie.map { min($0, die) } ?? die
            maxDie = maxDie.map { max($0, die) } ?? die
        }
        if stalled { return nil }
        if let lastChange, let minDie, let maxDie,
           now - lastChange >= stuckAfter, maxDie - minDie >= dieSwing {
            stalled = true
            return nil
        }
        return system
    }
}
