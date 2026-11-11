import AppKit
import OpenFanCore
import OpenFanSMC

public struct LiveSnapshot {
    public var reading: SensorReading?
    public var fans: [FanInfo]
    public var pressure: MemoryPressure?
    public var helperInstalled: Bool
    /// The installed helper differs from the one this app carries.
    public var helperOutdated: Bool
    public var helperConnected: Bool
    public var helperStatus: HelperStatus?
    public var helperError: String?
    /// False on a desktop Mac: the battery column and the battery curve input are hidden.
    public var hasBattery: Bool
    /// TVS0 exists: system holds are offered.
    public var hasSystem: Bool
    /// An M3/M4 force-test Mac: hold presets stay hidden until hold is verified there.
    public var hasForceTest: Bool
    /// The helper keeps running Auto although a preset is selected, and sending it again has not helped yet.
    public var controlLost: Bool
    /// What the footer offers about a newer release; nil shows nothing.
    public var update: UpdateOffer?

    public init(
        reading: SensorReading?,
        fans: [FanInfo],
        pressure: MemoryPressure?,
        helperInstalled: Bool,
        helperOutdated: Bool = false,
        helperConnected: Bool,
        helperStatus: HelperStatus?,
        helperError: String?,
        hasBattery: Bool = true,
        hasSystem: Bool = false,
        hasForceTest: Bool = false,
        controlLost: Bool = false,
        update: UpdateOffer? = nil
    ) {
        self.reading = reading
        self.fans = fans
        self.pressure = pressure
        self.helperInstalled = helperInstalled
        self.helperOutdated = helperOutdated
        self.helperConnected = helperConnected
        self.helperStatus = helperStatus
        self.helperError = helperError
        self.hasBattery = hasBattery
        self.hasSystem = hasSystem
        self.hasForceTest = hasForceTest
        self.controlLost = controlLost
        self.update = update
    }
}

public struct PopoverActions {
    public var presetsChanged: () -> Void
    public var settingsChanged: () -> Void
    public var installHelper: () -> Void
    public var uninstallHelper: () -> Void
    public var quit: () -> Void
    public var installUpdate: () -> Void = {}

    public init(
        presetsChanged: @escaping () -> Void,
        settingsChanged: @escaping () -> Void,
        installHelper: @escaping () -> Void,
        uninstallHelper: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.presetsChanged = presetsChanged
        self.settingsChanged = settingsChanged
        self.installHelper = installHelper
        self.uninstallHelper = uninstallHelper
        self.quit = quit
    }
}

public final class PopoverViewController: NSViewController {
    private enum Layout {
        static let width: CGFloat = 380
        static let margin: CGFloat = 16
        static let inner: CGFloat = width - margin * 2
        /// Long enough to read as a change, short enough not to be waited for.
        static let transition: TimeInterval = 0.18
    }

    /// Called with the content size the popover should take. A shown NSPopover follows `contentSize`, not
    /// `preferredContentSize`, so whoever owns the popover applies it.
    public var onPreferredSizeChange: ((NSSize) -> Void)?

    private let store: PresetStore
    private let settings: SettingsStore
    private let actions: PopoverActions
    private let header = TelemetryHeaderView()
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let slider: PresetSliderView
    private let editor: CurveEditorPanel
    /// Built the first time the settings page is shown: most openings never visit it, and its buttons took a fifth
    /// of the time the popover needs to appear.
    private var settingsPanel: SettingsPanel?
    private let pages = NSView()
    let footer = PopoverFooter(width: Layout.inner)
    let helpBubble = HelpBubbleView()
    private var snapshot: LiveSnapshot?
    private var visibility = (hasSystem: false, hasForceTest: false)
    /// The preset row is filled by the first update, which knows the Mac's sensors: filling it while the view loads
    /// built every chip twice on a Mac that has the system sensor.
    private var presetRowLoaded = false

    /// The library as the preset row shows it: hold presets this Mac cannot run are left out, the stored file is not.
    private var visibleLibrary: PresetLibrary {
        var library = store.library
        library.presets = library.visiblePresets(hasSystem: visibility.hasSystem, hasForceTest: visibility.hasForceTest)
        return library
    }
    private(set) var showingSettings = false

    public init(store: PresetStore, settings: SettingsStore, actions: PopoverActions) {
        self.store = store
        self.settings = settings
        self.actions = actions
        let slider = PresetSliderView(width: Layout.inner)
        self.slider = slider
        self.editor = CurveEditorPanel(store: store, picker: slider, width: Layout.inner)
        super.init(nibName: nil, bundle: nil)
        header.setShowsRPM(settings.settings.fanUnitsRPM, notify: false)
        header.onUnitsChanged = { [weak self] showsRPM in
            guard let self else { return }
            self.settings.setFanUnitsRPM(showsRPM)
            self.saveSettings()
            self.refreshHeader()
        }
    }

    public required init?(coder: NSCoder) {
        return nil
    }

    public override func loadView() {
        slider.onSelect = { [weak self] id in self?.select(id) }
        slider.onNew = { [weak self] in
            guard let self else { return }
            self.editor.addPreset(copying: self.store.library.activePreset)
        }
        editor.onLibraryChange = { [weak self] in self?.libraryChanged() }
        editor.setGradual(settings.settings.gradualCooldown)
        editor.onGradualChange = { [weak self] gradual in
            guard let self else { return }
            self.settings.setGradualCooldown(gradual)
            self.saveSettings()
        }
        footer.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        footer.onUpdate = { [weak self] in self?.actions.installUpdate() }
        footer.onHelpChange = { [weak self] shown in
            if shown {
                self?.showHelpBubble()
            } else {
                self?.helpBubble.isHidden = true
            }
        }
        helpBubble.isHidden = true

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.preferredMaxLayoutWidth = Layout.inner
        warningLabel.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator

        // Both pages share one slot as tall as the editor, the taller of the two, so turning the page fades one into
        // the other and the popover keeps its size.
        addPage(editor)
        editor.bottomAnchor.constraint(equalTo: pages.bottomAnchor).isActive = true

        let sections: [NSView] = [header, warningLabel, pages, separator, footer]
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(8, after: warningLabel)
        stack.edgeInsets = NSEdgeInsets(top: Layout.margin, left: Layout.margin, bottom: 12, right: Layout.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.widthAnchor.constraint(equalToConstant: Layout.inner).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Layout.width).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        editor.showActive()
        resize()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        footer.dismissHelp()
    }

    public func update(_ snapshot: LiveSnapshot) {
        guard isViewLoaded else { return }
        self.snapshot = snapshot

        let warning = warning(for: snapshot)
        let text = warning ?? ""
        let warningChanged = warningLabel.stringValue != text
        if warningChanged { setWarning(text) }

        var readout = HeaderReadout(reading: snapshot.reading, fans: snapshot.fans)
        readout.hasBattery = snapshot.hasBattery
        header.update(readout)
        editor.setBatteryAvailable(snapshot.hasBattery)
        editor.setSystemAvailable(snapshot.hasSystem)
        editor.setGradualAvailable(!snapshot.helperOutdated)
        if !presetRowLoaded || (snapshot.hasSystem, snapshot.hasForceTest) != (visibility.hasSystem, visibility.hasForceTest) {
            presetRowLoaded = true
            visibility = (snapshot.hasSystem, snapshot.hasForceTest)
            slider.reload(library: visibleLibrary)
        }
        footer.update(pressure: snapshot.pressure)
        footer.update(offer: snapshot.update)

        if showingSettings {
            settingsPanel?.update(values: MenuBarValues(reading: snapshot.reading, presetName: store.library.activePreset?.name ?? "Auto"))
        }

        let temperature = editor.activeInput.flatMap { snapshot.reading?.input($0) }
        editor.updateLive(temperature: temperature, speed: FanSpeedFormat(fan: snapshot.fans.first, showsRPM: header.showsRPM),
                          fanPercent: Self.fanPercent(snapshot),
                          rampPercent: snapshot.helperStatus?.mode == .curve ? snapshot.helperStatus?.rampPercent : nil)
    }

    private func addPage(_ page: NSView) {
        page.translatesAutoresizingMaskIntoConstraints = false
        pages.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pages.topAnchor),
            page.leadingAnchor.constraint(equalTo: pages.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
        ])
    }

    private func settingsPage() -> SettingsPanel {
        if let settingsPanel { return settingsPanel }
        let panel = SettingsPanel(settings: settings, width: Layout.inner)
        panel.onChange = { [weak self] in self?.actions.settingsChanged() }
        addPage(panel)
        panel.bottomAnchor.constraint(lessThanOrEqualTo: pages.bottomAnchor).isActive = true
        settingsPanel = panel
        return panel
    }

    /// A warning is the one thing that still changes the popover's height, so it slides in and out with the resize
    /// instead of snapping. Before the popover is on screen there is nothing to animate.
    private func setWarning(_ text: String) {
        let change = { [self] in
            warningLabel.stringValue = text
            warningLabel.isHidden = text.isEmpty
            resize()
        }
        guard view.window != nil else { return change() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.transition
            context.allowsImplicitAnimation = true
            change()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func resize() {
        guard let stack = view.subviews.first as? NSStackView else { return }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        guard abs(size.height - preferredContentSize.height) > 1 else { return }
        view.frame.size = size
        preferredContentSize = size
        onPreferredSizeChange?(size)
    }

    private func refreshHeader() {
        if let snapshot { update(snapshot) }
    }

    private func saveSettings() {
        do {
            try settings.save()
            actions.settingsChanged()
        } catch {
            editor.report("Not saved: \(error.localizedDescription)")
        }
    }

    private func select(_ id: String) {
        do {
            try store.setActive(id)
        } catch {
            editor.report("Save failed: \(error.localizedDescription)")
        }
        editor.showActive()
        slider.reload(library: visibleLibrary)
        actions.presetsChanged()
        forgetDescent()
        refreshHeader()
        resize()
    }

    private func libraryChanged() {
        slider.reload(library: visibleLibrary)
        resize()
        actions.presetsChanged()
        forgetDescent()
        refreshHeader()
    }

    /// A curve that was just sent starts at its own value, so the descent the last status reported belongs to the
    /// curve before it and must not be drawn on this one until the helper reports again.
    private func forgetDescent() {
        snapshot?.helperStatus?.rampPercent = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(withTitle: version.map { "OpenFan \($0)" } ?? "OpenFan", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let page = menu.addItem(
            withTitle: showingSettings ? "Back to Presets" : "Menu Bar Text\u{2026}",
            action: #selector(pageTapped(_:)),
            keyEquivalent: ""
        )
        page.target = self
        let helper = menu.addItem(
            withTitle: snapshot?.helperInstalled == true ? "Uninstall Helper\u{2026}" : "Install Helper\u{2026}",
            action: #selector(helperTapped(_:)),
            keyEquivalent: ""
        )
        helper.target = self
        if snapshot?.helperOutdated == true {
            let refresh = menu.addItem(withTitle: "Update Helper\u{2026}", action: #selector(updateHelperTapped(_:)), keyEquivalent: "")
            refresh.target = self
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit OpenFan", action: #selector(quitTapped(_:)), keyEquivalent: "q")
        quit.target = self
        return menu
    }

    @objc private func updateHelperTapped(_ sender: Any?) {
        actions.installHelper()
    }

    @objc private func helperTapped(_ sender: Any?) {
        if snapshot?.helperInstalled == true {
            actions.uninstallHelper()
        } else {
            actions.installHelper()
        }
    }

    @objc private func pageTapped(_ sender: Any?) {
        showingSettings.toggle()
        view.window?.makeFirstResponder(nil)
        footer.dismissHelp()
        let settingsPanel = settingsPage()
        let incoming: NSView = showingSettings ? settingsPanel : editor
        let outgoing: NSView = showingSettings ? editor : settingsPanel
        incoming.alphaValue = 0
        incoming.isHidden = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.transition
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The page may have been turned back before the fade ended, so the flag decides, not this closure's pair.
            guard let self else { return }
            self.editor.isHidden = self.showingSettings
            self.settingsPanel?.isHidden = !self.showingSettings
        })
        refreshHeader()
    }

    @objc private func quitTapped(_ sender: Any?) {
        actions.quit()
    }

    /// Fan 0's real speed as a percent of its range; nil while it is stopped (below Mn) or unread.
    private static func fanPercent(_ snapshot: LiveSnapshot) -> Double? {
        guard let fan = snapshot.fans.first, fan.maxRPM > fan.minRPM,
              let rpm = snapshot.reading?.fans.first(where: { $0.index == fan.index })?.rpm, rpm >= fan.minRPM
        else { return nil }
        return min(Double((rpm - fan.minRPM) / (fan.maxRPM - fan.minRPM)) * 100, 100)
    }

    private func warning(for snapshot: LiveSnapshot) -> String? {
        if snapshot.fans.isEmpty && snapshot.reading != nil {
            return "No fan found on this Mac. OpenFan shows temperatures only."
        }
        if !snapshot.helperInstalled {
            return "Helper not installed. Fans stay on Auto until you install it from the menu."
        }
        if snapshot.helperOutdated {
            return "This version has a new helper. Choose Update Helper\u{2026} from the menu."
        }
        if !snapshot.helperConnected {
            return "Helper not responding. Reconnecting\u{2026}"
        }
        if let error = snapshot.helperError, !error.isEmpty {
            return "Helper: \(error)"
        }
        switch snapshot.helperStatus?.mode {
        case .panic?:
            return "Panic: a temperature reached 95 \u{00B0}C, fans at full speed."
        case .monitor?:
            return "Helper stopped controlling the fans (\(snapshot.helperStatus?.error ?? "write failed"))."
        case .hold? where snapshot.helperStatus?.error == HelperStatus.holdPausedReason:
            return "Cruise paused: the system temperature stopped moving. macOS runs the fans until it moves again."
        case .auto? where snapshot.controlLost && store.library.activePreset != nil:
            return "\(store.library.activePreset?.name ?? "The preset") is not running: macOS controls the fans. Retrying\u{2026}"
        default:
            return nil
        }
    }
}
