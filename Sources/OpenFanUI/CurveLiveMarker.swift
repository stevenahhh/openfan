import AppKit
import OpenFanCore

/// The once-a-second overlay on the graph: a dashed line at the current temperature, a dot on the curve, and a pill
/// with the temperature and the speed the curve asks for. It is built from layers, so an update never redraws the graph's backing store.
final class CurveLiveMarker {
    private let line = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let pill = CALayer()
    private let text = CATextLayer()

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

    private var allLayers: [CALayer] {
        [line, dot, pill, text]
    }

    private var shapeLayers: [CALayer] {
        [line, dot, pill]
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

    func applyColors() {
        let orange = NSColor.systemOrange.cgColor
        line.strokeColor = orange
        dot.fillColor = orange
        dot.strokeColor = NSColor.textBackgroundColor.cgColor
        pill.borderColor = orange
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
        for layer in shapeLayers where layer.isHidden == visible {
            layer.isHidden = !visible
        }
        guard visible, let temperature else { return }

        let clamped = min(max(Double(temperature), plot.tMin), plot.tMax)
        let percent = cruise ? (cruisePercent ?? 0) : FanCurve(points: points).percent(at: Double(temperature))
        let center = plot.point(t: clamped, p: percent)

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

        let speedLine = cruise && cruisePercent == nil ? "fans off" : speed.text(forCurvePercent: percent)
        let lines = [String(format: "%.1f\u{00B0}C", temperature), speedLine]
        let label = lines.joined(separator: "\n")
        let size = CurvePill.size(for: lines)
        var x = center.x + CurveStyle.pillOffset
        if x + size.width > bounds.maxX {
            x = center.x - CurveStyle.pillOffset - size.width
        }
        pill.frame = CGRect(
            x: min(max(x, bounds.minX), bounds.maxX - size.width),
            y: min(max(center.y + CurveStyle.pillOffset, bounds.minY), bounds.maxY - size.height),
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
