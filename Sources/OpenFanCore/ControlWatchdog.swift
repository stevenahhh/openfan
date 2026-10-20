import Foundation

/// Notices when the helper has dropped back to Auto while the app still has a preset selected (a sensor loss, a
/// restart, a write that failed and recovered), so the app sends the preset again instead of showing a preset that is
/// not running. Two Auto replies in a row count, so a status read racing a command just sent never triggers a resend,
/// and a resend happens at most once per `retryInterval`.
public struct ControlWatchdog: Equatable, Sendable {
    public let retryInterval: Double
    private var autoStreak = 0
    private var lastResend: Double?

    public init(retryInterval: Double = 30) {
        self.retryInterval = retryInterval
    }

    /// True once Auto outlasted a resend (the third reply in a row); the popover says so.
    public var isLost: Bool { autoStreak >= 3 }

    /// Feeds one STATUS reply. Returns true when the selected preset should be sent again now.
    public mutating func observe(mode: HelperMode, presetSelected: Bool, now: Double) -> Bool {
        guard presetSelected, mode == .auto else {
            autoStreak = 0
            return false
        }
        autoStreak += 1
        guard autoStreak >= 2 else { return false }
        if let lastResend, now - lastResend < retryInterval { return false }
        lastResend = now
        return true
    }

    /// A preset was just chosen or sent: the next replies start a fresh count.
    public mutating func reset() {
        autoStreak = 0
        lastResend = nil
    }
}
