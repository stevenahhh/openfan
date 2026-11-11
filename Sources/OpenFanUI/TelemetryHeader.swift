import AppKit
import OpenFanSMC

struct HeaderReadout: Equatable {
    struct Fan: Equatable {
        var index: Int
        var rpm: Float?
        var minRPM: Float?
        var maxRPM: Float?

        /// Percent of the fan's own range, the scale a curve is drawn on: Mn reads 0 % and Mx 100 %. A stopped fan
        /// reads 0 % as well; the rpm view tells the two apart.
        var percent: Float? {
            guard let rpm, let minRPM, let maxRPM, maxRPM > minRPM else { return nil }
            return min(max((rpm - minRPM) / (maxRPM - minRPM) * 100, 0), 100)
        }
    }

    var cpu: Float?
    var gpu: Float?
    var battery: Float?
    var hasBattery = true
    var fanRows: [[Fan]] = []

    private static let maxFansPerRow = 3

    init() {}

    init(reading: SensorReading?, fans info: [FanInfo]) {
        cpu = reading?.cpu
        gpu = reading?.gpu
        battery = reading?.battery
        let fans = info.map { limit in
            Fan(index: limit.index,
                rpm: reading?.fans.first { $0.index == limit.index }?.rpm,
                minRPM: limit.minRPM,
                maxRPM: limit.maxRPM)
        }
        fanRows = Self.rows(of: fans)
    }

    /// The fewest rows of at most three fans, as even as possible, so each row's fans fill its whole width.
    private static func rows(of fans: [Fan]) -> [[Fan]] {
        let rowCount = (fans.count + maxFansPerRow - 1) / maxFansPerRow
        guard rowCount > 0 else { return [] }
        let perRow = (fans.count + rowCount - 1) / rowCount
        return stride(from: 0, to: fans.count, by: perRow).map { Array(fans[$0..<min($0 + perRow, fans.count)]) }
    }
}

private final class HeaderColumn: NSView {
    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 26, weight: .semibold)
    private static let captionFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)

    private let value = RollingNumberView(font: HeaderColumn.valueFont)
    private let caption = NSTextField(labelWithString: "")

    /// The value and its caption sit on the column's vertical axis, so the pair is centered in its grid cell.
    init() {
        super.init(frame: .zero)
        caption.font = Self.captionFont
        caption.textColor = .secondaryLabelColor
        for view in [value, caption] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
                view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            value.topAnchor.constraint(equalTo: topAnchor),
            caption.topAnchor.constraint(equalTo: value.bottomAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func set(value valueText: String, caption captionText: String) {
        value.setText(valueText, animated: true)
        if caption.stringValue != captionText { caption.stringValue = captionText }
    }
}

private final class HeaderRow: NSView {
    private let columns: [HeaderColumn]

    init(columnCount: Int) {
        columns = (0..<columnCount).map { _ in HeaderColumn() }
        super.init(frame: .zero)
        let stack = NSStackView(views: columns)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func set(_ cells: [(value: String, caption: String)]) {
        for (column, cell) in zip(columns, cells) {
            column.set(value: cell.value, caption: cell.caption)
        }
    }
}

/// The popover's top rows: CPU, GPU and battery temperatures, then one column per fan. Fan values are a percentage
/// of the fan's range until the fan row is clicked; the choice is handed to the owner to remember.
final class TelemetryHeaderView: NSView {
    var onUnitsChanged: ((Bool) -> Void)?

    private(set) var showsRPM = false

    private var temperatureRow = HeaderRow(columnCount: 3)
    private var temperatureColumns = 3
    private var fanRows: [HeaderRow] = []
    private let stack = NSStackView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        rebuild()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(_ readout: HeaderReadout) {
        let columns = readout.hasBattery ? 3 : 2
        if columns != temperatureColumns {
            temperatureColumns = columns
            temperatureRow = HeaderRow(columnCount: columns)
            for row in fanRows { row.widthAnchor.constraint(equalTo: temperatureRow.widthAnchor).isActive = true }
            stack.setViews(fanRows + [temperatureRow], in: .top)
        }
        while fanRows.count < readout.fanRows.count {
            makeFanRow(columnCount: readout.fanRows[fanRows.count].count)
        }
        var temperatures = [(Self.degrees(readout.cpu), "CPU"), (Self.degrees(readout.gpu), "GPU")]
        if readout.hasBattery { temperatures.append((Self.degrees(readout.battery), "BATTERY")) }
        temperatureRow.set(temperatures)
        for (index, row) in readout.fanRows.enumerated() where index < fanRows.count {
            fanRows[index].set(row.map(fanCell))
        }
    }

    func setShowsRPM(_ value: Bool, notify: Bool) {
        guard value != showsRPM else { return }
        showsRPM = value
        if notify { onUnitsChanged?(value) }
    }

    private func rebuild() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The fans are what the app controls, so their row sits above the temperatures.
        stack.setViews([temperatureRow], in: .top)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func makeFanRow(columnCount: Int) {
        let row = HeaderRow(columnCount: columnCount)
        row.toolTip = "Click to switch the fan values between a percentage and rpm"
        let click = NSClickGestureRecognizer(target: self, action: #selector(fanRowClicked(_:)))
        row.addGestureRecognizer(click)
        fanRows.append(row)
        stack.setViews(fanRows + [temperatureRow], in: .top)
        row.widthAnchor.constraint(equalTo: temperatureRow.widthAnchor).isActive = true
    }

    @objc private func fanRowClicked(_ sender: Any?) {
        showsRPM.toggle()
        onUnitsChanged?(showsRPM)
    }

    private func fanCell(_ fan: HeaderReadout.Fan) -> (value: String, caption: String) {
        let value: String
        if let rpm = fan.rpm {
            value = showsRPM ? String(Int(rpm.rounded())) : "\(Int((fan.percent ?? 0).rounded()))%"
        } else {
            value = "--"
        }
        return (value, "FAN \(fan.index)")
    }

    private static func degrees(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(Int(value.rounded()))\u{00B0}"
    }
}
