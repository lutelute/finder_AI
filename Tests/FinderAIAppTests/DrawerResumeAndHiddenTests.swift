import AppKit
import FinderAICore
import Foundation
import Testing

@testable import FinderAIApp

@MainActor
private final class ResumeMockSession: ManagedTerminalSession {
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
private final class ResumeRecordingBuilder: TerminalSessionBuilding {
    private(set) var resumeFlags: [Bool] = []
    private(set) var roles: [String?] = []

    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?,
        resumesConversation: Bool,
        role: String?
    ) throws -> any ManagedTerminalSession {
        resumeFlags.append(resumesConversation)
        roles.append(role)
        return ResumeMockSession(directoryURL: directoryURL, kind: kind)
    }
}

@MainActor
private struct ResumeMockLocator: CommandLocating {
    func locate(command: String) -> URL? {
        command == "tmux" ? nil : URL(fileURLWithPath: "/usr/bin/true")
    }
}

/// 「AIに復帰できない」の残り筋への手当て：tmuxも消えた後は台帳の記録から
/// `--continue`で会話へ戻り、隠れて動いているものはチップで見えるようにする。
@MainActor
struct DrawerResumeAndHiddenTests {
    private let folder = URL(fileURLWithPath: "/private/tmp/drawer-resume-a", isDirectory: true)

    private func makePreferences(_ name: String) -> WorkspacePreferences {
        let suite = "finderai.tests.drawer-resume.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WorkspacePreferences(defaults: defaults)
    }

    private func makeManager(
        builder: ResumeRecordingBuilder = ResumeRecordingBuilder(),
        records: [TerminalSessionRecord] = []
    ) -> TerminalSessionManager {
        TerminalSessionManager(
            builder: builder,
            commandLocator: ResumeMockLocator(),
            registry: InMemorySessionRegistryStore(records: records)
        )
    }

    private func makeDrawer(
        manager: TerminalSessionManager,
        name: String
    ) -> DrawerContentViewController {
        let drawer = DrawerContentViewController(
            sessionManager: manager,
            preferences: makePreferences(name)
        )
        _ = drawer.view
        drawer.setExpanded(true)
        drawer.setDirectory(folder)
        return drawer
    }

    private func buttons(in root: NSView, action: String) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, button.action == Selector((action)) {
                found.append(button)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    @Test("台帳に記録があるフォルダは、その種類・そのフォルダでだけ「続き」がある")
    func resumableComesFromRegistry() {
        let manager = makeManager(records: [
            TerminalSessionRecord(
                directoryPath: folder.path,
                kind: .claude,
                backend: .tmux,
                isPresented: false
            ),
            TerminalSessionRecord(
                directoryPath: folder.path,
                kind: .codex,
                backend: .ephemeral,
                isPresented: false
            )
        ])
        #expect(manager.hasResumableConversation(kind: .claude, directoryURL: folder))
        #expect(manager.hasResumableConversation(kind: .codex, directoryURL: folder))
        #expect(!manager.hasResumableConversation(kind: .shell, directoryURL: folder))
        #expect(!manager.hasResumableConversation(
            kind: .claude,
            directoryURL: URL(fileURLWithPath: "/private/tmp/elsewhere", isDirectory: true)
        ))
    }

    @Test("記録のあるフォルダのボタンは「前回の続き」になり、押すと--continueで起動する")
    func startButtonResumesPriorConversation() throws {
        let builder = ResumeRecordingBuilder()
        let manager = makeManager(builder: builder, records: [
            TerminalSessionRecord(
                directoryPath: folder.path,
                kind: .claude,
                backend: .ephemeral,
                isPresented: false
            )
        ])
        let drawer = makeDrawer(manager: manager, name: #function)

        let starters = buttons(in: drawer.view, action: "startSessionFromButton:")
        let claudeButton = try #require(
            starters.first { $0.title == "Claudeで前回の続き" }
        )
        claudeButton.performClick(nil)
        #expect(builder.resumeFlags == [true])
    }

    @Test("記録の無いフォルダのボタンはただの新規で、resumeを求めない")
    func startButtonStaysFreshWithoutRecord() throws {
        let builder = ResumeRecordingBuilder()
        let manager = makeManager(builder: builder)
        let drawer = makeDrawer(manager: manager, name: #function)

        let starters = buttons(in: drawer.view, action: "startSessionFromButton:")
        let claudeButton = try #require(starters.first { $0.title == "Claude" })
        claudeButton.performClick(nil)
        #expect(builder.resumeFlags == [false])
    }

    @Test("走っているセッションを名指しで改名でき、その名前が引ける")
    func renameSessionRoundTrips() throws {
        let manager = makeManager()
        let session = try manager.create(kind: .claude, directoryURL: folder)
        #expect(manager.customName(for: session) == nil)

        manager.renameSession(session, to: "  査読担当  ")
        #expect(manager.customName(for: session) == "査読担当")

        // 空欄は「名前を外す」。種類名へ戻る。
        manager.renameSession(session, to: "   ")
        #expect(manager.customName(for: session) == nil)
    }

    @Test("役割は台帳に残り、同じフォルダで開き直したAIへ渡る")
    func roleSticksToFolderAndKind() throws {
        let builder = ResumeRecordingBuilder()
        let manager = makeManager(builder: builder)

        let first = try manager.create(kind: .claude, directoryURL: folder)
        // 最初の起動には何も渡らない。まだ役割が決まっていない。
        #expect(builder.roles == [nil])

        manager.setRole(for: first, to: "  査読者として振る舞う  ")
        #expect(manager.role(for: first) == "査読者として振る舞う")

        // 閉じて開き直すと、台帳の役割が次のセッションへ渡る。
        manager.remove(first)
        _ = try manager.create(kind: .claude, directoryURL: folder)
        #expect(builder.roles.last == "査読者として振る舞う")
    }

    @Test("役割を空にすると、次の起動には渡らない")
    func clearingRoleStopsPassingIt() throws {
        let builder = ResumeRecordingBuilder()
        let manager = makeManager(builder: builder)

        let session = try manager.create(kind: .claude, directoryURL: folder)
        manager.setRole(for: session, to: "査読者")
        manager.setRole(for: session, to: "   ")
        #expect(manager.role(for: session) == nil)

        manager.remove(session)
        _ = try manager.create(kind: .claude, directoryURL: folder)
        // `.last`は二重Optionalになるので添字で見る。
        #expect(builder.roles.count == 2)
        #expect(builder.roles[1] == nil)
    }

    @Test("隠れて実行中のセッションは「＋N」チップになり、押すと管理パネルを開く")
    func hiddenRunningSessionsShowChip() throws {
        let manager = makeManager()
        let drawer = makeDrawer(manager: manager, name: #function)
        let session = try manager.create(kind: .claude, directoryURL: folder)
        manager.hideFromTabs(session)

        var managed = 0
        drawer.onManageSessions = { managed += 1 }
        let chip = try #require(
            buttons(in: drawer.view, action: "showHiddenSessions").first
        )
        #expect(chip.title == "＋1")
        chip.performClick(nil)
        #expect(managed == 1)
    }
}
