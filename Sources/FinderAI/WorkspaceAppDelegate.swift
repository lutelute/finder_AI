import AppKit

@MainActor
final class WorkspaceAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: WorkspaceAppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let coordinator = WorkspaceAppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.prepareForTermination() ?? .terminateNow
    }

    /// Quitting with the last window is right for a single-window app; with ⌘N it
    /// would also mean closing your only open window kills sessions running in the
    /// drawer. `showWorkspace` below reopens a window from the Dock instead.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        coordinator?.showWorkspace()
        return true
    }
}
