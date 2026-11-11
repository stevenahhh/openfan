import AppKit
import OpenFanCore

/// The once-a-second overlay on the graph: a dashed line at the current temperature, a dot on the curve, and a pill
/// with the temperature and the speed the curve asks for. While a gradual cool-down holds the fans above the curve, a
/// red line marks the speed they are held at, from the cold end of the graph to where the curve takes over again, and
/// the pill moves to a red dot on it: where the fans are, not where the curve will bring them.
/// It is built from layers, so an update never redraws the graph's backing store.
final class CurveLiveMarker {
    private let line = CAShapeLayer()
    private let rampLine = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let rampDot = CAShapeLayer()
    private let pill = CALayer()
    private let text = CATextLayer()

    private var rampPercent: Double?
    private var descending = false
    private var liveTint: CGColor?
    private var rampTint: CGColor?
    private var temperature: Float?
    private var speed = FanSpeedFormat(fan: nil, showsRPM: false)

    /// No layer property ever fades or slides: the live readout jumps to each new value.
    private static let noAnimations: [String: CAAction] = Dictionary(
        uniqueKeysWithValues: ["contents", "string", "bounds", "position", "frame", "path", "hidden", "opacity"]
            .map { ($0, NSNull()) }
    )

    init() {
        line.fillColor = nil
        line.lineWidth = CurveStyle.liveLineWidth
        line.lineDashPattern = [5, 3]
        dot.lineWidth = CurveStyle.dotRingWidth
        rampLine.fillColor = nil
        rampLine.lineWidth = CurveStyle.curveWidth
        rampLine.lineCap = .round
        rampDot.lineWidth = CurveStyle.dotRingWidth
        pill.borderWidth = 1
        text.font = CurveStyle.pillFont
        text.fontSize = CurveStyle.pillFont.pointSize
        text.alignmentMode = .left
        text.truncationMode = .none
        text.isWrapped = true
        pill.addSublayer(text)
        text.actions = Self.noAnimations
        for layer in shapeLayers {
            layer.actions = Self.noAnimations
            layer.isHidden = true
        }
    }

    /// Back to front: the held speed's line lies under both dots, the pill over everything.
    private var shapeLayers: [CALayer] {
        [line, rampLine, dot, rampDot, pill]
    }

    private var rampLayers: [CALayer] {
        [rampLine, rampDot]
    }

    func attach(to host: CALayer, contentsScale: CGFloat) {
        for layer in shapeLayers { host.addSublayer(layer) }
        text.contentsScale = contentsScale
    }

    func setContentsScale(_ scale: CGFloat) {
        text.contentsScale = scale
    }

    /// Keeps the temperature as shown (0.1 C). Returns true when a displayed value changed.
    @discardableResult
    func set(temperature: Float?, speed: FanSpeedFormat) -> Bool {
        let newTemperature = temperature.flatMap { $0.isFinite ? ($0 * 10).rounded() / 10 : nil }
        guard newTemperature != self.temperature || speed != self.speed else { return false }
        self.temperature = newTemperature
        self.speed = speed
        return true
    }

    /// Keeps the held speed as shown (0.1 %). Returns true when it changed.
    @discardableResult
    func setRamp(_ percent: Double?) -> Bool {
        let rounded = percent.flatMap { $0.isFinite ? ($0 * 10).rounded() / 10 : nil }
        guard rounded != rampPercent else { return false }
        rampPercent = rounded
        return true
    }

    func applyColors() {
        let orange = NSColor.systemOrange.cgColor
        let red = NSColor.systemRed.cgColor
        liveTint = orange
        rampTint = red
        line.strokeColor = orange
        dot.fillColor = orange
        dot.strokeColor = NSColor.textBackgroundColor.cgColor
        rampLine.strokeColor = red
        rampDot.fillColor = red
        rampDot.strokeColor = NSColor.textBackgroundColor.cgColor
        pill.borderColor = descending ? red : orange
        pill.backgroundColor = NSColor.controlBackgroundColor.cgColor
        text.foregroundColor = NSColor.labelColor.cgColor
    }

    /// On a cruise preset there is no curve to sit on: `cruisePercent` is the fans' real speed (nil while they are
    /// stopped), and the dot shows where the fans are rather than where a curve would put them.
    func render(points: [CurvePoint], plot: CurvePlot, suppressed: Bool = false, cruise: Bool = false, cruisePercent: Double? = nil) {
        let bounds = plot.rect
        let visible = !suppressed && temperature != nil && (cruise || !points.isEmpty) && bounds.width > 8 && bounds.height > 8
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [line, dot, pill] where layer.isHidden == visible {
            layer.isHidden = !visible
        }
        guard visible, let temperature else {
            for layer in rampLayers where !layer.isHidden { layer.isHidden = true }
            return
        }

        let curve = FanCurve(points: points)
        let clamped = min(max(Double(temperature), plot.tMin), plot.tMax)
        let percent = cruise ? (cruisePercent ?? 0) : curve.percent(at: Double(temperature))
        let center = plot.point(t: clamped, p: percent)
        // A held speed only counts while it is above what the curve asks for here: once they meet, the descent is over.
        let held = cruise ? nil : rampPercent.flatMap { $0 > percent ? $0 : nil }
        descending = held != nil
        for layer in rampLayers where layer.isHidden == descending {
            layer.isHidden = !descending
        }
        pill.borderColor = descending ? rampTint : liveTint

        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: bounds.minY))
        path.addLine(to: CGPoint(x: center.x, y: bounds.maxY))
        line.path = path
        dot.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - CurveStyle.liveDotRadius,
                y: center.y - CurveStyle.liveDotRadius,
                width: CurveStyle.liveDotRadius * 2,
                height: CurveStyle.liveDotRadius * 2
            ),
            transform: nil
        )

        var anchor = center
        var speedLine = cruise && cruisePercent == nil ? "fans off" : speed.text(forCurvePercent: percent)
        if let held {
            // The line starts at the cold end, where the curve alone would already have let the fans stop, and ends
            // where the curve climbs back up to the held speed.
            let meets = min(max(curve.temperature(reaching: held) ?? plot.tMax, plot.tMin), plot.tMax)
            anchor = plot.point(t: clamped, p: held)
            let floor = CGMutablePath()
            floor.move(to: CGPoint(x: bounds.minX + CurveStyle.curveWidth / 2, y: anchor.y))
            floor.addLine(to: CGPoint(x: plot.point(t: meets, p: held).x, y: anchor.y))
            rampLine.path = floor
            rampDot.path = CGPath(
                ellipseIn: CGRect(
                    x: anchor.x - CurveStyle.liveDotRadius,
                    y: anchor.y - CurveStyle.liveDotRadius,
                    width: CurveStyle.liveDotRadius * 2,
                    height: CurveStyle.liveDotRadius * 2
                ),
                transform: nil
            )
            speedLine = speed.text(forCurvePercent: held) + " \u{2193}"
        }
        let lines = [String(format: "%.1f\u{00B0}C", temperature), speedLine]
        let label = lines.joined(separator: "\n")
        let size = CurvePill.size(for: lines)
        var x = anchor.x + CurveStyle.pillOffset
        if x + size.width > bounds.maxX {
            x = anchor.x - CurveStyle.pillOffset - size.width
        }
        pill.frame = CGRect(
            x: min(max(x, bounds.minX), bounds.maxX - size.width),
            y: min(max(anchor.y + CurveStyle.pillOffset, bounds.minY), bounds.maxY - size.height),
            width: size.width,
            height: size.height
        )
        pill.cornerRadius = size.height / 2
        text.frame = CGRect(
            x: CurveStyle.pillPaddingX,
            y: CurveStyle.pillPaddingY,
            width: size.width - CurveStyle.pillPaddingX * 2,
            height: size.height - CurveStyle.pillPaddingY * 2
        )
        if text.string as? String != label {
            text.string = label
        }
    }
}
