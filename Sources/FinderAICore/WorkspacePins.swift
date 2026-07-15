import Foundation

/// The user's own pinned folders — the editable counterpart to Finder's
/// favourites, which are read-only here.
///
/// Order is the user's, so this is an array rather than a set; pinning something
/// already pinned moves nothing, because a pin silently jumping position would be
/// worse than the click doing nothing.
public struct WorkspacePins: Equatable, Sendable {
    private var paths: [String] = []

    /// Deep enough to never be the reason a pin is refused, shallow enough that
    /// the section cannot swallow the sidebar.
    public static let capacity = 30

    public init() {}

    public init(paths: [String]) {
        for path in paths where !self.paths.contains(path) {
            self.paths.append(path)
        }
        if self.paths.count > Self.capacity {
            self.paths = Array(self.paths.prefix(Self.capacity))
        }
    }

    public var urls: [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public var storedPaths: [String] { paths }

    public var isFull: Bool { paths.count >= Self.capacity }

    public func contains(_ url: URL) -> Bool {
        paths.contains(url.standardizedFileURL.path)
    }

    /// Returns false when the pin was refused: already pinned, or at capacity.
    @discardableResult
    public mutating func pin(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !paths.contains(path), paths.count < Self.capacity else { return false }
        paths.append(path)
        return true
    }

    @discardableResult
    public mutating func unpin(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let index = paths.firstIndex(of: path) else { return false }
        paths.remove(at: index)
        return true
    }

    public mutating func toggle(_ url: URL) {
        if contains(url) {
            unpin(url)
        } else {
            pin(url)
        }
    }

    /// Moves the pin at `index` so it lands before `destination`, matching
    /// `NSTableView`'s drop semantics where the destination is the gap between
    /// rows and therefore shifts once the source is lifted out.
    public mutating func move(from index: Int, to destination: Int) {
        guard paths.indices.contains(index),
              destination >= 0, destination <= paths.count else { return }
        let path = paths.remove(at: index)
        let adjusted = destination > index ? destination - 1 : destination
        paths.insert(path, at: min(adjusted, paths.count))
    }
}
