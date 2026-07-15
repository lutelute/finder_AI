import CoreGraphics
import Foundation

public struct FinderBreadcrumbCandidate: Equatable, Sendable {
    public let url: URL
    public let frame: CGRect

    public init(url: URL, frame: CGRect) {
        self.url = url.standardizedFileURL
        self.frame = frame
    }
}

public enum FinderBreadcrumbURLSelector {
    /// Finder exposes the current folder as the deepest item in a horizontal
    /// AXList of file-URL static text elements on macOS 26. The caller already
    /// scopes candidates to one AXList; this function rejects vertical lists
    /// and chooses the deepest URL, using visual order only as a tie-breaker.
    public static func selectCurrent(
        from candidates: [FinderBreadcrumbCandidate]
    ) -> URL? {
        let fileCandidates = candidates.filter { candidate in
            candidate.url.isFileURL
                && candidate.frame.width > 0
                && candidate.frame.height > 0
        }
        guard !fileCandidates.isEmpty else { return nil }

        if fileCandidates.count > 1 {
            let midYs = fileCandidates.map(\.frame.midY)
            guard let minimumY = midYs.min(),
                  let maximumY = midYs.max(),
                  maximumY - minimumY <= 4 else { return nil }
        }

        return fileCandidates.max { lhs, rhs in
            let lhsDepth = lhs.url.pathComponents.count
            let rhsDepth = rhs.url.pathComponents.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.frame.maxX < rhs.frame.maxX
        }?.url
    }
}
