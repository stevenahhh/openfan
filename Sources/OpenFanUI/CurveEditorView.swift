import AppKit
import OpenFanCore

/// Core Graphics graph of one fan curve: X = temperature 0...110 C, Y = speed 0...100 percent.
/// The base graph redraws only when the points, the size or the hover/drag state change. The live marker is made of
/// layers, so its once-a-second updates never redraw the backing store.
final class CurveEditorView: NSView {
    /// Fires after every accepted edit (drag step, insert, remove) with the new points.
    var onEdit: (([CurvePoint]) -> Void)?

    /// Fires once an edit is finished: when a drag ends, and after an insert or a remove.
    var onCommit: (([CurvePoint]) -> Void)?

    /// Fires when a drag of the cruise target line ends with a new target.
    var onCruiseCommit: ((Double) -> Void)?

    /// Built-in presets are shown but cannot be dragged, extended or trimmed.
    var isEditable = true {
        didSet {
            guard isEditable != oldValue else { return }
            dragIndex = nil
            hoverIndex = nil
            needsDisplay = true
        }
    }

    private(set) var points: [CurvePoint] = [] {
        didSet { renderLive() }
    }

    private var dragIndex: Int?
    private var dragMoved = false
    private var dragOffset = NSSize.zero
    private var hoverIndex: Int?
    private var trackingArea: NSTrackingArea?
    private let live = CurveLiveMarker()
    private var speed = FanSpeedFormat(fan: nil, showsRPM: false)

    /// A cruise preset: the graph zooms to `axis`, draws the target as a line and lets it be dragged within `range`.
    private var cruise: (target: Double, axis: ClosedRange<Double>, range: ClosedRange<Double>)?
    private var cruiseDragging = false
    private var cruiseHover = false
    private var cruisePercent: Double?

    var plot: CurvePlot {
        guard let cruise else { return CurvePlot(bounds: bounds) }
        return CurvePlot(bounds: bounds, tMin: cruise.axis.lowerBound, tMax: cruise.axis.upperBound)
    }

    /// Shows a cruise target instead of a curve, or nil to go back to curves.
    func setCruise(target: Double, axis: ClosedRange<Double>, range: ClosedRange<Double>) {
        if let cruise, cruise.target == target, cruise.axis == axis, cruise.range == range { return }
        self.cruise = (target, axis, range)
        cruiseDragging = false
        needsDisplay = true
        renderLive()
    }

    func clearCruise() {
        guard cruise != nil else { return }
        cruise = nil
        cruiseDragging = false
        cruiseHover = false
        needsDisplay = true
        renderLive()
    }

    /// The fans' real speed in percent of their range, nil while they are stopped; used only on a cruise preset.
    func setCruisePercent(_ percent: Double?) {
        let rounded = percent.map { ($0 * 10).rounded() / 10 }
        guard rounded != cruisePercent else { return }
        cruisePercent = rounded
        renderLive()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Fan curve graph")
        wantsLayer = true
        live.attach(to: layer!, contentsScale: window?.backingScaleFactor ?? 2)
        applyLiveColors()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setPoints(_ newPoints: [CurvePoint]) {
        guard newPoints != points else { return }
        points = newPoints
        dragIndex = nil
        hoverIndex = nil
        needsDisplay = true
    }

    /// Hands the live values to the marker; the graph itself redraws only when a displayed value changed.
    func setLive(temperature: Float?, speed: FanSpeedFormat) {
        self.speed = speed
        if live.set(temperature: temperature, speed: speed) {
            renderLive()
        }
    }

    override func layout() {
        super.layout()
        renderLive()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        live.setContentsScale(window?.backingScaleFactor ?? 2)
        applyLiveColors()
        renderLive()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLiveColors()
    }

    override func draw(_ dirtyRect: NSRect) {
        CurveDrawing(
            points: points,
            mapping: plot,
            bounds: bounds,
            isEditable: isEditable,
            dragIndex: dragIndex,
            hoverIndex: hoverIndex,
            speed: speed,
            scale: window?.backingScaleFactor ?? 2,
            cruise: cruise.map { CruiseMark(target: $0.target, active: cruiseDragging || cruiseHover) }
        ).draw()
    }

    private func applyLiveColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { live.applyColors() }
    }

    private func renderLive() {
        live.render(points: points, plot: plot, suppressed: dragIndex != nil || cruiseDragging,
                    cruise: cruise != nil, cruisePercent: cruisePercent)
    }

    private func hitIndex(at location: NSPoint) -> Int? {
        let mapping = plot
        var best: Int?
        var bestDistance = CurveStyle.hitRadius
        for (index, point) in points.enumerated() {
            let center = mapping.point(t: point.t, p: point.p)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func hitsCruise(_ location: NSPoint) -> Bool {
        guard let cruise else { return false }
        let mapping = plot
        let x = mapping.point(t: cruise.target, p: 0).x
        return abs(location.x - x) <= CurveStyle.hitRadius && location.y >= mapping.rect.minY && location.y <= mapping.rect.maxY
    }

    override func mouseMoved(with event: NSEvent) {
        if cruise != nil {
            let hover = hitsCruise(convert(event.locationInWindow, from: nil))
            if hover != cruiseHover {
                cruiseHover = hover
                needsDisplay = true
            }
            return
        }
        guard isEditable else { return }
        updateHover(to: hitIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        if cruiseHover {
            cruiseHover = false
            needsDisplay = true
        }
        updateHover(to: nil)
    }

    private func updateHover(to index: Int?) {
        guard index != hoverIndex else { return }
        hoverIndex = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if cruise != nil {
            // Anywhere in the plot works, not only on the line: a click moves the target there and a drag follows.
            let location = convert(event.locationInWindow, from: nil)
            guard plot.rect.insetBy(dx: -CurveStyle.hitRadius, dy: 0).contains(location) else { return }
            cruiseDragging = true
            moveCruise(to: location)
            return
        }
        guard isEditable else { return }
        let location = convert(event.locationInWindow, from: nil)
        let hit = hitIndex(at: location)

        // Control-click acts as a right click.
        if event.modifierFlags.contains(.control) {
            if let hit { removePoint(at: hit) }
            return
        }

        if let hit {
            let center = plot.point(t: points[hit].t, p: points[hit].p)
            dragIndex = hit
            dragMoved = false
            dragOffset = NSSize(width: center.x - location.x, height: center.y - location.y)
            needsDisplay = true
            renderLive()
            return
        }

        if event.clickCount == 2, plot.rect.contains(location) {
            insertPoint(at: location)
        }
    }

    private func moveCruise(to location: NSPoint) {
        guard var current = cruise else { return }
        let t = (plot.data(at: location).t * 2).rounded() / 2
        let target = min(max(t, current.range.lowerBound), current.range.upperBound)
        if target != current.target {
            current.target = target
            cruise = current
        }
        needsDisplay = true
        renderLive()
    }

    /// The target the line shows right now, including an unfinished drag.
    var cruiseTarget: Double? { cruise?.target }

    override func mouseDragged(with event: NSEvent) {
        if cruiseDragging {
            moveCruise(to: convert(event.locationInWindow, from: nil))
            return
        }
        guard let index = dragIndex, points.indices.contains(index) else { return }
        let location = convert(event.locationInWindow, from: nil)
        let target = plot.data(at: NSPoint(x: location.x + dragOffset.width, y: location.y + dragOffset.height))
        let moved = CurveGeometry.moved(points, index: index, toTemperature: target.t, percent: target.p)
        if moved != points[index] {
            points[index] = moved
            dragMoved = true
            onEdit?(points)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if cruiseDragging {
            cruiseDragging = false
            cruiseHover = hitsCruise(convert(event.locationInWindow, from: nil))
            needsDisplay = true
            renderLive()
            if let target = cruise?.target { onCruiseCommit?(target) }
            return
        }
        guard dragIndex != nil else { return }
        dragIndex = nil
        if dragMoved {
            dragMoved = false
            onCommit?(points)
        }
        hoverIndex = hitIndex(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        renderLive()
    }

    override func rightMouseDown(with event: NSEvent) {
        // No super call: the default implementation would look for a context menu.
        guard isEditable, cruise == nil else { return }
        if let hit = hitIndex(at: convert(event.locationInWindow, from: nil)) {
            removePoint(at: hit)
        }
    }

    private func insertPoint(at location: NSPoint) {
        let target = plot.data(at: location)
        guard let updated = CurveGeometry.inserting(into: points, temperature: target.t, percent: target.p) else {
            NSSound.beep()
            return
        }
        points = updated
        hoverIndex = nil
        onEdit?(points)
        onCommit?(points)
        needsDisplay = true
    }

    private func removePoint(at index: Int) {
        guard let updated = CurveGeometry.removing(from: points, index: index) else {
            NSSound.beep()
            return
        }
        points = updated
        dragIndex = nil
        hoverIndex = nil
        onEdit?(points)
        onCommit?(points)
        needsDisplay = true
    }
}
