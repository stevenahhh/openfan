import AppKit
import OpenFanCore

private final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(symbol: String, description: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        contentTintColor = .secondaryLabelColor
        toolTip = description
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            // The popover does not make the app active, so the help must appear for an inactive app too.
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

/// The footer's update label. `available` and `failed` are clickable and start the update.
public enum UpdateOffer: Equatable {
    case available(version: String)
    case installing(version: String)
    case failed(version: String, reason: String)
}

final class PopoverFooter: NSView {
    var menuProvider: (() -> NSMenu)?
    var onUpdate: (() -> Void)?
    var onHelpChange: ((Bool) -> Void)?

    private let helpButton = HoverButton(symbol: "questionmark.circle", description: "Help")
    private let pressureDot = NSImageView()
    private let pressureLabel = NSTextField(labelWithString: "")
    private let menuButton = HoverButton(symbol: "line.3.horizontal", description: "More")
    private let updateButton = NSButton(title: "", target: nil, action: nil)
    private var helpShown = false

    var helpAnchor: NSRect? {
        guard helpButton.window != nil else { return nil }
        return helpButton.convert(helpButton.bounds, to: nil)
    }

    init(width: CGFloat) {
        super.init(frame: .zero)

        pressureLabel.font = .systemFont(ofSize: 11)
        pressureLabel.textColor = .labelColor

        helpButton.target = self
        helpButton.action = #selector(helpTapped(_:))
        helpButton.onHover = { [weak self] inside in
            guard let self else { return }
            self.setHelpShown(inside)
        }
        menuButton.target = self
        menuButton.action = #selector(menuTapped(_:))
        menuButton.toolTip = "Settings, install, uninstall, quit"

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)

        updateButton.isBordered = false
        updateButton.bezelStyle = .regularSquare
        updateButton.font = .systemFont(ofSize: 11, weight: .semibold)
        updateButton.contentTintColor = .controlAccentColor
        updateButton.target = self
        updateButton.action = #selector(updateTapped(_:))
        updateButton.isHidden = true

        let row = NSStackView(views: [helpButton, pressureDot, pressureLabel, spacer, updateButton, menuButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setCustomSpacing(10, after: pressureLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])

        for button in [helpButton, menuButton] {
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        }
        update(pressure: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(pressure: MemoryPressure?) {
        pressureDot.isHidden = pressure == nil
        pressureLabel.isHidden = pressure == nil
        guard let pressure else { return }
        pressureDot.image = pressure.dotImage(size: 8)
        pressureLabel.stringValue = "Memory \(pressure.label)"
    }

    func update(offer: UpdateOffer?) {
        updateButton.isHidden = offer == nil
        guard let offer else { return }
        let title: String
        let tip: String
        switch offer {
        case let .available(version):
            title = "Update available!"
            tip = "Install OpenFan \(version) and relaunch"
        case let .installing(version):
            title = "Updating…"
            tip = "Downloading and checking OpenFan \(version)"
        case let .failed(version, reason):
            title = "Update failed, retry"
            tip = "OpenFan \(version): \(reason)"
        }
        if updateButton.title != title { updateButton.title = title }
        updateButton.toolTip = tip
        updateButton.setAccessibilityLabel(tip)
        if case .installing = offer { updateButton.isEnabled = false } else { updateButton.isEnabled = true }
    }

    @objc private func updateTapped(_ sender: Any?) {
        onUpdate?()
    }

    func dismissHelp() {
        setHelpShown(false)
    }

    private func setHelpShown(_ shown: Bool) {
        guard shown != helpShown else { return }
        helpShown = shown
        onHelpChange?(shown)
    }

    @objc private func helpTapped(_ sender: Any?) {
        setHelpShown(!helpShown)
    }

    @objc private func menuTapped(_ sender: Any?) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY + 6),
                   in: self)
    }
}
