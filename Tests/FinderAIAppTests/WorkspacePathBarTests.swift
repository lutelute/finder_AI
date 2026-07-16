import AppKit
@testable import FinderAIApp
import Testing

/// The address-bar split: a click on a crumb navigates, a click on the trailing
/// empty area opens the editor.
///
/// The split must come from the component cells' real frames. `NSPathControl`
/// maps trailing-area clicks onto the *last* component, so both earlier
/// approaches — a gesture recognizer, then a did-the-action-fire flag — either
/// raced the control or classified every empty click as a crumb click, and the
/// editor never opened.
@Suite("Path bar tells crumbs from empty area")
@MainActor
struct WorkspacePathBarTests {
    private func makeBar(crumbs: [String]) -> WorkspacePathBar {
        let bar = WorkspacePathBar()
        bar.pathItems = crumbs.map { title in
            let item = NSPathControlItem()
            item.title = title
            return item
        }
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: 22)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    @Test("a point on the first crumb is a crumb")
    func firstCrumbHit() {
        let bar = makeBar(crumbs: ["Macintosh HD", "Users", "someone"])
        // The first crumb starts at the leading edge; a few points in is safely
        // inside it.
        #expect(bar.isOnCrumb(NSPoint(x: 12, y: 11)))
    }

    @Test("a point in the trailing empty area is not a crumb")
    func trailingAreaMiss() {
        let bar = makeBar(crumbs: ["Macintosh HD", "Users"])
        // Two short crumbs occupy nowhere near 790pt; the far right is empty.
        #expect(!bar.isOnCrumb(NSPoint(x: 790, y: 11)))
    }

    @Test("with no crumbs at all, everywhere is empty area")
    func emptyBar() {
        let bar = makeBar(crumbs: [])
        #expect(!bar.isOnCrumb(NSPoint(x: 10, y: 11)))
    }

    /// The full wiring: a synthetic mouseDown in the trailing area must invoke
    /// the editor callback, and one on a crumb must not.
    @Test("mouseDown routes by area")
    func mouseDownRouting() {
        let bar = makeBar(crumbs: ["Macintosh HD", "Users"])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 22),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // A programmatic NSWindow defaults to isReleasedWhenClosed = true; under
        // ARC that is a double release and close() segfaulted the test run.
        window.isReleasedWhenClosed = false
        window.contentView = bar

        var editorOpened = 0
        bar.onEmptyAreaClick = { editorOpened += 1 }

        func mouseDown(at x: CGFloat) {
            guard let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: x, y: 11),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { return }
            bar.mouseDown(with: event)
        }

        mouseDown(at: 790)   // trailing empty area
        #expect(editorOpened == 1)
        // A crumb click goes to the control's own tracking, not the editor. The
        // tracking loop needs a real mouse-up, so only the callback count is
        // asserted here.
        window.close()
    }
}
