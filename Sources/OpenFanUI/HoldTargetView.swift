import AppKit
import OpenFanCore
import OpenFanSMC

/// What the editor shows in place of the graph for a hold preset: what it holds, the live reading and a slider for
/// the target (on a built-in, releasing the slider saves the user's own copy).
final class HoldTargetView: NSView {
    /// Called while the slider moves (`committed` false) and once when it is released (`committed` true).
    var onTarget: ((Double, _ committed: Bool) -> Void)?

    private let summary = NSTextField(wrappingLabelWithString: "")
    private let live = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 45, minValue: 40, maxValue: 50, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")
    private let sliderRow = NSStackView()
    private let note = NSTextField(wrappingLabelWithString: "")

    private var preset: Preset?

    init(width: CGFloat) {
        super.init(frame: .zero)
        summary.font = .systemFont(ofSize: 12)
        summary.preferredMaxLayoutWidth = width
        live.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = width
        note.stringValue = "Above about 50 \u{00B0}C (system) macOS may lower performance before the fans reach full speed."

        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("Target temperature")
        sliderRow.setViews([slider, valueLabel], in: .leading)
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 8
        slider.widthAnchor.constraint(equalToConstant: width - 64).isActive = true

        let stack = NSStackView(views: [summary, live, sliderRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.widthAnchor.constraint(equalToConstant: width),
            note.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func show(_ preset: Preset) {
        self.preset = preset
        guard let target = preset.target else { return }
        let range = Preset.holdRange(for: preset.input)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = Int((range.upperBound - range.lowerBound) * 2) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        if slider.doubleValue != target { slider.doubleValue = target }
        note.isHidden = preset.input != .system
        refreshText(target: target)
    }

    /// `holding` is true while the helper runs this hold, so the reading next to it is the loop's own input.
    func updateLive(temperature: Float?, holding: Bool) {
        let now = temperature.map { String(format: "%.1f \u{00B0}C", $0) } ?? "--"
        let text: String
        if holding, let target = preset?.target {
            text = "\(now)  \u{2192}  holding \(Self.degrees(target))"
        } else {
            text = now
        }
        if live.stringValue != text { live.stringValue = text }
    }

    private func refreshText(target: Double) {
        guard let preset else { return }
        let source = CurveEditorPanel.holdSourceName(for: preset.input)
        let text = "Holds \(source) at \(Self.degrees(target)) as quietly as possible, and hands the fans back to macOS when they are not needed."
        if summary.stringValue != text { summary.stringValue = text }
        let value = Self.degrees(target)
        if valueLabel.stringValue != value { valueLabel.stringValue = value }
    }

    @objc private func sliderMoved(_ sender: Any?) {
        let value = (slider.doubleValue * 2).rounded() / 2
        refreshText(target: value)
        let committed = NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .keyDown
        onTarget?(value, committed)
    }

    static func degrees(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) \u{00B0}C" : String(format: "%.1f \u{00B0}C", value)
    }
}
