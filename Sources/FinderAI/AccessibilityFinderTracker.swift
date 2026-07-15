import AppKit
import ApplicationServices
import FinderAICore
import Foundation

@MainActor
final class AccessibilityFinderTracker: NSObject, FinderTracking {
    private static let finderBundleIdentifier = "com.apple.finder"

    var onStateChange: ((FinderTrackingState) -> Void)?
    private(set) var state: FinderTrackingState = .permissionRequired {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedWindow: AXUIElement?
    private var observedBreadcrumbList: AXUIElement?
    private var observedPID: pid_t?
    private var eventDebounceTimer: Timer?
    private var fallbackTimer: Timer?
    private var permissionRecheckTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false

    func start(promptForPermission: Bool) {
        guard !started else {
            recheckPermission(prompt: promptForPermission)
            return
        }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFrontmostApplicationChange() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureObserverIfNeeded(force: true)
                self?.refresh()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureObserverIfNeeded(force: true)
                self?.refresh()
            }
        })

        recheckPermission(prompt: promptForPermission)
    }

    func stop() {
        eventDebounceTimer?.invalidate()
        eventDebounceTimer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        permissionRecheckTimer?.invalidate()
        permissionRecheckTimer = nil
        tearDownAXObserver()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        started = false
    }

    func recheckPermission(prompt: Bool) {
        // Use the documented key's stable value instead of touching the SDK's
        // imported mutable global, which is not concurrency-annotated.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            enterPermissionRequiredState()
            return
        }

        permissionRecheckTimer?.invalidate()
        permissionRecheckTimer = nil
        configureObserverIfNeeded(force: false)
        if fallbackTimer == nil {
            // Finder does not consistently emit a public notification for a
            // tab's AXDocument change. Two hertz is the bounded fallback; all
            // window movement and focus changes remain event-driven.
            fallbackTimer = Timer.scheduledTimer(
                timeInterval: 0.5,
                target: self,
                selector: #selector(fallbackRefresh),
                userInfo: nil,
                repeats: true
            )
            fallbackTimer?.tolerance = 0.15
        }
        refresh()
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            enterPermissionRequiredState()
            return
        }

        guard shouldTrackFrontmostApplication else {
            state = .hidden
            return
        }

        configureObserverIfNeeded(force: false)
        guard let application = observedApplication,
              let window = copyAXElement(application, attribute: kAXFocusedWindowAttribute) else {
            state = .noFinderWindow
            return
        }

        if observedWindow == nil || !CFEqual(observedWindow, window) {
            observeFocusedWindow(window)
        }

        guard let frame = readFrame(window),
              let folderURL = readDocumentURL(window) else {
            state = .noFinderWindow
            return
        }

        let minimized = readBool(window, attribute: kAXMinimizedAttribute) ?? false
        // Full-screen detection is deliberately handled later using public
        // NSScreen geometry; AX has no public full-screen window attribute.
        let fullScreen = false
        if minimized {
            state = .hidden
            return
        }

        state = .tracking(FinderSnapshot(
            axFrame: frame,
            folderURL: folderURL,
            isMinimized: minimized,
            isFullScreen: fullScreen
        ))
    }

    private var shouldTrackFrontmostApplication: Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        let identifier = frontmost.bundleIdentifier
        return identifier == Self.finderBundleIdentifier || identifier == Bundle.main.bundleIdentifier
    }

    private func handleFrontmostApplicationChange() {
        guard AXIsProcessTrusted() else {
            enterPermissionRequiredState()
            return
        }
        refresh()
    }

    private func enterPermissionRequiredState() {
        eventDebounceTimer?.invalidate()
        eventDebounceTimer = nil
        tearDownAXObserver()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        state = .permissionRequired

        guard permissionRecheckTimer == nil, started else { return }
        // System Settings does not notify an app when its Accessibility slider
        // changes. Recheck without prompting so an already-open onboarding
        // window advances automatically as soon as the user enables access.
        permissionRecheckTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(permissionRecheckTick),
            userInfo: nil,
            repeats: true
        )
        permissionRecheckTimer?.tolerance = 0.2
    }

    @objc private func permissionRecheckTick() {
        recheckPermission(prompt: false)
    }

    private func configureObserverIfNeeded(force: Bool) {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.finderBundleIdentifier
        ).first else {
            tearDownAXObserver()
            state = .noFinderWindow
            return
        }

        if !force, observedPID == finder.processIdentifier, observer != nil {
            return
        }

        tearDownAXObserver()
        let pid = finder.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, Self.axObserverCallback, &newObserver)
        guard result == .success, let newObserver else {
            state = .noFinderWindow
            return
        }

        observer = newObserver
        observedApplication = application
        observedPID = pid
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        addNotification(kAXFocusedWindowChangedNotification, to: application, refcon: refcon)
        addNotification(kAXFocusedUIElementChangedNotification, to: application, refcon: refcon)
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )
    }

    private func observeFocusedWindow(_ window: AXUIElement) {
        if let previous = observedWindow, let observer {
            for notification in Self.windowNotifications {
                AXObserverRemoveNotification(observer, previous, notification as CFString)
            }
        }

        observedWindow = window
        observedBreadcrumbList = nil
        guard observer != nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.windowNotifications {
            addNotification(notification, to: window, refcon: refcon)
        }
    }

    private func addNotification(
        _ notification: String,
        to element: AXUIElement,
        refcon: UnsafeMutableRawPointer
    ) {
        guard let observer else { return }
        let result = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        if result != .success, result != .notificationAlreadyRegistered {
            // A missing optional notification is harmless; the bounded timer
            // still refreshes the snapshot without mutating Finder.
        }
    }

    private func tearDownAXObserver() {
        if let observer {
            if let window = observedWindow {
                for notification in Self.windowNotifications {
                    AXObserverRemoveNotification(observer, window, notification as CFString)
                }
            }
            if let application = observedApplication {
                AXObserverRemoveNotification(observer, application, kAXFocusedWindowChangedNotification as CFString)
                AXObserverRemoveNotification(observer, application, kAXFocusedUIElementChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        observedApplication = nil
        observedWindow = nil
        observedBreadcrumbList = nil
        observedPID = nil
    }

    @objc private func fallbackRefresh() {
        guard shouldTrackFrontmostApplication else {
            if state != .hidden { state = .hidden }
            return
        }
        refresh()
    }

    private func scheduleEventRefresh() {
        // Finder can emit moved/resized/title notifications in bursts. Coalesce
        // each burst so AX reads and panel layout happen once on the main loop.
        eventDebounceTimer?.invalidate()
        eventDebounceTimer = Timer.scheduledTimer(
            timeInterval: 0.04,
            target: self,
            selector: #selector(performDebouncedRefresh),
            userInfo: nil,
            repeats: false
        )
        eventDebounceTimer?.tolerance = 0.01
    }

    @objc private func performDebouncedRefresh() {
        eventDebounceTimer = nil
        refresh()
    }

    private func copyAXElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func readFrame(_ window: AXUIElement) -> CGRect? {
        guard let position = readPoint(window, attribute: kAXPositionAttribute),
              let size = readSize(window, attribute: kAXSizeAttribute),
              size.width > 0,
              size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func readPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        var output = CGPoint.zero
        return AXValueGetValue(rawValue as! AXValue, .cgPoint, &output) ? output : nil
    }

    private func readSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        var output = CGSize.zero
        return AXValueGetValue(rawValue as! AXValue, .cgSize, &output) ? output : nil
    }

    private func readBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func readDocumentURL(_ window: AXUIElement) -> URL? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXDocumentAttribute as CFString,
            &value
        ) == .success,
           let value,
           let directURL = parseFileURL(value) {
            return directURL
        }

        // Finder on macOS 26 advertises AXDocument but returns
        // kAXErrorNoValue. Its public breadcrumb AXList still exposes file
        // URLs through kAXURLAttribute. Cache that list after one bounded
        // discovery so the 0.5s tab fallback does not walk the whole tree.
        if let observedBreadcrumbList,
           let url = readBreadcrumbURL(from: observedBreadcrumbList) {
            return url
        }
        observedBreadcrumbList = nil

        guard let list = findBreadcrumbList(in: window),
              let url = readBreadcrumbURL(from: list) else { return nil }
        observedBreadcrumbList = list
        return url
    }

    private func parseFileURL(_ value: CFTypeRef) -> URL? {
        if CFGetTypeID(value) == CFURLGetTypeID() {
            let url = value as! URL
            return url.isFileURL ? url.standardizedFileURL : nil
        }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return FinderDocumentURLParser.parse(value as! String)
        }
        return nil
    }

    private func readBreadcrumbURL(from list: AXUIElement) -> URL? {
        let children = copyAXElements(list, attribute: kAXChildrenAttribute)
        var candidates: [FinderBreadcrumbCandidate] = []
        candidates.reserveCapacity(children.count)

        for child in children {
            guard readString(child, attribute: kAXRoleAttribute) == kAXStaticTextRole,
                  let value = copyAXValue(child, attribute: kAXURLAttribute),
                  let url = parseFileURL(value),
                  let frame = readFrame(child) else { continue }
            candidates.append(FinderBreadcrumbCandidate(url: url, frame: frame))
        }
        return FinderBreadcrumbURLSelector.selectCurrent(from: candidates)
    }

    private func findBreadcrumbList(in window: AXUIElement) -> AXUIElement? {
        struct Node {
            let element: AXUIElement
            let depth: Int
        }

        var queue = [Node(element: window, depth: 0)]
        var cursor = 0
        var seen = Set<CFHashCode>()
        let maximumElements = 600
        let maximumDepth = 6

        while cursor < queue.count, cursor < maximumElements {
            let node = queue[cursor]
            cursor += 1
            guard seen.insert(CFHash(node.element)).inserted else { continue }

            if readString(node.element, attribute: kAXRoleAttribute) == kAXListRole,
               readBreadcrumbURL(from: node.element) != nil {
                return node.element
            }
            guard node.depth < maximumDepth else { continue }

            var children = copyAXElements(node.element, attribute: kAXChildrenAttribute)
            if children.isEmpty {
                children = copyAXElements(
                    node.element,
                    attribute: "AXChildrenInNavigationOrder"
                )
            }
            queue.append(contentsOf: children.map {
                Node(element: $0, depth: node.depth + 1)
            })
        }
        return nil
    }

    private func copyAXValue(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value
    }

    private func copyAXElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let value = copyAXValue(element, attribute: attribute),
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func readString(_ element: AXUIElement, attribute: String) -> String? {
        guard let value = copyAXValue(element, attribute: attribute),
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private static let windowNotifications: [String] = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification
    ]

    private static let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let tracker = Unmanaged<AccessibilityFinderTracker>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        MainActor.assumeIsolated {
            tracker.scheduleEventRefresh()
        }
    }
}
