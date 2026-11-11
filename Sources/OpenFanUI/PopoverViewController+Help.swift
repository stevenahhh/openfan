import AppKit

extension PopoverViewController {
    func showHelpBubble() {
        let text = helpText()
        guard !text.isEmpty, let anchor = footer.helpAnchor else { return }
        let viewAnchor = view.convert(anchor, from: nil)
        let size = helpBubble.setText(text)
        let x = min(max(viewAnchor.midX - size.width / 2, 8), max(view.bounds.width - size.width - 8, 8))
        helpBubble.frame = NSRect(x: x, y: viewAnchor.maxY + 8, width: size.width, height: size.height)
        if helpBubble.superview == nil { view.addSubview(helpBubble) }
        helpBubble.isHidden = false
    }

    func helpText() -> String {
        if showingSettings {
            return "The menu bar text is rebuilt from this template. Click a name to insert it; anything else is shown as typed. Leave the field empty to show only the pressure dot."
        }
        return """
            Drag a point to move it. Double-click empty space to add a point. Right-click a point to remove it.
            Built-in presets cannot be changed: duplicate one to make it yours.
            With CPU or GPU as the input, 95 \u{00B0}C or above still forces full speed.
            Where a curve reaches the bottom, the fans go back to macOS (shown as Auto), which stops them on a cool Mac.
            Speeds use the unit of the fan row: click it to switch between a percentage (0 % is the fan's slowest speed, 100 % its fastest) and rpm.
            """
    }
}
