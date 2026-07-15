import CoreGraphics
import Foundation

public struct ScreenGeometry: Equatable, Sendable {
    public let visibleFrame: CGRect
    public let primaryScreenMaxY: CGFloat

    public init(visibleFrame: CGRect, primaryScreenMaxY: CGFloat) {
        self.visibleFrame = visibleFrame
        self.primaryScreenMaxY = primaryScreenMaxY
    }
}

public struct PanelPlacement: Equatable, Sendable {
    public static let collapsedHeight: CGFloat = 34
    public static let minimumExpandedHeight: CGFloat = 160
    public static let defaultExpandedHeight: CGFloat = 280
    public static let maximumExpandedHeight: CGFloat = 600

    public let frame: CGRect
    public let effectiveExpandedHeight: CGFloat

    public init(frame: CGRect, effectiveExpandedHeight: CGFloat) {
        self.frame = frame
        self.effectiveExpandedHeight = effectiveExpandedHeight
    }
}

public enum PanelPlacementCalculator {
    public static func isProbablyFullScreen(
        finderAXFrame: CGRect,
        screenFrame: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> Bool {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return true }
        let appKitFrame = CGRect(
            x: finderAXFrame.minX,
            y: primaryScreenMaxY - finderAXFrame.maxY,
            width: finderAXFrame.width,
            height: finderAXFrame.height
        )
        let intersection = appKitFrame.intersection(screenFrame)
        guard !intersection.isNull else { return true }
        return intersection.width / screenFrame.width > 0.985
            && intersection.height / screenFrame.height > 0.985
    }

    /// Converts the public Accessibility frame into AppKit coordinates and
    /// places the drawer *inside* the Finder window. Finder itself is never
    /// moved or resized.
    public static func placement(
        finderAXFrame: CGRect,
        screen: ScreenGeometry,
        isExpanded: Bool,
        requestedExpandedHeight: CGFloat
    ) -> PanelPlacement? {
        guard finderAXFrame.width > 80, finderAXFrame.height > 80 else {
            return nil
        }

        let finderAppKitFrame = CGRect(
            x: finderAXFrame.minX,
            y: screen.primaryScreenMaxY - finderAXFrame.maxY,
            width: finderAXFrame.width,
            height: finderAXFrame.height
        )

        let usableFinderFrame = finderAppKitFrame.intersection(screen.visibleFrame)
        guard !usableFinderFrame.isNull,
              usableFinderFrame.width > 80,
              usableFinderFrame.height >= PanelPlacement.collapsedHeight else {
            return nil
        }

        // Never advertise an expanded drawer smaller than the documented
        // minimum. If the Finder itself cannot contain 160 pt, fail closed and
        // let the controller keep the overlay out of an invalid position.
        guard !isExpanded || usableFinderFrame.height >= PanelPlacement.minimumExpandedHeight else {
            return nil
        }

        let maximumInsideFinder = max(
            PanelPlacement.minimumExpandedHeight,
            usableFinderFrame.height - 72
        )
        let expandedHeight = min(
            max(requestedExpandedHeight, PanelPlacement.minimumExpandedHeight),
            min(PanelPlacement.maximumExpandedHeight, maximumInsideFinder)
        )
        let height = isExpanded ? expandedHeight : PanelPlacement.collapsedHeight

        return PanelPlacement(
            frame: CGRect(
                x: usableFinderFrame.minX,
                y: usableFinderFrame.minY,
                width: usableFinderFrame.width,
                height: height
            ).integral,
            effectiveExpandedHeight: expandedHeight
        )
    }
}
