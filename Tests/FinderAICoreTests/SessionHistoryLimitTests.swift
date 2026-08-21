import Foundation
import Testing
@testable import FinderAICore

@Suite("履歴の本数")
struct SessionHistoryLimitTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// `minutesAgo`が大きいほど古い記録。
    private func record(
        minutesAgo: Int,
        ended: Bool = true,
        pinned: Bool = false
    ) -> TerminalSessionRecord {
        let stamp = epoch.addingTimeInterval(-Double(minutesAgo) * 60)
        return TerminalSessionRecord(
            directoryPath: "/tmp/history-\(minutesAgo)",
            kind: .shell,
            backend: .ephemeral,
            lastActivityAt: stamp,
            isPresented: false,
            endedAt: ended ? stamp : nil,
            endReason: ended ? .processExited : nil,
            isPinned: pinned
        )
    }

    @Test("上限までは何も落とさない")
    func keepsEverythingUnderCapacity() {
        let records = (0..<5).map { record(minutesAgo: $0) }
        #expect(SessionHistoryLimit.pruned(records, capacity: 5) == records)
    }

    @Test("溢れたぶんは古いものから落ちる")
    func dropsTheOldest() {
        let records = (0..<8).map { record(minutesAgo: $0) }
        let pruned = SessionHistoryLimit.pruned(records, capacity: 3)
        #expect(pruned.count == 3)
        // 残るのは新しい3本。台帳の並び順は崩さない。
        #expect(pruned.map(\.directoryPath) == [
            "/tmp/history-0",
            "/tmp/history-1",
            "/tmp/history-2"
        ])
    }

    @Test("留めた記録は本数のせいで消えない")
    func pinnedRecordsSurvive() {
        var records = (0..<6).map { record(minutesAgo: $0) }
        records.append(record(minutesAgo: 999, pinned: true))
        let pruned = SessionHistoryLimit.pruned(records, capacity: 2)
        #expect(pruned.contains { $0.isPinned })
        // 留めたぶんは数に入れないので、終わった記録は上限どおり2本残る。
        #expect(pruned.filter { !$0.isPinned }.count == 2)
    }

    @Test("走っているセッションは履歴として数えない")
    func liveSessionsAreNotHistory() {
        var records = (0..<4).map { record(minutesAgo: $0) }
        records.append(contentsOf: (10..<13).map { record(minutesAgo: $0, ended: false) })
        let pruned = SessionHistoryLimit.pruned(records, capacity: 2)
        #expect(pruned.filter { $0.endedAt == nil }.count == 3)
        #expect(pruned.filter { $0.endedAt != nil }.count == 2)
    }
}
