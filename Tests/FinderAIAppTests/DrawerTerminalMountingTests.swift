import AppKit
import FinderAICore
import Foundation
import Testing

@testable import FinderAIApp

@MainActor
private final class DrawerMockSession: ManagedTerminalSession {
    let id = UUID()
    let key: TerminalSessionKey
    let directoryURL: URL
    let kind: TerminalSessionKind
    let contentView = NSView()
    var isRunning = true
    var persistence: TerminalSessionPersistence?
    var onChange: (() -> Void)?

    init(directoryURL: URL, kind: TerminalSessionKind) {
        self.directoryURL = directoryURL
        self.kind = kind
        key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
    }

    func terminate() {
        isRunning = false
    }

    func transcriptData() -> Data? { nil }
}

@MainActor
private final class DrawerMockBuilder: TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?
    ) throws -> any ManagedTerminalSession {
        DrawerMockSession(directoryURL: directoryURL, kind: kind)
    }
}

@MainActor
private struct DrawerMockLocator: CommandLocating {
    func locate(command: String) -> URL? {
        URL(fileURLWithPath: "/usr/bin/true")
    }
}

/// セッションのcontentViewは1つしかない。複数ウインドウのドロワーが同じ
/// セッションを取り合うと、負けた側はタブだけ残して中身が空になり、押しても
/// 何も起きなくなる——その取り合いの規律を検証する。
@MainActor
struct DrawerTerminalMountingTests {
    private func makePreferences(_ name: String) -> WorkspacePreferences {
        let suite = "finderai.tests.drawer-mounting.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WorkspacePreferences(defaults: defaults)
    }

    private func makeDrawer(
        manager: TerminalSessionManager,
        preferences: WorkspacePreferences,
        directory: URL
    ) -> DrawerContentViewController {
        let drawer = DrawerContentViewController(
            sessionManager: manager,
            preferences: preferences
        )
        _ = drawer.view
        drawer.setExpanded(true)
        drawer.setDirectory(directory)
        return drawer
    }

    private func rootView(of view: NSView) -> NSView {
        var current = view
        while let superview = current.superview { current = superview }
        return current
    }

    private func tabButtons(in root: NSView) -> [NSButton] {
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton,
               button.action == Selector(("selectSession:")) {
                buttons.append(button)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return buttons
    }

    @Test("別フォルダの新しいドロワーは、他所に出ている中身を自動では取らない")
    func newDrawerDoesNotStealMountedSession() throws {
        let preferences = makePreferences(#function)
        let manager = TerminalSessionManager(
            builder: DrawerMockBuilder(),
            commandLocator: DrawerMockLocator(),
            registry: InMemorySessionRegistryStore(records: [])
        )
        let folderA = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-a")
        let folderB = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-b")

        let drawerA = makeDrawer(manager: manager, preferences: preferences, directory: folderA)
        let session = try manager.create(kind: .claude, directoryURL: folderA)
        #expect(rootView(of: session.contentView) === drawerA.view)

        let drawerB = makeDrawer(manager: manager, preferences: preferences, directory: folderB)
        #expect(rootView(of: session.contentView) === drawerA.view)
        _ = drawerB
    }

    @Test("タブを押せば、他所に出ている中身でも取り寄せられ、元の側も押せば取り戻せる")
    func clickingTabReclaimsStolenSession() throws {
        let preferences = makePreferences(#function)
        let manager = TerminalSessionManager(
            builder: DrawerMockBuilder(),
            commandLocator: DrawerMockLocator(),
            registry: InMemorySessionRegistryStore(records: [])
        )
        let folderA = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-a")
        let folderB = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-b")

        let drawerA = makeDrawer(manager: manager, preferences: preferences, directory: folderA)
        let session = try manager.create(kind: .claude, directoryURL: folderA)
        let drawerB = makeDrawer(manager: manager, preferences: preferences, directory: folderB)

        // Bのタブを押す＝意思のある取り寄せ。
        try #require(tabButtons(in: drawerB.view).first).performClick(nil)
        #expect(rootView(of: session.contentView) === drawerB.view)

        // Aはまだ「自分に出ている」と記録したまま。押せば実際の所在を見て
        // 取り戻せること（IDの一致だけで早退しないこと）を確かめる。
        try #require(tabButtons(in: drawerA.view).first).performClick(nil)
        #expect(rootView(of: session.contentView) === drawerA.view)
    }

    @Test("畳んだパネルでタブを押すと本体も開く")
    func clickingTabExpandsCollapsedPanel() throws {
        let preferences = makePreferences(#function)
        let manager = TerminalSessionManager(
            builder: DrawerMockBuilder(),
            commandLocator: DrawerMockLocator(),
            registry: InMemorySessionRegistryStore(records: [])
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-a")
        let drawer = makeDrawer(manager: manager, preferences: preferences, directory: folder)
        _ = try manager.create(kind: .claude, directoryURL: folder)

        var toggleCount = 0
        drawer.onToggle = { toggleCount += 1 }
        drawer.setExpanded(false)
        try #require(tabButtons(in: drawer.view).first).performClick(nil)
        #expect(toggleCount == 1)
    }
}
