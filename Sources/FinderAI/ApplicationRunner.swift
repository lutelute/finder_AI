import AppKit

@MainActor
public func runFinderAI() {
    guard let instanceLock = SingleInstanceLock() else { return }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(instanceLock) {
        application.run()
    }
}
