import AppKit
import FinderAICore

@MainActor
final class FinderDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AccordionPanelController: NSWindowController {
    private let drawerContent: DrawerContentViewController
    private var snapshot: FinderSnapshot?
    private(set) var isExpanded = false
    private var requestedExpandedHeight = PanelPlacement.defaultExpandedHeight

    init(sessionManager: any TerminalSessionManaging) {
        drawerContent = DrawerContentViewController(sessionManager: sessionManager)
        let panel = FinderDrawerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: PanelPlacement.collapsedHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = IntegratedPanelTheme.background
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .ignoresCycle]
        panel.contentViewController = drawerContent
        super.init(window: panel)

        drawerContent.onToggle = { [weak self] in self?.toggle() }
        drawerContent.onResizeDelta = { [weak self] delta in self?.resize(by: delta) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(to snapshot: FinderSnapshot, animated: Bool = false) {
        drawerContent.setDirectory(snapshot.folderURL)
        guard !appearsToBeFullScreen(snapshot.axFrame) else {
            self.snapshot = nil
            window?.orderOut(nil)
            return
        }
        self.snapshot = snapshot
        updateFrame(animated: animated)
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        snapshot = nil
    }

    func toggle() {
        guard snapshot != nil else { return }
        isExpanded.toggle()
        drawerContent.setExpanded(isExpanded)
        updateFrame(animated: true)
        if isExpanded {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    private func resize(by delta: CGFloat) {
        guard isExpanded else { return }
        requestedExpandedHeight = min(
            max(requestedExpandedHeight + delta, PanelPlacement.minimumExpandedHeight),
            PanelPlacement.maximumExpandedHeight
        )
        updateFrame(animated: false)
    }

    private func updateFrame(animated: Bool) {
        guard let snapshot,
              let screen = bestScreen(for: snapshot.axFrame),
              let primary = NSScreen.screens.first,
              let placement = PanelPlacementCalculator.placement(
                finderAXFrame: snapshot.axFrame,
                screen: ScreenGeometry(
                    visibleFrame: screen.visibleFrame,
                    primaryScreenMaxY: primary.frame.maxY
                ),
                isExpanded: isExpanded,
                requestedExpandedHeight: requestedExpandedHeight
              ),
              let panel = window else {
            window?.orderOut(nil)
            return
        }

        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(placement.frame, display: true)
            }
        } else {
            panel.setFrame(placement.frame, display: true)
        }
    }

    private func bestScreen(for finderAXFrame: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let finderAppKitFrame = CGRect(
            x: finderAXFrame.minX,
            y: primary.frame.maxY - finderAXFrame.maxY,
            width: finderAXFrame.width,
            height: finderAXFrame.height
        )
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(finderAppKitFrame).area < rhs.frame.intersection(finderAppKitFrame).area
        }
    }

    private func appearsToBeFullScreen(_ finderAXFrame: CGRect) -> Bool {
        guard let primary = NSScreen.screens.first,
              let screen = bestScreen(for: finderAXFrame) else { return true }
        return PanelPlacementCalculator.isProbablyFullScreen(
            finderAXFrame: finderAXFrame,
            screenFrame: screen.frame,
            primaryScreenMaxY: primary.frame.maxY
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull ? 0 : width * height
    }
}
