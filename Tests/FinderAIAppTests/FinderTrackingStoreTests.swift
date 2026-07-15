import Foundation
import FinderAICore
@testable import FinderAIApp
import Testing

@MainActor
private final class MockFinderTracker: FinderTracking {
    var state: FinderTrackingState = .permissionRequired
    var onStateChange: ((FinderTrackingState) -> Void)?

    private(set) var startPrompts: [Bool] = []
    private(set) var recheckPrompts: [Bool] = []
    private(set) var refreshCount = 0
    private(set) var stopCount = 0

    func start(promptForPermission: Bool) {
        startPrompts.append(promptForPermission)
    }

    func recheckPermission(prompt: Bool) {
        recheckPrompts.append(prompt)
    }

    func refresh() {
        refreshCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ newState: FinderTrackingState) {
        state = newState
        onStateChange?(newState)
    }
}

@Suite("Finder tracking lifecycle without Accessibility")
@MainActor
struct FinderTrackingStoreTests {
    @Test("forwards lifecycle calls and deterministic state changes")
    func lifecycleAndStateForwarding() {
        let tracker = MockFinderTracker()
        let store = FinderTrackingStore(tracker: tracker)
        var observed: [FinderTrackingState] = []
        store.onStateChange = { observed.append($0) }

        store.start(promptForPermission: false)
        #expect(tracker.startPrompts == [false])
        #expect(store.state == .permissionRequired)

        let snapshot = FinderSnapshot(
            axFrame: .init(x: 25, y: 40, width: 900, height: 700),
            folderURL: URL(fileURLWithPath: "/tmp/mock finder folder"),
            isMinimized: false,
            isFullScreen: false
        )
        tracker.emit(.tracking(snapshot))
        tracker.emit(.hidden)
        #expect(observed == [.tracking(snapshot), .hidden])
        #expect(store.state == .hidden)

        store.recheckPermission(prompt: true)
        store.refresh()
        #expect(tracker.recheckPrompts == [true])
        #expect(tracker.refreshCount == 1)

        store.stop()
        #expect(tracker.stopCount == 1)
        #expect(tracker.onStateChange == nil)

        tracker.emit(.noFinderWindow)
        #expect(store.state == .hidden)
    }
}
