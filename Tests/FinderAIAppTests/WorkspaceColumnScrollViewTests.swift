import AppKit
@testable import FinderAIApp
import Testing

@Suite("Column view trackpad routing")
@MainActor
struct WorkspaceColumnScrollViewTests {
    @Test("a horizontal gesture over column content reaches the outer browser")
    func horizontalGestureIsForwarded() throws {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        outer.hasHorizontalScroller = true
        outer.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 120))
        outer.contentView.scroll(to: NSPoint(x: 220, y: 0))
        outer.reflectScrolledClipView(outer.contentView)
        let before = outer.contentView.bounds.origin.x
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 18,
            wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        let scrollView = WorkspaceColumnScrollView()
        var forwardedDeltaX: CGFloat?
        scrollView.onScrollForOuterBrowser = {
            forwardedDeltaX = $0.scrollingDeltaX
            WorkspaceColumnHorizontalScroll.apply($0, to: outer)
        }

        scrollView.scrollWheel(with: event)

        #expect(forwardedDeltaX != nil)
        #expect(abs(forwardedDeltaX ?? 0) > 0)
        #expect(outer.contentView.bounds.origin.x != before)
    }
}
