import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@Suite("Terminal sessions overview rows")
struct TerminalSessionsOverviewTests {
    @Test("pinned records lead and search combines text with state filters")
    func pinSearchAndFilter() {
        let now = Date()
        let records = [
            TerminalSessionRecord(
                directoryPath: "/tmp/archive",
                kind: .shell,
                backend: .ephemeral,
                lastActivityAt: now,
                isPresented: false,
                endedAt: now
            ),
            TerminalSessionRecord(
                directoryPath: "/tmp/client-alpha",
                kind: .codex,
                backend: .ephemeral,
                lastActivityAt: now.addingTimeInterval(-100),
                isPresented: false,
                endedAt: now,
                customName: "Alpha review",
                isPinned: true
            )
        ]

        let rows = TerminalSessionsOverview.rows(
            inApp: [],
            detached: [],
            history: records
        )
        #expect(rows.first?.kindLabel == "Alpha review")
        #expect(rows.first?.isPinned == true)

        let matches = TerminalSessionsOverview.filteredRows(
            rows,
            query: "alpha",
            filter: .history
        )
        #expect(matches.count == 1)
        #expect(matches.first?.folderPath == "/tmp/client-alpha")
        #expect(TerminalSessionsOverview.filteredRows(
            rows,
            query: "alpha",
            filter: .active
        ).isEmpty)
    }

    @Test("confirmed missing tmux records are distinct from ended sessions")
    func missingState() {
        let record = TerminalSessionRecord(
            directoryPath: "/tmp/missing",
            kind: .claude,
            backend: .tmux,
            persistentName: "finderai-claude-aaaaaaaaaaaa",
            isPresented: false,
            endedAt: Date(),
            endReason: .missing
        )

        let rows = TerminalSessionsOverview.rows(
            inApp: [],
            detached: [],
            history: [record]
        )

        #expect(rows.first?.stateLabel == "消失")
    }

    @Test("history follows live rows and does not duplicate a matching live session")
    func historyComposition() {
        let liveID = UUID()
        let oldID = UUID()
        let folder = "/tmp/live"
        let inApp: [TerminalSessionsOverview.InAppSummary] = [
            .init(
                id: liveID,
                kind: .shell,
                kindLabel: "Shell",
                folderPath: folder,
                isRunning: true,
                isPresented: true,
                persistentName: nil
            )
        ]
        let now = Date()
        let history = [
            TerminalSessionRecord(
                id: UUID(),
                directoryPath: folder,
                kind: .shell,
                backend: .ephemeral,
                lastActivityAt: now
            ),
            TerminalSessionRecord(
                id: oldID,
                directoryPath: "/tmp/old",
                kind: .codex,
                backend: .ephemeral,
                lastActivityAt: now.addingTimeInterval(-10),
                isPresented: false,
                endedAt: now
            )
        ]

        let rows = TerminalSessionsOverview.rows(
            inApp: inApp,
            detached: [],
            history: history
        )

        #expect(rows.count == 2)
        #expect(rows[0].target == .inApp(liveID))
        #expect(rows[1].target == .record(oldID))
        #expect(rows[1].stateLabel == "前回終了")
    }

    @Test("in-app sessions lead, attached persistents are deduped, leftovers sort by path")
    func rowComposition() {
        let attachedName = "finderai-shell-aaaaaaaaaaaa"
        let inApp: [TerminalSessionsOverview.InAppSummary] = [
            .init(
                id: UUID(),
                kindLabel: "Shell",
                folderPath: "/tmp/a",
                isRunning: true,
                isPresented: true,
                persistentName: attachedName
            ),
            .init(
                id: UUID(),
                kindLabel: "Claude",
                folderPath: "/tmp/b",
                isRunning: false,
                isPresented: true,
                persistentName: nil
            ),
            .init(
                id: UUID(),
                kindLabel: "Codex",
                folderPath: "/tmp/hidden",
                isRunning: true,
                isPresented: false,
                persistentName: nil
            )
        ]
        let detached = [
            // アプリ内で接続中の永続セッションはtmux一覧にも載る。二重に出さない。
            TmuxSessionInfo(name: attachedName, workingDirectoryPath: "/tmp/a", isAttached: true),
            TmuxSessionInfo(
                name: "finderai-codex-cccccccccccc",
                workingDirectoryPath: "/tmp/z",
                isAttached: false
            ),
            TmuxSessionInfo(
                name: "finderai-shell-dddddddddddd",
                workingDirectoryPath: "/tmp/c",
                isAttached: true
            )
        ]

        let rows = TerminalSessionsOverview.rows(inApp: inApp, detached: detached)

        #expect(rows.count == 5)
        #expect(rows[0].stateLabel == "表示中（永続）")
        #expect(rows[1].stateLabel == "終了")
        #expect(rows[2].stateLabel == "バックグラウンド")
        #expect(rows[3].folderPath == "/tmp/c")
        #expect(rows[3].stateLabel == "接続中（外部）")
        #expect(rows[3].kindLabel == "Shell")
        #expect(rows[3].kind == .shell)
        #expect(rows[4].folderPath == "/tmp/z")
        #expect(rows[4].stateLabel == "待機中（未接続）")
        #expect(rows[4].kindLabel == "Codex")
        #expect(rows[4].kind == .codex)
    }

    @Test("close plans freeze exact IDs instead of mutable row indexes")
    func closePlan() {
        let inAppID = UUID()
        let recordID = UUID()
        let rows = [
            TerminalSessionRowModel(
                target: .inApp(inAppID),
                recordID: nil,
                kind: .codex,
                kindLabel: "Codex",
                folderPath: "/tmp/a",
                stateLabel: "表示中",
                category: .active,
                lastActivityAt: nil,
                isPinned: false
            ),
            TerminalSessionRowModel(
                target: .detachedTmux("finderai-shell-aaaaaaaaaaaa"),
                recordID: nil,
                kind: .shell,
                kindLabel: "Shell",
                folderPath: "/tmp/b",
                stateLabel: "待機中（未接続）",
                category: .recoverable,
                lastActivityAt: nil,
                isPinned: false
            ),
            TerminalSessionRowModel(
                target: .record(recordID),
                recordID: recordID,
                kind: .claude,
                kindLabel: "Claude",
                folderPath: "/tmp/c",
                stateLabel: "前回終了",
                category: .history,
                lastActivityAt: nil,
                isPinned: false
            )
        ]

        let plan = TerminalSessionClosePlan(rows: rows)

        #expect(plan.inAppSessionIDs == [inAppID])
        #expect(plan.detachedTmuxNames == ["finderai-shell-aaaaaaaaaaaa"])
        #expect(plan.recordIDs == [recordID])
        #expect(plan.containsInAppSessions)
        #expect(!plan.containsOnlyRecords)
    }
}
