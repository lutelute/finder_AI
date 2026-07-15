import AppKit
import FinderAICore
@testable import FinderAIApp
import Testing

@Suite("Workspace window layout")
@MainActor
struct WorkspaceWindowLayoutTests {
    @Test("workspace opens at a useful desktop size with one embedded terminal")
    func initialSizeAndTerminal() {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser
        )

        #expect(controller.window?.contentView?.frame.width == 1180)
        #expect(controller.window?.contentView?.frame.height == 760)
        #expect(controller.terminalPanelHeight == PanelPlacement.collapsedHeight)
        #expect(!controller.isTerminalExpanded)

        controller.toggleTerminal()
        #expect(controller.isTerminalExpanded)
        #expect(controller.terminalPanelHeight == 300)
    }

    @Test("workspace sidebar can be resized independently inside the same window")
    func resizableSidebar() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let split = try #require(firstSplitView(in: root))
        #expect(split.subviews.count == 2)
        #expect(split.subviews[0].frame.width >= 160)
        #expect(split.subviews[0].frame.width <= 360)
        #expect(split.subviews[1].frame.width >= 600)

        split.setPosition(280, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        #expect(abs(split.subviews[0].frame.width - 280) < 1)
        #expect(abs(split.subviews[1].frame.width - 899) < 2)
    }

    private func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap(firstSplitView).first
    }
}
