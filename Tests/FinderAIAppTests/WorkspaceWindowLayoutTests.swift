import AppKit
import FinderAICore
@testable import FinderAIApp
import Testing

@Suite("Workspace window layout")
@MainActor
struct WorkspaceWindowLayoutTests {
    /// Each controller gets a throwaway defaults suite. Sharing `UserDefaults
    /// .standard` would let `toggleTerminal()` below rewrite the developer's real
    /// preferences and make these expectations depend on run order.
    static func isolatedPreferences() -> WorkspacePreferences {
        let suite = UserDefaults(suiteName: "finderai.layout.\(UUID().uuidString)")
        return WorkspacePreferences(defaults: suite ?? .standard)
    }

    @Test("workspace opens at a useful desktop size with one embedded terminal")
    func initialSizeAndTerminal() {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
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
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
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

    /// A terminal tall enough to squeeze the file list used to just clip it: the
    /// status bar and last rows went out of view with nothing to stop them.
    @Test("terminal height yields to the file list's minimum")
    func terminalCannotEatTheFileList() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
        )
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()

        let contentHeight = try #require(window.contentView?.bounds.height)
        let ceiling = contentHeight - WorkspaceWindowController.minimumBrowserHeight

        // Asking for more than fits is capped, not honoured.
        #expect(controller.clampedTerminalHeight(5_000) <= ceiling)
        #expect(controller.clampedTerminalHeight(5_000) <= 600)
        // A reasonable request is untouched.
        #expect(controller.clampedTerminalHeight(300) == 300)
        // Below the floor is raised, never negative.
        #expect(controller.clampedTerminalHeight(10) == 160)
        #expect(controller.clampedTerminalHeight(-500) == 160)
    }

    @Test("a window too short for both still returns a usable height")
    func shortWindowDoesNotProduceNonsense() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
        )
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 820, height: 260))
        window.contentView?.layoutSubtreeIfNeeded()

        // 260 - 220 leaves less than the 160 floor; the result must still be the
        // floor rather than a negative or zero height.
        #expect(controller.clampedTerminalHeight(300) == 160)
    }

    private func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap(firstSplitView).first
    }
}
