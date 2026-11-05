import AppKit
import FinderAICore
import Foundation
import Testing

@testable import FinderAIApp

/// 追従（cd）と所属の付け替えまで真似るフェイク。PTYは持たない。
@MainActor
private final class LauncherMockSession: ManagedTerminalSession {
    let id = UUID()
    private(set) var key: TerminalSessionKey
    private(set) var directoryURL: URL
    let kind: TerminalSessionKind
    let contentView = NSView()
    var isRunning = true
    var isAnchored = false
    var persistence: TerminalSessionPersistence?
    var onChange: (() -> Void)?
    /// 送られたcdの行き先。
    private(set) var cdTargets: [URL] = []

    init(directoryURL: URL, kind: TerminalSessionKind, target: String?) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.kind = kind
        key = TerminalSessionKey(directoryURL: directoryURL, kind: kind, target: target)
    }

    func terminate() { isRunning = false }
    func transcriptData() -> Data? { nil }

    func followDirectory(to url: URL) -> Bool {
        guard kind == .shell else { return false }
        cdTargets.append(url.standardizedFileURL)
        return true
    }

    func rebind(to url: URL) {
        directoryURL = url.standardizedFileURL
        key = TerminalSessionKey(directoryURL: directoryURL, kind: kind, target: key.target)
        onChange?()
    }
}

@MainActor
private final class LauncherMockBuilder: TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?,
        resumesConversation: ConversationResume?,
        role: String?
    ) throws -> any ManagedTerminalSession {
        LauncherMockSession(directoryURL: directoryURL, kind: kind, target: nil)
    }

    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        target: String?,
        sshHostOverride: String?,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?,
        resumesConversation: ConversationResume?,
        role: String?
    ) throws -> any ManagedTerminalSession {
        LauncherMockSession(directoryURL: directoryURL, kind: kind, target: target)
    }
}

@MainActor
private struct LauncherMockLocator: CommandLocating {
    func locate(command: String) -> URL? { URL(fileURLWithPath: "/usr/bin/true") }
}

/// 新しいフォルダでは開始の画面（Shell・Codex・Claudeと会話の履歴）が出る。
/// 1.42.0までは、一度でも何かを出すとどのフォルダへ行ってもその端末が居座り、
/// 別のウインドウで何かが起きると無関係なフォルダの端末に入れ替わっていた。
@MainActor
struct DrawerLauncherTests {
    private func makePreferences(_ name: String) -> WorkspacePreferences {
        let suite = "finderai.tests.drawer-launcher.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WorkspacePreferences(defaults: defaults)
    }

    private func makeManager() -> TerminalSessionManager {
        TerminalSessionManager(
            builder: LauncherMockBuilder(),
            commandLocator: LauncherMockLocator(),
            registry: InMemorySessionRegistryStore(records: [])
        )
    }

    private func makeDrawer(
        manager: TerminalSessionManager,
        preferences: WorkspacePreferences,
        directory: URL
    ) -> DrawerContentViewController {
        let drawer = DrawerContentViewController(sessionManager: manager, preferences: preferences)
        _ = drawer.view
        drawer.setExpanded(true)
        drawer.setDirectory(directory)
        return drawer
    }

    private func folder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("drawer-launcher-\(name)", isDirectory: true)
            .standardizedFileURL
    }

    private func rootView(of view: NSView) -> NSView {
        var current = view
        while let superview = current.superview { current = superview }
        return current
    }

    /// このドロワーに中身が載っているセッション。無ければnil。
    private func mounted(
        in drawer: DrawerContentViewController,
        _ manager: TerminalSessionManager
    ) -> (any ManagedTerminalSession)? {
        manager.allSessions.first { rootView(of: $0.contentView) === drawer.view }
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants(of:))
    }

    /// 開始の画面が見えているか（見出しが隠れていないか）。
    private func showsLauncher(_ drawer: DrawerContentViewController) -> Bool {
        descendants(of: drawer.view)
            .compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "このフォルダでTerminalを開始" && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func startButton(
        in drawer: DrawerContentViewController,
        kind: TerminalSessionKind
    ) -> NSButton? {
        let tag = TerminalSessionKind.startable.firstIndex(of: kind)
        return descendants(of: drawer.view)
            .compactMap { $0 as? NSButton }
            .first { $0.action == Selector(("startSessionFromButton:")) && $0.tag == tag }
    }

    private func tabButton(
        in drawer: DrawerContentViewController,
        for session: any ManagedTerminalSession
    ) -> NSButton? {
        descendants(of: drawer.view)
            .compactMap { $0 as? NSButton }
            .first {
                $0.action == Selector(("selectSession:"))
                    && $0.identifier?.rawValue == session.id.uuidString
            }
    }

    @Test("新しいウインドウは、よその場所の端末を出さず開始の画面になる")
    func newWindowShowsLauncherInsteadOfUnrelatedSession() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawerA = makeDrawer(manager: manager, preferences: preferences, directory: folder("a"))
        _ = try manager.create(kind: .shell, directoryURL: folder("a"))
        _ = try manager.create(kind: .claude, directoryURL: folder("a"))
        // Aに出ているのは片方だけで、もう片方はどこにも載っていない。
        // それでも新しいフォルダとは無関係なので、拾ってはいけない。

        let drawerB = makeDrawer(manager: manager, preferences: preferences, directory: folder("new"))
        #expect(mounted(in: drawerB, manager) == nil)
        #expect(showsLauncher(drawerB))
        _ = drawerA
    }

    @Test("開始の画面は、別のウインドウで端末が開いたり書き換わったりしても入れ替わらない")
    func launcherSurvivesActivityInAnotherWindow() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawerA = makeDrawer(manager: manager, preferences: preferences, directory: folder("a"))
        let claude = try manager.create(kind: .claude, directoryURL: folder("a"))
        let drawerB = makeDrawer(manager: manager, preferences: preferences, directory: folder("new"))
        #expect(showsLauncher(drawerB))

        // AでShellを開く——Aの前の中身（Claude）はどこにも載っていない状態になる。
        try #require(startButton(in: drawerA, kind: .shell)).performClick(nil)
        // どこかの端末がタイトルを書き換えた（Claude Codeは作業中ずっと書き換える）。
        claude.onChange?()

        #expect(mounted(in: drawerB, manager) == nil)
        #expect(showsLauncher(drawerB))
        #expect(mounted(in: drawerA, manager)?.kind == .shell)
    }

    @Test("端末の無いフォルダへ移ると開始の画面になり、前の中身はタブに残って、戻れば前へ出る")
    func movingToEmptyFolderShowsLauncherAndKeepsTab() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawer = makeDrawer(manager: manager, preferences: preferences, directory: folder("a"))
        let claude = try manager.create(kind: .claude, directoryURL: folder("a"))
        #expect(mounted(in: drawer, manager)?.id == claude.id)

        drawer.setDirectory(folder("new"))
        #expect(mounted(in: drawer, manager) == nil)
        #expect(showsLauncher(drawer))
        // 下ろしただけで、帯からは消えない。
        #expect(tabButton(in: drawer, for: claude) != nil)

        drawer.setDirectory(folder("a"))
        #expect(mounted(in: drawer, manager)?.id == claude.id)
    }

    @Test("タブで選んだよその場所の中身は、端末の無いフォルダへ移ると下ろす")
    func explicitlySelectedAISessionIsLoweredOnMove() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawer = makeDrawer(manager: manager, preferences: preferences, directory: folder("here"))
        let claude = try manager.create(kind: .claude, directoryURL: folder("a"))
        // よその場所のものは自動では出ない。
        #expect(mounted(in: drawer, manager) == nil)

        try #require(tabButton(in: drawer, for: claude)).performClick(nil)
        #expect(mounted(in: drawer, manager)?.id == claude.id)

        drawer.setDirectory(folder("new"))
        #expect(mounted(in: drawer, manager) == nil)
        #expect(showsLauncher(drawer))
    }

    @Test("自分で開いたShellは、フォルダを移ると付いてきてcdする")
    func userStartedShellFollows() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawer = makeDrawer(manager: manager, preferences: preferences, directory: folder("a"))
        try #require(startButton(in: drawer, kind: .shell)).performClick(nil)
        let shell = try #require(mounted(in: drawer, manager) as? LauncherMockSession)

        drawer.setDirectory(folder("new"))
        #expect(mounted(in: drawer, manager)?.id == shell.id)
        #expect(shell.cdTargets == [folder("new")])
        #expect(shell.directoryURL == folder("new"))

        // 付いてきた先でも、続けて付いてくる。
        drawer.setDirectory(folder("next"))
        #expect(mounted(in: drawer, manager)?.id == shell.id)
        #expect(shell.directoryURL == folder("next"))
    }

    @Test("フォルダに着いて前に出ただけのShellは付いてこない——元の場所に残る")
    func automaticallyShownShellStaysHome() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawer = makeDrawer(manager: manager, preferences: preferences, directory: folder("home"))
        // 復元などで、このフォルダのShellが自動で前に出た。
        let shell = try #require(
            try manager.create(kind: .shell, directoryURL: folder("home")) as? LauncherMockSession
        )
        #expect(mounted(in: drawer, manager)?.id == shell.id)

        drawer.setDirectory(folder("new"))
        #expect(mounted(in: drawer, manager) == nil)
        #expect(showsLauncher(drawer))
        #expect(shell.cdTargets.isEmpty)
        #expect(shell.directoryURL == folder("home"))

        // タブを押して自分で選べば、そこからは付いてくる。
        try #require(tabButton(in: drawer, for: shell)).performClick(nil)
        drawer.setDirectory(folder("next"))
        #expect(mounted(in: drawer, manager)?.id == shell.id)
        #expect(shell.directoryURL == folder("next"))
    }

    @Test("📌のShellは、自分で開いたものでも付いてこない")
    func anchoredShellDoesNotFollow() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawer = makeDrawer(manager: manager, preferences: preferences, directory: folder("a"))
        try #require(startButton(in: drawer, kind: .shell)).performClick(nil)
        let shell = try #require(mounted(in: drawer, manager) as? LauncherMockSession)
        shell.isAnchored = true

        drawer.setDirectory(folder("new"))
        #expect(shell.cdTargets.isEmpty)
        #expect(mounted(in: drawer, manager) == nil)
        #expect(showsLauncher(drawer))
    }

    @Test("sshはどのフォルダにも属さないので、フォルダを移っても下ろさない")
    func serverSessionStaysAcrossFolders() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawer = makeDrawer(manager: manager, preferences: preferences, directory: folder("a"))
        let ssh = try manager.openServerSession(target: "user@example.invalid", routeHost: nil)
        try #require(tabButton(in: drawer, for: ssh)).performClick(nil)
        #expect(mounted(in: drawer, manager)?.id == ssh.id)

        drawer.setDirectory(folder("new"))
        #expect(mounted(in: drawer, manager)?.id == ssh.id)
    }

    @Test("中身を別のウインドウに取られた側は、空の区画ではなく開始の画面に戻る")
    func drawerThatLostItsSessionShowsLauncher() throws {
        let preferences = makePreferences(#function)
        let manager = makeManager()
        let drawerA = makeDrawer(manager: manager, preferences: preferences, directory: folder("a"))
        let claude = try manager.create(kind: .claude, directoryURL: folder("a"))
        let drawerB = makeDrawer(manager: manager, preferences: preferences, directory: folder("b"))
        #expect(mounted(in: drawerA, manager)?.id == claude.id)

        try #require(tabButton(in: drawerB, for: claude)).performClick(nil)
        #expect(mounted(in: drawerB, manager)?.id == claude.id)
        #expect(mounted(in: drawerA, manager) == nil)
        #expect(showsLauncher(drawerA))
    }
}
