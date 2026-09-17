import AppKit

enum TerminalInputRouting {
    static func owns(_ event: NSEvent, view: NSView, isActive: Bool) -> Bool {
        guard isActive, let window = view.window else { return false }
        return window.isKeyWindow && event.window === window && window.firstResponder === view
    }
}
