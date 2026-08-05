import AppKit

@MainActor
final class ResizeHandleView: NSView {
    /// ドラッグでパネルの厚みを変える向き。下辺のパネルは上端を掴んで上下に、
    /// 右辺のパネルは左端を掴んで左右に動かす。
    enum Axis {
        case vertical
        case horizontal
    }

    var axis: Axis = .vertical {
        didSet {
            guard axis != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// パネルが「広がる」向きを正にした差分。軸ごとの符号の違いはここで吸収して
    /// あるので、受け手はどちらの辺でも同じ足し算でよい。
    var onDragDelta: ((CGFloat) -> Void)?
    private var previousLocation: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        previousLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        if let previousLocation {
            // 下辺は上へ引くほど高く、右辺は左へ引くほど広い。
            let delta = axis == .vertical
                ? location.y - previousLocation.y
                : previousLocation.x - location.x
            onDragDelta?(delta)
        }
        previousLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        previousLocation = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        let grip = axis == .vertical
            ? NSRect(x: bounds.midX - 18, y: bounds.midY, width: 36, height: 1)
            : NSRect(x: bounds.midX, y: bounds.midY - 18, width: 1, height: 36)
        NSBezierPath(rect: grip).fill()
    }
}
