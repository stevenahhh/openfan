import Foundation
import OpenFanSMC

/// How a fan speed is worded for the person looking at it, so the header and the graph's readouts say the same thing
/// about the same speed: a percentage of the fan's own range (its slowest speed is 0 %, its fastest 100 %), or rpm.
public struct FanSpeedFormat: Equatable, Sendable {
    public var fan: FanInfo?
    public var showsRPM: Bool

    public init(fan: FanInfo?, showsRPM: Bool) {
        self.fan = fan
        self.showsRPM = showsRPM
    }

    /// What a curve value asks the fan to do. A curve is drawn between the fan's slowest and fastest speed, which is
    /// the scale the percentage uses too, so the number shown is the one the curve's height reads. At 0 or below the
    /// fans go back to macOS.
    public func text(forCurvePercent percent: Double) -> String {
        guard let fan else { return "--" }
        guard percent > 0 else { return "Auto" }
        if showsRPM { return "\(Int(fan.rpm(percent: percent).rounded())) rpm" }
        return "\(Int(min(percent, 100).rounded()))%"
    }
}
