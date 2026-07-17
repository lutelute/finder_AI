import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@Suite("Crash detection via the clean-shutdown flag")
@MainActor
struct WorkspaceRestorationStoreTests {
    private func makeStore(_ name: String) -> WorkspaceRestorationStore {
        let suite = "finderai.tests.restoration.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceRestorationStore(defaults: defaults)
    }

    @Test("first launch is never treated as a crash")
    func firstLaunchIsClean() {
        let store = makeStore("first-launch")
        #expect(store.previousRunEndedCleanly)
    }

    @Test("only reaching the termination hook counts as a clean shutdown")
    func dirtyUntilMarkedClean() {
        let store = makeStore("dirty-flow")
        store.beginRun()
        // ここでプロセスが死ねば、次の起動はこの値を見る。
        #expect(!store.previousRunEndedCleanly)
        store.markCleanShutdown()
        #expect(store.previousRunEndedCleanly)
    }

    @Test("snapshot survives the round trip and clears on nil")
    func snapshotRoundTrip() {
        let store = makeStore("snapshot")
        #expect(store.snapshot == nil)

        let snapshot = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/tmp/one", "/tmp/two"],
            sessions: [.init(directoryPath: "/tmp/one", kind: .codex)]
        )
        store.snapshot = snapshot
        #expect(store.snapshot == snapshot)

        store.snapshot = nil
        #expect(store.snapshot == nil)
    }
}
