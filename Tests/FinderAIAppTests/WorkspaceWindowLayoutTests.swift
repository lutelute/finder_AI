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
        // Search from the browser, not the window: the window's own split view
        // holds the two panes and would be found first.
        let split = try #require(firstSplitView(in: controller.browser.view))
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

    /// Every window sharing one autosave name would have them overwrite each
    /// other's saved position and reopen stacked.
    @Test("only the frame-restoring window claims the autosave name")
    func onlyOneWindowAutosaves() throws {
        _ = NSApplication.shared
        let restoring = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences(),
            restoresFrame: true
        )
        let cascading = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences(),
            restoresFrame: false
        )
        restoring.show()
        cascading.cascade(from: restoring.cascadeOrigin)

        #expect(restoring.window?.frameAutosaveName == "FinderAIWorkspaceWindow")
        #expect(cascading.window?.frameAutosaveName.isEmpty == true)
        restoring.close()
        cascading.close()
    }

    /// Opening several in a row leaves the key window unchanged between calls, so
    /// deriving each offset from "the window in front" stacked them all on one
    /// spot. The running point is what keeps them apart.
    @Test("each cascaded window lands somewhere new")
    func cascadeWalks() throws {
        _ = NSApplication.shared
        let first = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
        )
        let window = try #require(first.window)
        window.setFrameOrigin(NSPoint(x: 200, y: 200))

        var point = first.cascadeOrigin
        var origins: [NSPoint] = [window.frame.origin]
        var controllers: [WorkspaceWindowController] = [first]

        for _ in 0..<3 {
            let next = WorkspaceWindowController(
                sessionManager: TerminalSessionManager(),
                initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
                preferences: Self.isolatedPreferences(),
                restoresFrame: false
            )
            point = next.cascade(from: point)
            origins.append(try #require(next.window).frame.origin)
            controllers.append(next)
        }

        let distinct = Set(origins.map { "\($0.x),\($0.y)" })
        #expect(distinct.count == origins.count)
        controllers.forEach { $0.close() }
    }

    @Test("closing a window reports itself so the coordinator can release it")
    func closeIsReported() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
        )
        var closed = false
        controller.onClose = { closed = true }
        controller.showWindow(nil)
        controller.close()

        #expect(closed)
    }

    @Test("splitting adds a second pane on the same folder, and closing it returns focus")
    func splitTogglesPanes() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
        )
        _ = controller.window?.contentView
        let left = controller.browser

        #expect(!controller.isSplit)
        controller.toggleSplit()
        #expect(controller.isSplit)
        // The second pane opens where you already are; you then navigate one side
        // away. `browser` still points at the pane commands will hit.
        #expect(controller.browser.currentDirectory == left.currentDirectory)

        controller.toggleSplit()
        #expect(!controller.isSplit)
        // A closed pane must not keep receiving commands.
        #expect(controller.browser === left)
        controller.close()
    }

    /// A pane is about half a window wide. The sidebar's 160pt minimum only binds
    /// a drag, so the initial layout squeezed it into an unreadable strip of
    /// truncated labels — neither pane keeps one while split, and the left pane
    /// gets its sidebar back when the split closes.
    @Test("no sidebars while split, and the left one returns after")
    func sidebarsFoldAwayWhileSplit() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
        )
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        let split = controller.paneSplitViewForTesting

        // Unsplit: sidebar plus file area.
        #expect(try #require(firstSplitView(in: split.arrangedSubviews[0])).arrangedSubviews.count == 2)

        controller.toggleSplit()
        split.layoutSubtreeIfNeeded()
        #expect(try #require(firstSplitView(in: split.arrangedSubviews[0])).arrangedSubviews.count == 1)
        #expect(try #require(firstSplitView(in: split.arrangedSubviews[1])).arrangedSubviews.count == 1)

        controller.toggleSplit()
        split.layoutSubtreeIfNeeded()
        #expect(try #require(firstSplitView(in: split.arrangedSubviews[0])).arrangedSubviews.count == 2)
        controller.close()
    }

    @Test("a pane cannot be squeezed to an unreadable strip")
    func paneWidthIsBounded() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(
            sessionManager: TerminalSessionManager(),
            initialDirectory: FileManager.default.homeDirectoryForCurrentUser,
            preferences: Self.isolatedPreferences()
        )
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1180, height: 760))
        controller.toggleSplit()
        window.contentView?.layoutSubtreeIfNeeded()

        let split = controller.paneSplitViewForTesting
        #expect(split.arrangedSubviews.count == 2)

        // Checks what a drag actually produces rather than
        // minPossiblePositionOfDivider, which reports the unconstrained value for
        // a constraint-based split view even when the delegate clamps the drag.
        let minimum = WorkspaceWindowController.minimumPaneWidth
        split.setPosition(10, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        #expect(split.arrangedSubviews[0].frame.width >= minimum)

        split.setPosition(split.bounds.width - 10, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        // Each pane carries its own sidebar and columns; neither may become a
        // strip too narrow to read.
        #expect(split.arrangedSubviews[1].frame.width >= minimum)
        controller.close()
    }

    /// Searches inside the browser rather than the window: the window now hosts an
    /// outer split view for the two panes, and a depth-first search from the root
    /// finds that one first.
    private func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap(firstSplitView).first
    }
}
