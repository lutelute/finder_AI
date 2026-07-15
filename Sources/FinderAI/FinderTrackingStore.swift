import FinderAICore

/// Small state boundary between AX-backed tracking and the UI. Keeping this
/// independent of Accessibility lets all lifecycle behavior be tested with a
/// deterministic tracker and no system permission.
@MainActor
final class FinderTrackingStore {
    var onStateChange: ((FinderTrackingState) -> Void)?
    private(set) var state: FinderTrackingState = .permissionRequired

    private let tracker: FinderTracking

    init(tracker: FinderTracking) {
        self.tracker = tracker
    }

    func start(promptForPermission: Bool) {
        tracker.onStateChange = { [weak self] state in
            self?.accept(state)
        }
        tracker.start(promptForPermission: promptForPermission)
        accept(tracker.state)
    }

    func recheckPermission(prompt: Bool) {
        tracker.recheckPermission(prompt: prompt)
        accept(tracker.state)
    }

    func refresh() {
        tracker.refresh()
        accept(tracker.state)
    }

    func stop() {
        tracker.stop()
        tracker.onStateChange = nil
    }

    private func accept(_ newState: FinderTrackingState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}
