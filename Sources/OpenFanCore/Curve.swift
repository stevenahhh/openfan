import Foundation
import OpenFanSMC

public enum CurveError: Error, CustomStringConvertible, Equatable {
    case tooFewPoints(Int)
    case tooManyPoints(Int)
    case notStrictlyIncreasing(index: Int)
    case temperatureOutOfRange(index: Int)
    case percentOutOfRange(index: Int)
    case decreasingPercent(index: Int)

    public var description: String {
        switch self {
        case .tooFewPoints(let n): return "curve needs at least 2 points (has \(n))"
        case .tooManyPoints(let n): return "curve allows at most 12 points (has \(n))"
        case .notStrictlyIncreasing(let i): return "point \(i) is not strictly above the previous temperature"
        case .temperatureOutOfRange(let i): return "point \(i) temperature is outside 0...130"
        case .percentOutOfRange(let i): return "point \(i) percent is outside 0...100"
        case .decreasingPercent(let i): return "point \(i) percent is below the previous point (a hotter point must not slow the fan)"
        }
    }
}

/// One control point: temperature in Celsius, speed as percent of the fan's [Mn, Mx] range.
public struct CurvePoint: Codable, Equatable, Sendable {
    public var t: Double
    public var p: Double

    public init(t: Double, p: Double) {
        self.t = t
        self.p = p
    }
}

/// Piecewise-linear temperature-to-speed curve.
public struct FanCurve: Codable, Equatable, Sendable {
    public static let minPoints = 2
    public static let maxPoints = 12
    public static let minTemperature: Double = 0
    public static let maxTemperature: Double = 130

    public var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = points
    }

    /// Throws the first CurveError found. Order: point count, then per point the temperature range,
    /// the percent range, and finally the monotonicity of temperature and percent.
    public func validate() throws {
        let count = points.count
        if count < FanCurve.minPoints { throw CurveError.tooFewPoints(count) }
        if count > FanCurve.maxPoints { throw CurveError.tooManyPoints(count) }
        for (index, point) in points.enumerated() {
            guard point.t.isFinite,
                  point.t >= FanCurve.minTemperature,
                  point.t <= FanCurve.maxTemperature else {
                throw CurveError.temperatureOutOfRange(index: index)
            }
            guard point.p.isFinite, point.p >= 0, point.p <= 100 else {
                throw CurveError.percentOutOfRange(index: index)
            }
            if index > 0 {
                if point.t <= points[index - 1].t {
                    throw CurveError.notStrictlyIncreasing(index: index)
                }
                if point.p < points[index - 1].p {
                    throw CurveError.decreasingPercent(index: index)
                }
            }
        }
    }

    /// The lowest temperature at which the curve asks for at least `percent`: where a speed held above the curve
    /// meets it again. Nil when the curve never gets that high.
    public func temperature(reaching percent: Double) -> Double? {
        guard let first = points.first else { return nil }
        if first.p >= percent { return FanCurve.minTemperature }
        for index in 0..<(points.count - 1) {
            let lower = points[index]
            let upper = points[index + 1]
            guard upper.p >= percent else { continue }
            let rise = upper.p - lower.p
            if rise <= 0 { return upper.t }
            return lower.t + (percent - lower.p) / rise * (upper.t - lower.t)
        }
        return nil
    }

    /// Piecewise-linear lookup: clamps below the first and above the last point, interpolates between
    /// neighbouring points otherwise.
    public func percent(at temperature: Double) -> Double {
        guard let first = points.first else { return 0 }
        if temperature <= first.t { return first.p }
        guard let last = points.last else { return first.p }
        if temperature >= last.t { return last.p }
        for index in 0..<(points.count - 1) {
            let lower = points[index]
            let upper = points[index + 1]
            if temperature >= lower.t && temperature <= upper.t {
                let span = upper.t - lower.t
                if span <= 0 { return upper.p }
                let fraction = (temperature - lower.t) / span
                return lower.p + (upper.p - lower.p) * fraction
            }
        }
        return last.p
    }
}
