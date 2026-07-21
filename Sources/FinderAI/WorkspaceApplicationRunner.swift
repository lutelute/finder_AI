import AppKit

@MainActor
public func runFinderAIWorkspace() {
    WorkspaceBuildInfo.captureRunningIdentity()
    guard let instanceLock = SingleInstanceLock(
        identifier: "com.shigenoburyuto.finderai.workspace"
    ) else { return }

    let application = NSApplication.shared
    let delegate = WorkspaceAppDelegate()
    application.delegate = delegate
    withExtendedLifetime(instanceLock) {
        application.run()
    }
}
