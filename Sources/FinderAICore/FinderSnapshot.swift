import CoreGraphics
import Foundation

/// A value-only description of the Finder window we are allowed to observe.
/// `axFrame` uses the Accessibility coordinate system (origin at the upper-left
/// of the primary display, positive Y downward).
public struct FinderSnapshot: Equatable, Sendable {
    public let axFrame: CGRect
    public let folderURL: URL
    public let isMinimized: Bool
    public let isFullScreen: Bool

    public init(
        axFrame: CGRect,
        folderURL: URL,
        isMinimized: Bool = false,
        isFullScreen: Bool = false
    ) {
        self.axFrame = axFrame
        self.folderURL = folderURL.standardizedFileURL
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
    }
}

public enum FinderTrackingState: Equatable, Sendable {
    case permissionRequired
    case noFinderWindow
    case hidden
    case tracking(FinderSnapshot)
}
