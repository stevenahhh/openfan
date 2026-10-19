import SwiftUI
import OpenFanCore
import OpenFanSMC

/// A reading that makes every part of the popover show something: two fans at the given rpm, three temperatures.
public func previewSnapshot(temperature: Float = 46.5, rpm: Float = 2900, mode: HelperMode = .curve) -> LiveSnapshot {
    let fans = [
        FanInfo(index: 0, minRPM: 2317, maxRPM: 7826),
        FanInfo(index: 1, minRPM: 2317, maxRPM: 7826),
    ]
    let reading = SensorReading(
        cpu: temperature,
        gpu: temperature - 3,
        battery: 33,
        fans: [
            FanReading(index: 0, rpm: rpm, targetRPM: rpm, manual: true),
            FanReading(index: 1, rpm: rpm - 12, targetRPM: rpm, manual: true),
        ],
        system: 44.6
    )
    return LiveSnapshot(
        reading: reading,
        fans: fans,
        pressure: .normal,
        helperInstalled: true,
        helperConnected: true,
        helperStatus: HelperStatus(mode: mode, inputTemperature: Double(temperature), targetRPM: [rpm, rpm]),
        helperError: nil,
        hasSystem: true
    )
}

/// A popover wired to a throwaway store, for the canvas and the preview host. Nothing it does can reach the real
/// settings or presets, and the helper is not involved. A built-in preset is active by default so the graph, the live
/// readout and the editor buttons are all on screen; `previewHoldID` selects a user's own hold preset.
public let previewHoldID = "custom-hold"

public func previewPopover(active: String = "balanced") -> PopoverViewController {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("openfan-previews", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let store = PresetStore(url: directory.appendingPathComponent("presets.json"))
    try? store.load()
    if store.library.preset(id: previewHoldID) == nil {
        try? store.upsert(Preset(id: previewHoldID, name: "Hold 47 \u{00B0}C", input: .system, points: [], target: 47))
    }
    try? store.setActive(active)

    let controller = PopoverViewController(
        store: store,
        settings: SettingsStore(url: directory.appendingPathComponent("settings.json")),
        actions: PopoverActions(
            presetsChanged: {},
            settingsChanged: {},
            installHelper: {},
            uninstallHelper: {},
            quit: {}
        )
    )
    controller.loadView()
    let hold = store.library.activePreset?.isHold ?? false
    controller.update(previewSnapshot(mode: hold ? .hold : .curve))
    return controller
}

/// Xcode canvas harness. The previews run with the Xcode toolchain, since #Preview expands through macro plugins
/// that do not ship with the Command Line Tools.
private struct PopoverPreview: NSViewControllerRepresentable {
    var temperature: Float = 46.5
    var rpm: Float = 2900

    func makeNSViewController(context: Context) -> PopoverViewController {
        let controller = previewPopover()
        controller.update(previewSnapshot(temperature: temperature, rpm: rpm))
        return controller
    }

    func updateNSViewController(_ controller: PopoverViewController, context: Context) {
        controller.update(previewSnapshot(temperature: temperature, rpm: rpm))
    }
}

#Preview("Popover") {
    PopoverPreview()
        .frame(width: 380)
}

#Preview("Popover - light") {
    PopoverPreview(temperature: 71.5, rpm: 5200)
        .frame(width: 380)
        .preferredColorScheme(.light)
}

#Preview("Popover - dark") {
    PopoverPreview(temperature: 71.5, rpm: 5200)
        .frame(width: 380)
        .preferredColorScheme(.dark)
}
