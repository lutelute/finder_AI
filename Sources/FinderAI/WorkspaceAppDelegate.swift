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

    /// ここに到達した終了だけが「正常終了」。クラッシュや強制終了は到達せず、
    /// 次回起動時に構成復元の提案対象になる。
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.finalizeTermination()
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
