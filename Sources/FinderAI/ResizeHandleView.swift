import AppKit

@MainActor
final class ResizeHandleView: NSView {
    var onDragDelta: ((CGFloat) -> Void)?
    private var previousMouseY: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        previousMouseY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let mouseY = NSEvent.mouseLocation.y
        if let previousMouseY {
            onDragDelta?(mouseY - previousMouseY)
        }
        previousMouseY = mouseY
    }

    override func mouseUp(with event: NSEvent) {
        previousMouseY = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(rect: NSRect(x: bounds.midX - 18, y: bounds.midY, width: 36, height: 1)).fill()
    }
}
