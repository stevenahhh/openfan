import AppKit

/// Maps between data space (degrees C, percent of range) and the graph's plot rectangle. A curve spans the whole
/// 0...110 C axis; a cruise preset zooms in on the band around its target.
struct CurvePlot {
    var bounds: NSRect
    var tMin: Double = 0
    var tMax: Double = CurveGeometry.maxTemperature

    var rect: NSRect {
        NSRect(
            x: bounds.minX + CurveStyle.leftMargin,
            y: bounds.minY + CurveStyle.bottomMargin,
            width: max(bounds.width - CurveStyle.leftMargin - CurveStyle.rightMargin, 1),
            height: max(bounds.height - CurveStyle.bottomMargin - CurveStyle.topMargin, 1)
        )
    }

    func point(t: Double, p: Double) -> NSPoint {
        let plot = rect
        return NSPoint(
            x: plot.minX + CGFloat((t - tMin) / (tMax - tMin)) * plot.width,
            y: plot.minY + CGFloat(p / CurveGeometry.maxPercent) * plot.height
        )
    }

    func data(at location: NSPoint) -> (t: Double, p: Double) {
        let plot = rect
        return (
            t: tMin + Double((location.x - plot.minX) / plot.width) * (tMax - tMin),
            p: Double((location.y - plot.minY) / plot.height) * CurveGeometry.maxPercent
        )
    }
}
