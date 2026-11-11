import AppKit

/// The preset name, shown as a label until the user asks to rename it. A rename is committed only by Save or
/// Return; clicking away, Escape and Cancel leave the stored name untouched.
final class PresetNameEditor: NSView, NSTextFieldDelegate {
    /// Called with a non-empty, trimmed name when the user saves.
    var onCommit: ((String) -> Void)?

    var onError: ((String) -> Void)?

    private(set) var isEditing = false

    private let label = NSTextField(labelWithString: "")
    private let field = NSTextField(string: "")
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var isBuiltIn = false

    init() {
        super.init(frame: .zero)

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Spare width goes to the field while renaming and to empty space otherwise, never to the label or a button:
        // with equal priorities Auto Layout picked one at random and the row jumped between openings.
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        field.placeholderString = "Preset name"
        field.delegate = self
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        field.setAccessibilityLabel("Preset name")

        renameButton.toolTip = "Name this preset"
        for button in [renameButton, saveButton, cancelButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.target = self
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        renameButton.action = #selector(renameTapped(_:))
        saveButton.action = #selector(saveTapped(_:))
        cancelButton.action = #selector(cancelTapped(_:))

        let row = NSStackView(views: [label, field, renameButton, saveButton, cancelButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            // The field is the tallest thing this row ever shows, so the row is that tall from the start and
            // Rename, Save and Cancel move nothing around it.
            heightAnchor.constraint(equalToConstant: ceil(field.fittingSize.height)),
        ])
        render()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func set(name: String, isBuiltIn: Bool) {
        self.isBuiltIn = isBuiltIn
        if !isEditing {
            if label.stringValue != name { label.stringValue = name }
            if field.stringValue != name { field.stringValue = name }
        }
        render()
    }

    func beginEditing() {
        isEditing = true
        render()
        // NSTextField.selectText(_:) ends editing for the field first, which would cancel the very rename it starts,
        // so the field editor is asked to select its text instead. The focus waits for the layout pass after the
        // visibility change, which re-inserts the field.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditing else { return }
            self.window?.makeFirstResponder(self.field)
            self.field.currentEditor()?.selectAll(nil)
        }
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        render()
    }

    func keepEditing() {
        window?.makeFirstResponder(field)
    }

    private func render() {
        label.isHidden = isEditing
        field.isHidden = !isEditing
        renameButton.isHidden = isEditing || isBuiltIn
        saveButton.isHidden = !isEditing
        cancelButton.isHidden = !isEditing
    }

    private func commit() {
        guard isEditing else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            onError?("Name cannot be empty")
            keepEditing()
            return
        }
        isEditing = false
        render()
        onCommit?(name)
    }

    @objc private func renameTapped(_ sender: Any?) {
        beginEditing()
    }

    @objc private func saveTapped(_ sender: Any?) {
        commit()
    }

    @objc private func cancelTapped(_ sender: Any?) {
        endEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            return true
        }
        return false
    }

    /// Clicking away leaves edit mode without saving, so a half-typed name is never committed by accident.
    func controlTextDidEndEditing(_ notification: Notification) {
        endEditing()
    }
}
