import AppKit
import SwiftUI

nonisolated enum ExplorerWidth {
    static let minimum: CGFloat = 180
    static let terminalMinimum: CGFloat = 620
    static let divider: CGFloat = 6

    static func clamped(_ proposed: CGFloat, availableWidth: CGFloat) -> CGFloat {
        min(max(minimum, proposed.isFinite ? proposed : 240), max(minimum, availableWidth - terminalMinimum - divider))
    }
}

struct ExplorerResizeDivider: NSViewRepresentable {
    let width: CGFloat
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) {
        view.width = width
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class DividerView: NSView {
        var width: CGFloat = 240
        var onChange: (CGFloat) -> Void = { _ in }
        var onEnd: (CGFloat) -> Void = { _ in }
        private var startX: CGFloat?
        private var startWidth: CGFloat = 240

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill()
        }
        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            startWidth = width
        }
        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onChange(startWidth + event.locationInWindow.x - startX)
        }
        override func mouseUp(with event: NSEvent) {
            guard let startX else { return }
            onEnd(startWidth + event.locationInWindow.x - startX)
            self.startX = nil
        }
    }
}
