import AppKit
import OpenFanCore
import OpenFanSMC

final class CurveEditorPanel: NSView {
    var onLibraryChange: (() -> Void)?

    var activeInput: FanControlInput? { draft?.input }

    static func title(for input: FanControlInput) -> String {
        switch input {
        case .max: return "Max (CPU or GPU)"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery (average)"
        case .system: return "System"
        }
    }

    /// How a hold preset names what it holds, inside a sentence.
    static func holdSourceName(for input: FanControlInput) -> String {
        switch input {
        case .max: return "the hottest CPU/GPU"
        case .cpu: return "the CPU"
        case .gpu: return "the GPU"
        case .battery: return "the battery"
        case .system: return "the system temperature"
        }
    }

    private let store: PresetStore
    private let graph = CurveEditorView(frame: .zero)
    private let holdView: HoldTargetView
    private let picker: NSView
    private let nameEditor = PresetNameEditor()
    private let inputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let nameRow = NSStackView()
    private let buttonRow = NSStackView()
    private let stack = NSStackView()

    private var draft: Preset?
    private var deleteArmed = false
    private var lastError: String?
    private var batteryAvailable = true
    private var systemAvailable = true

    init(store: PresetStore, picker: NSView, width: CGFloat) {
        self.store = store
        self.picker = picker
        self.holdView = HoldTargetView(width: width)
        super.init(frame: .zero)
        configure(width: width)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func showActive() {
        lastError = nil
        deleteArmed = false
        nameEditor.endEditing()
        draft = store.library.activePreset
        render()
    }

    /// A desktop Mac has no battery sensor: the Battery input is hidden, unless the preset already follows it, which
    /// then reads no temperature and leaves the fans to macOS.
    func setBatteryAvailable(_ available: Bool) {
        batteryAvailable = available
        refreshInputItems()
    }

    /// A Mac without TVS0 cannot hold the system temperature.
    func setSystemAvailable(_ available: Bool) {
        systemAvailable = available
        refreshInputItems()
    }

    func updateLive(temperature: Float?, speed: FanSpeedFormat, holding: Bool = false) {
        graph.setLive(temperature: temperature, speed: speed)
        holdView.updateLive(temperature: temperature, holding: holding)
    }

    /// A hold never follows the battery (too slow to steer a loop) and needs TVS0 for the system input.
    private func refreshInputItems() {
        let isHold = draft?.isHold ?? false
        let hiddenInputs: [(FanControlInput, Bool)] = [
            (.battery, isHold || (!batteryAvailable && draft?.input != .battery)),
            (.system, isHold && !systemAvailable && draft?.input != .system),
        ]
        for (input, hidden) in hiddenInputs {
            guard let item = inputPopup.item(at: FanControlInput.allCases.firstIndex(of: input) ?? -1) else { continue }
            if item.isHidden != hidden { item.isHidden = hidden }
        }
    }

    func report(_ message: String) {
        lastError = message
        refreshError()
    }

    func addPreset(copying source: Preset?) {
        let preset = store.library.newCustomPreset(copying: source)
        do {
            try store.upsert(preset)
            try store.setActive(preset.id)
        } catch {
            fail("Save failed: \(error.localizedDescription)")
            return
        }
        lastError = nil
        deleteArmed = false
        draft = preset
        render()
        nameEditor.beginEditing()
        onLibraryChange?()
    }

    private func configure(width: CGFloat) {
        graph.onEdit = { [weak self] points in self?.graphEdited(points) }
        graph.onCommit = { [weak self] points in self?.graphCommitted(points) }
        holdView.onTarget = { [weak self] target, committed in self?.targetChanged(target, committed: committed) }

        nameEditor.onCommit = { [weak self] name in self?.commitName(name) }
        nameEditor.onError = { [weak self] message in self?.fail(message) }

        for input in FanControlInput.allCases {
            inputPopup.addItem(withTitle: Self.title(for: input))
        }
        inputPopup.target = self
        inputPopup.action = #selector(inputChanged(_:))
        inputPopup.setContentHuggingPriority(.required, for: .horizontal)
        inputPopup.setAccessibilityLabel("Temperature input")

        duplicateButton.target = self
        duplicateButton.action = #selector(duplicateTapped(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        for button in [duplicateButton, deleteButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
        }

        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.preferredMaxLayoutWidth = width
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.preferredMaxLayoutWidth = width

        nameEditor.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameRow.setViews([nameEditor, inputPopup], in: .leading)
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.alignment = .centerY

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        buttonRow.setViews([duplicateButton, deleteButton, spacer], in: .leading)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        // The graph and the text that replaces it share one slot, so the picker below never moves when the preset changes.
        let graphSlot = NSView()
        for view in [graph, holdView, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            graphSlot.addSubview(view)
        }
        NSLayoutConstraint.activate([
            graphSlot.heightAnchor.constraint(equalToConstant: 200),
            graph.topAnchor.constraint(equalTo: graphSlot.topAnchor),
            graph.bottomAnchor.constraint(equalTo: graphSlot.bottomAnchor),
            graph.leadingAnchor.constraint(equalTo: graphSlot.leadingAnchor),
            graph.trailingAnchor.constraint(equalTo: graphSlot.trailingAnchor),
            holdView.topAnchor.constraint(equalTo: graphSlot.topAnchor),
            holdView.bottomAnchor.constraint(equalTo: graphSlot.bottomAnchor),
            holdView.leadingAnchor.constraint(equalTo: graphSlot.leadingAnchor),
            holdView.trailingAnchor.constraint(equalTo: graphSlot.trailingAnchor),
            placeholder.centerYAnchor.constraint(equalTo: graphSlot.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: graphSlot.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: graphSlot.trailingAnchor),
        ])

        let rows: [NSView] = [graphSlot, picker, nameRow, buttonRow, noteLabel, errorLabel]
        stack.setViews(rows, in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for row in rows {
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func render() {
        guard let draft, !draft.isFullSpeed else {
            showText(draft?.editorNote ?? PresetLibrary.autoNote)
            return
        }
        setTextOnly(false)
        graph.isHidden = draft.isHold
        holdView.isHidden = !draft.isHold
        refreshInputItems()

        let builtIn = draft.isBuiltIn
        if draft.isHold {
            holdView.show(draft)
        } else {
            graph.isEditable = !builtIn
            graph.setPoints(draft.points)
        }
        nameEditor.set(name: draft.name, isBuiltIn: builtIn)
        inputPopup.isEnabled = !builtIn
        inputPopup.toolTip = builtIn ? "Built-in presets keep this setting"
            : (draft.isHold ? "Temperature the hold keeps" : "Temperature the curve follows")
        if let index = FanControlInput.allCases.firstIndex(of: draft.input), inputPopup.indexOfSelectedItem != index {
            inputPopup.selectItem(at: index)
        }
        duplicateButton.title = builtIn ? "Duplicate to Edit" : "Duplicate"
        deleteButton.isHidden = builtIn
        updateDeleteTitle()

        let note = draft.editorNote
        if noteLabel.stringValue != note { noteLabel.stringValue = note }
        noteLabel.isHidden = note.isEmpty
        refreshError()
    }

    private func showText(_ message: String) {
        setTextOnly(true)
        if placeholder.stringValue != message { placeholder.stringValue = message }
        refreshError()
    }

    private func setTextOnly(_ textOnly: Bool) {
        graph.isHidden = textOnly
        holdView.isHidden = true
        placeholder.isHidden = !textOnly
        nameRow.isHidden = textOnly
        buttonRow.isHidden = textOnly
        noteLabel.isHidden = textOnly
    }

    private func updateDeleteTitle() {
        let title = deleteArmed ? "Click again to delete" : "Delete"
        if deleteButton.title != title { deleteButton.title = title }
        deleteButton.contentTintColor = deleteArmed ? .systemRed : nil
    }

    private func refreshError() {
        let message = lastError ?? ""
        if errorLabel.stringValue != message { errorLabel.stringValue = message }
    }

    private func apply(_ preset: Preset) {
        if preset.isHold {
            guard preset.isValid else {
                fail("Invalid hold target")
                return
            }
        } else {
            do {
                try preset.curve.validate()
            } catch {
                fail("Invalid curve: \(error)")
                return
            }
        }
        guard preset != store.library.preset(id: preset.id) else {
            draft = preset
            render()
            return
        }
        do {
            try store.upsert(preset)
        } catch {
            fail("Save failed: \(error.localizedDescription)")
            return
        }
        draft = preset
        lastError = nil
        render()
        onLibraryChange?()
    }

    private func fail(_ message: String) {
        lastError = message
        NSSound.beep()
        refreshError()
        nameEditor.keepEditing()
    }

    private func disarmDelete() {
        guard deleteArmed else { return }
        deleteArmed = false
        updateDeleteTitle()
    }

    private func graphEdited(_ points: [CurvePoint]) {
        guard draft != nil else { return }
        draft?.points = points
        lastError = nil
        disarmDelete()
        refreshError()
    }

    private func graphCommitted(_ points: [CurvePoint]) {
        guard var draft else { return }
        draft.points = points
        apply(draft)
    }

    /// The slider saves (and so re-sends HOLD) only on release, not on every step of a drag.
    private func targetChanged(_ target: Double, committed: Bool) {
        guard var draft, draft.isHold, !draft.isBuiltIn else { return }
        draft.target = target
        disarmDelete()
        if committed {
            apply(draft)
        } else {
            self.draft = draft
        }
    }

    private func commitName(_ name: String) {
        guard var draft else { return }
        draft.name = name
        apply(draft)
    }

    @objc private func inputChanged(_ sender: Any?) {
        let index = inputPopup.indexOfSelectedItem
        guard var draft, FanControlInput.allCases.indices.contains(index) else { return }
        draft.input = FanControlInput.allCases[index]
        if let target = draft.target {
            let range = Preset.holdRange(for: draft.input)
            draft.target = min(max(target, range.lowerBound), range.upperBound)
        }
        disarmDelete()
        apply(draft)
    }

    @objc private func duplicateTapped(_ sender: Any?) {
        addPreset(copying: draft)
    }

    @objc private func deleteTapped(_ sender: Any?) {
        guard let preset = draft, !preset.isBuiltIn else { return }
        guard deleteArmed else {
            deleteArmed = true
            updateDeleteTitle()
            return
        }
        do {
            try store.remove(id: preset.id)
        } catch {
            fail("Delete failed: \(error.localizedDescription)")
            return
        }
        deleteArmed = false
        lastError = nil
        nameEditor.endEditing()
        draft = store.library.activePreset
        render()
        onLibraryChange?()
    }
}
