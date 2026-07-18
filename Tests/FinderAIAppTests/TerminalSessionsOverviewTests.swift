import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@Suite("Terminal sessions overview rows")
struct TerminalSessionsOverviewTests {
    @Test("in-app sessions lead, attached persistents are deduped, leftovers sort by path")
    func rowComposition() {
        let attachedName = "finderai-shell-aaaaaaaaaaaa"
        let inApp: [TerminalSessionsOverview.InAppSummary] = [
            .init(
                id: UUID(),
                kindLabel: "Shell",
                folderPath: "/tmp/a",
                isRunning: true,
                persistentName: attachedName
            ),
            .init(
                id: UUID(),
                kindLabel: "Claude",
                folderPath: "/tmp/b",
                isRunning: false,
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

        #expect(rows.count == 4)
        #expect(rows[0].stateLabel == "実行中（永続）")
        #expect(rows[1].stateLabel == "終了")
        #expect(rows[2].folderPath == "/tmp/c")
        #expect(rows[2].stateLabel == "接続中（外部）")
        #expect(rows[2].kindLabel == "Shell")
        #expect(rows[3].folderPath == "/tmp/z")
        #expect(rows[3].stateLabel == "待機中（未接続）")
        #expect(rows[3].kindLabel == "Codex")
    }
}
