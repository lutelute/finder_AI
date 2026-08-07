import FinderAICore
import Testing

@Suite("動いているAIの数え方と言い方")
struct SessionCountSummaryTests {
    @Test("繋いでいなくても、tmuxで生きているぶんは数える")
    func detachedSessionsAreStillRunning() {
        // アプリを開き直した直後の姿。繋いだ数だけを見ると0になる。
        let summary = SessionCountSummary(attached: 0, detached: 3)
        #expect(summary.total == 3)
        #expect(summary.isIdle == false)
        #expect(summary.badgeText == "3")
        #expect(summary.statusTooltip == "実行中3件（うち3件は未接続）")
    }

    @Test("全部繋がっているときは内訳を言わない")
    func fullyAttachedNeedsNoBreakdown() {
        let summary = SessionCountSummary(attached: 2, detached: 0)
        #expect(summary.badgeText == "2")
        #expect(summary.statusTooltip == "実行中2件")
        #expect(summary.manageTooltip == "Terminalセッションを管理 — 実行中2件（⌘⌥T）")
    }

    @Test("混ざっているときは合計を出し、内訳を添える")
    func mixedShowsTotalAndBreakdown() {
        let summary = SessionCountSummary(attached: 2, detached: 5)
        #expect(summary.total == 7)
        #expect(summary.badgeText == "7")
        #expect(summary.manageTooltip == "Terminalセッションを管理 — 実行中7件（うち5件は未接続）（⌘⌥T）")
    }

    @Test("1つも動いていなければ、帯には何も出さない")
    func idleShowsNothing() {
        let summary = SessionCountSummary(attached: 0, detached: 0)
        #expect(summary.isIdle)
        #expect(summary.badgeText.isEmpty)
        #expect(summary.statusTooltip == "実行中のセッションはありません")
        #expect(summary.manageTooltip == "すべてのTerminalセッションを管理（⌘⌥T）")
    }

    @Test("負の数を渡されても0として扱う")
    func negativeCountsAreClamped() {
        let summary = SessionCountSummary(attached: -1, detached: -2)
        #expect(summary.total == 0)
        #expect(summary.isIdle)
    }
}
