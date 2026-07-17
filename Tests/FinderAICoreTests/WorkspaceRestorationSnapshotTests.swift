import FinderAICore
import Foundation
import Testing

@Suite("Crash-restoration snapshot codec")
struct WorkspaceRestorationSnapshotTests {
    @Test("round-trips windows and sessions")
    func roundTrip() throws {
        let snapshot = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/Users/x/proj", "/Users/x/docs"],
            sessions: [
                .init(directoryPath: "/Users/x/proj", kind: .shell),
                .init(directoryPath: "/Users/x/proj", kind: .claude)
            ]
        )
        let data = try #require(snapshot.encoded())
        let decoded = try #require(WorkspaceRestorationSnapshot.decoded(from: data))
        #expect(decoded == snapshot)
    }

    @Test("corrupt data decodes to nil, not an error")
    func corruptData() {
        #expect(WorkspaceRestorationSnapshot.decoded(from: Data("junk".utf8)) == nil)
        #expect(WorkspaceRestorationSnapshot.decoded(from: Data()) == nil)
    }

    @Test("restore is only offered when it adds something over lastDirectory")
    func worthRestoring() {
        // 1枚・セッション無し＝lastDirectory復元と同じなので提案しない。
        #expect(!WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/a"],
            sessions: []
        ).isWorthRestoring)
        #expect(!WorkspaceRestorationSnapshot(
            windowDirectoryPaths: [],
            sessions: []
        ).isWorthRestoring)
        #expect(WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/a", "/b"],
            sessions: []
        ).isWorthRestoring)
        #expect(WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/a"],
            sessions: [.init(directoryPath: "/a", kind: .shell)]
        ).isWorthRestoring)
    }
}
