import AppKit

/// The "Custom…" input: the only window the app ever shows.
@MainActor
enum CustomPrompt {
    /// Returns the chosen duration, or nil on Cancel. Invalid input shows the prompt again.
    static func ask() -> TimeInterval? {
        // A menu-bar app is not frontmost, so the alert would open behind other windows.
        NSApp.activate(ignoringOtherApps: true)

        let hint = "For example 45, 90m, 2h, 1h30m or 1:30."
        var error: String?
        var text = ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Keep awake for how long?"
            alert.informativeText = [error, hint].compactMap { $0 }.joined(separator: "\n")
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = text
            field.placeholderString = "1h30m"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            text = field.stringValue
            if let duration = DurationParser.parse(text) { return duration }
            error = "Enter a time between 1 minute and 7 days."
        }
    }
}
