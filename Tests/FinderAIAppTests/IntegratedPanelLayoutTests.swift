import AppKit
import FinderAICore
@testable import FinderAIApp
import Testing

@Suite("Integrated Finder panel layout")
@MainActor
struct IntegratedPanelLayoutTests {
    @Test("collapsed content keeps the exact Finder-width 34pt frame")
    func collapsedFrameDoesNotGrowFromHiddenBodyConstraints() {
        _ = NSApplication.shared
        let content = DrawerContentViewController(sessionManager: TerminalSessionManager())
        let panel = FinderDrawerPanel(
            contentRect: NSRect(
                x: 100,
                y: 200,
                width: 920,
                height: PanelPlacement.collapsedHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = content
        content.setExpanded(false)
        panel.setFrame(
            NSRect(x: 100, y: 200, width: 920, height: PanelPlacement.collapsedHeight),
            display: false
        )
        panel.contentView?.layoutSubtreeIfNeeded()

        #expect(panel.frame.minX == 100)
        #expect(panel.frame.width == 920)
        #expect(panel.frame.height == PanelPlacement.collapsedHeight)
    }

    @Test("production panel has no detached-window shadow")
    func panelUsesFlushEdges() {
        let controller = AccordionPanelController(sessionManager: TerminalSessionManager())
        #expect(controller.window?.hasShadow == false)
        #expect(controller.window?.styleMask == [.borderless])
    }
}
