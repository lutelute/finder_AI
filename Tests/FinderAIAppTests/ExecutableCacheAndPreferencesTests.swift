import AppKit
import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@MainActor
private final class CountingCommandLocator: CommandLocating {
    private(set) var lookups = 0
    var commands: [String: URL]

    init(commands: [String: URL]) {
        self.commands = commands
    }

    func locate(command: String) -> URL? {
        lookups += 1
        return commands[command]
    }
}

@MainActor
private struct StubSessionBuilder: TerminalSessionBuilding {
    func makeSession(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?,
        resumesConversation: ConversationResume?,
        role: String?
    ) throws -> any ManagedTerminalSession {
        throw SessionCreationError.executableNotFound(kind.displayName)
    }
}

@Suite("Executable lookups are cached across folder changes")
@MainActor
struct ExecutableCacheTests {
    @Test("repeated canStart does not rescan PATH")
    func canStartIsCached() {
        let locator = CountingCommandLocator(
            commands: ["codex": URL(fileURLWithPath: "/mock/bin/codex")]
        )
        let manager = TerminalSessionManager(
            builder: StubSessionBuilder(),
            commandLocator: locator
        )

        // canStart runs on every folder change; ten navigations must not cost ten
        // PATH scans per command.
        for _ in 0..<10 {
            #expect(manager.canStart(.codex))
            #expect(!manager.canStart(.claude))
        }
        #expect(locator.lookups == 2)
    }

    @Test("shell needs no lookup at all")
    func shellSkipsLookup() {
        let locator = CountingCommandLocator(commands: [:])
        let manager = TerminalSessionManager(
            builder: StubSessionBuilder(),
            commandLocator: locator
        )
        #expect(manager.canStart(.shell))
        #expect(locator.lookups == 0)
    }

    @Test("a negative result is dropped when creation fails, so a later install is seen")
    func negativeCacheIsInvalidatedOnFailure() {
        let locator = CountingCommandLocator(commands: [:])
        let manager = TerminalSessionManager(
            builder: StubSessionBuilder(),
            commandLocator: locator
        )
        let folder = URL(fileURLWithPath: "/tmp/cache-test", isDirectory: true)

        #expect(!manager.canStart(.codex))
        #expect(throws: SessionCreationError.self) {
            try manager.create(kind: .codex, directoryURL: folder)
        }

        // The CLI appears after the failed attempt.
        locator.commands["codex"] = URL(fileURLWithPath: "/mock/bin/codex")
        #expect(manager.canStart(.codex))
    }
}

@Suite("Workspace preferences round-trip and clamp")
@MainActor
struct WorkspacePreferencesTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "finderai.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test("defaults are returned when nothing was ever stored")
    func shippedDefaults() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        #expect(preferences.sidebarWidth == 210)
        #expect(preferences.sortColumn == "name")
        #expect(preferences.sortAscending)
        #expect(!preferences.showHiddenFiles)
        #expect(preferences.terminalHeight == 300)
        #expect(preferences.terminalWidth == 420)
        #expect(preferences.terminalEdge == .bottom)
        #expect(!preferences.terminalExpanded)
        #expect(preferences.lastDirectory == nil)
    }

    /// 下と右で覚える寸法は別のキー。行き来しても互いを上書きしない。
    @Test("each edge remembers its own thickness")
    func edgeThicknessesAreIndependent() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        preferences.setTerminalThickness(240, for: .bottom)
        preferences.setTerminalThickness(500, for: .right)

        #expect(preferences.terminalThickness(for: .bottom) == 240)
        #expect(preferences.terminalThickness(for: .right) == 500)

        preferences.terminalEdge = .right
        #expect(preferences.terminalEdge == .right)
    }

    @Test("a stored edge that no longer parses falls back to the bottom")
    func unknownEdgeFallsBack() throws {
        let defaults = try makeDefaults()
        defaults.set("diagonal", forKey: "workspace.terminalEdge")
        #expect(WorkspacePreferences(defaults: defaults).terminalEdge == .bottom)
    }

    @Test("values survive a round-trip")
    func roundTrip() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        preferences.sidebarWidth = 300
        preferences.sortColumn = "modified"
        preferences.sortAscending = false
        preferences.showHiddenFiles = true
        preferences.terminalHeight = 420
        preferences.terminalExpanded = true
        preferences.viewMode = .gallery

        #expect(preferences.sidebarWidth == 300)
        #expect(preferences.sortColumn == "modified")
        #expect(!preferences.sortAscending)
        #expect(preferences.showHiddenFiles)
        #expect(preferences.terminalHeight == 420)
        #expect(preferences.terminalExpanded)
        #expect(preferences.viewMode == .gallery)
    }

    @Test("the legacy column-view boolean migrates when no mode exists")
    func legacyViewModeMigration() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "workspace.columnView")
        let preferences = WorkspacePreferences(defaults: defaults)
        #expect(preferences.viewMode == .column)
        preferences.viewMode = .gallery
        #expect(!preferences.usesColumnView)
    }

    @Test("out-of-range geometry is clamped rather than trusted")
    func clampsStoredGeometry() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        preferences.sidebarWidth = 5_000
        #expect(preferences.sidebarWidth == 360)
        preferences.sidebarWidth = 1
        #expect(preferences.sidebarWidth == 160)
        preferences.terminalHeight = 5_000
        #expect(preferences.terminalHeight == 600)
        preferences.terminalHeight = 1
        #expect(preferences.terminalHeight == 160)
        preferences.terminalWidth = 5_000
        #expect(preferences.terminalWidth == 720)
        preferences.terminalWidth = 1
        #expect(preferences.terminalWidth == 280)
    }

    @Test("last directory resolves back to the same folder")
    func lastDirectoryRoundTrip() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        preferences.lastDirectory = folder
        #expect(preferences.lastDirectory?.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test("新しいウインドウで開くフォルダは往復し、外せば未指定へ戻る")
    func newWindowDirectoryRoundTrip() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        #expect(preferences.newWindowDirectory == nil)

        let folder = URL(fileURLWithPath: "/private/tmp/new-window-default", isDirectory: true)
        preferences.newWindowDirectory = folder
        #expect(preferences.newWindowDirectory == folder.standardizedFileURL)

        preferences.newWindowDirectory = nil
        #expect(preferences.newWindowDirectory == nil)
    }
}
