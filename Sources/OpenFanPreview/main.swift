import AppKit
import OpenFanCore
import OpenFanUI

/// Hosts the popover with sample data in a plain window: a preview path that needs neither the canvas, the menu bar
/// item nor the helper, and that the Xcode View Debugger can attach to.
final class PreviewHost: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = previewPopover()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: controller.preferredContentSize.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenFan preview"
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `OpenFanPreview --snapshot <file.png> [--preset <id>] [--dark]` draws the popover offscreen to a PNG and exits: no
/// window, no menu bar item and no screen capture, so a layout can be checked without driving the desktop.
func snapshot(arguments: [String]) -> Int32 {
    guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return 2 }
    let url = URL(fileURLWithPath: arguments[index + 1])
    var preset = "balanced"
    if let p = arguments.firstIndex(of: "--preset"), p + 1 < arguments.count { preset = arguments[p + 1] }
    NSApp.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)

    let controller = previewPopover(active: preset)
    let size = NSSize(width: 380, height: controller.preferredContentSize.height)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = controller
    window.setContentSize(size)
    let view = controller.view
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return 1 }
    do {
        try png.write(to: url)
    } catch {
        FileHandle.standardError.write(Data("OpenFanPreview: \(error)\n".utf8))
        return 1
    }
    print("OpenFanPreview: \(Int(view.bounds.width))x\(Int(view.bounds.height)) preset \(preset) -> \(url.path)")
    return 0
}

let application = NSApplication.shared
if CommandLine.arguments.contains("--snapshot") {
    application.setActivationPolicy(.prohibited)
    exit(snapshot(arguments: CommandLine.arguments))
}
let host = PreviewHost()
application.delegate = host
application.setActivationPolicy(.regular)
application.run()
