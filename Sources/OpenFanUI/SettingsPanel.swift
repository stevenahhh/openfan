import AppKit
import OpenFanCore

final class SettingsPanel: NSView, NSTextFieldDelegate {
    var onChange: (() -> Void)?

    private static let help: [String: String] = [
        "max": "Hottest of CPU and GPU",
        "cpu": "CPU temperature",
        "gpu": "GPU temperature",
        "bat": "Battery average temperature",
        "rpm": "Fastest fan",
        "rpm0": "Fan 0",
        "rpm1": "Fan 1",
        "preset": "Active preset name",
    ]

    private static let tokensPerRow = 4

    private let settings: SettingsStore
    private let field = NSTextField(string: "")
    private let preview = NSTextField(labelWithString: "")
    private let dotToggle = NSButton(checkboxWithTitle: "Show memory pressure dot", target: nil, action: nil)
    private let panicToggle = NSButton(checkboxWithTitle: "Full speed at 95 \u{00B0}C", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private var values = MenuBarValues()

    init(settings: SettingsStore, width: CGFloat) {
        self.settings = settings
        super.init(frame: .zero)
        configure(width: width)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(values: MenuBarValues) {
        self.values = values
        // The field follows the stored template whenever the user is not editing it, so a stray end-editing can never
        // commit a stale or empty string over it.
        if field.currentEditor() == nil, field.stringValue != settings.settings.menuBarTemplate {
            field.stringValue = settings.settings.menuBarTemplate
        }
        refreshPreview()
    }

    private func configure(width: CGFloat) {
        let title = NSTextField(labelWithString: "Menu bar text")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        field.stringValue = settings.settings.menuBarTemplate
        field.placeholderString = "No text"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.target = self
        field.action = #selector(templateCommitted(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Menu bar text template")

        let reset = NSButton(title: "Default", target: self, action: #selector(resetTapped(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.toolTip = "Use \(AppSettings.defaultTemplate)"

        let fieldRow = NSStackView(views: [field, reset])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        fieldRow.alignment = .centerY

        let buttons = MenuBarTemplate.tokens.map { token -> NSButton in
            let button = NSButton(title: "{\(token)}", target: self, action: #selector(tokenTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            button.identifier = NSUserInterfaceItemIdentifier(token)
            button.toolTip = Self.help[token]
            return button
        }
        let tokenRows = stride(from: 0, to: buttons.count, by: Self.tokensPerRow).map { start -> NSStackView in
            let row = NSStackView(views: Array(buttons[start..<min(start + Self.tokensPerRow, buttons.count)]))
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            return row
        }

        let insertCaption = Self.caption("INSERT")
        let previewCaption = Self.caption("PREVIEW")
        preview.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        preview.lineBreakMode = .byTruncatingTail

        dotToggle.target = self
        dotToggle.action = #selector(dotToggled(_:))
        dotToggle.state = settings.settings.showPressureDot ? .on : .off
        dotToggle.font = .systemFont(ofSize: 12)

        let hint = NSTextField(wrappingLabelWithString: "Click a name to insert it. Leave the field empty to show only the dot. At most \(MenuBarTemplate.maxRenderedLength) characters are shown; text that is not a name is shown as typed.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = width

        let fanTitle = NSTextField(labelWithString: "Fans")
        fanTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        panicToggle.target = self
        panicToggle.action = #selector(panicToggled(_:))
        panicToggle.state = settings.settings.panicFullSpeed ? .on : .off
        panicToggle.font = .systemFont(ofSize: 12)

        let panicHint = NSTextField(wrappingLabelWithString: "When the CPU or GPU reaches 95 \u{00B0}C, curve presets run the fans at full speed until it drops below 88 \u{00B0}C. Off leaves the curve in charge.")
        panicHint.font = .systemFont(ofSize: 10)
        panicHint.textColor = .secondaryLabelColor
        panicHint.preferredMaxLayoutWidth = width

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed

        let rows: [NSView] = [title, fieldRow, insertCaption] + tokenRows + [previewCaption, preview, dotToggle, hint, fanTitle, panicToggle, panicHint, errorLabel]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: insertCaption)
        stack.setCustomSpacing(4, after: previewCaption)
        stack.setCustomSpacing(16, after: hint)
        stack.setCustomSpacing(4, after: panicToggle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        refreshPreview()
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func refreshPreview() {
        let draft = field.currentEditor()?.string ?? field.stringValue
        let rendered = MenuBarTemplate.render(draft, values)
        let shown = rendered.isEmpty ? "(no text)" : rendered
        if preview.stringValue != shown { preview.stringValue = shown }
        preview.textColor = rendered.isEmpty ? .tertiaryLabelColor : .labelColor
    }

    private func commitTemplate() {
        let before = settings.settings.menuBarTemplate
        settings.setTemplate(field.stringValue)
        let after = settings.settings.menuBarTemplate
        if field.stringValue != after { field.stringValue = after }
        refreshPreview()
        guard after != before else { return }
        persist()
    }

    private func persist() {
        do {
            try settings.save()
            errorLabel.stringValue = ""
        } catch {
            errorLabel.stringValue = "Not saved: \(error.localizedDescription)"
            NSSound.beep()
        }
        onChange?()
    }

    @objc private func templateCommitted(_ sender: Any?) {
        commitTemplate()
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshPreview()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitTemplate()
    }

    @objc private func tokenTapped(_ sender: NSButton) {
        guard let token = sender.identifier?.rawValue else { return }
        if field.currentEditor() == nil {
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        guard let editor = field.currentEditor() else { return }
        let text = "{\(token)}"
        let range = editor.selectedRange
        editor.replaceCharacters(in: range, with: text)
        editor.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        refreshPreview()
    }

    @objc private func resetTapped(_ sender: Any?) {
        field.stringValue = AppSettings.defaultTemplate
        commitTemplate()
    }

    @objc private func dotToggled(_ sender: NSButton) {
        settings.setShowPressureDot(sender.state == .on)
        persist()
    }

    @objc private func panicToggled(_ sender: NSButton) {
        settings.setPanicFullSpeed(sender.state == .on)
        persist()
    }
}
