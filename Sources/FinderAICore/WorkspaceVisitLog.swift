import Foundation

/// Tracks which folders get opened, so the sidebar can offer "frequent" and
/// "recent" without the user curating anything.
///
/// Pure value type: the caller owns persistence and supplies the clock, so the
/// ranking is testable without touching `UserDefaults` or waiting for real time
/// to pass.
public struct WorkspaceVisitLog: Equatable, Sendable {
    public struct Visit: Equatable, Sendable, Codable {
        public let path: String
        public var count: Int
        public var lastVisited: Date

        public init(path: String, count: Int, lastVisited: Date) {
            self.path = path
            self.count = count
            self.lastVisited = lastVisited
        }
    }

    /// Keyed by path so a folder cannot appear twice under different URL spellings.
    private var visits: [String: Visit] = [:]

    /// Old paths are only pruned on write, so a log that stops being written stops
    /// growing on its own. This bound keeps that from mattering.
    public static let capacity = 200

    public init() {}

    public init(visits: [Visit]) {
        for visit in visits { self.visits[visit.path] = visit }
        pruneIfNeeded()
    }

    public var all: [Visit] { Array(visits.values) }

    public mutating func record(_ url: URL, now: Date) {
        let path = url.standardizedFileURL.path
        if var existing = visits[path] {
            existing.count += 1
            existing.lastVisited = now
            visits[path] = existing
        } else {
            visits[path] = Visit(path: path, count: 1, lastVisited: now)
        }
        pruneIfNeeded()
    }

    public mutating func forget(_ url: URL) {
        visits.removeValue(forKey: url.standardizedFileURL.path)
    }

    /// Most-opened first.
    ///
    /// A folder seen once is excluded: a single visit says nothing about habit,
    /// and letting it in means the section churns with every stray folder opened.
    /// Ties break on recency so the list still reorders as habits move.
    public func frequent(limit: Int, excluding excluded: Set<String> = []) -> [URL] {
        visits.values
            .filter { $0.count > 1 && !excluded.contains($0.path) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lastVisited > rhs.lastVisited
            }
            .prefix(limit)
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// Most-recent first.
    public func recent(limit: Int, excluding excluded: Set<String> = []) -> [URL] {
        visits.values
            .filter { !excluded.contains($0.path) }
            .sorted { $0.lastVisited > $1.lastVisited }
            .prefix(limit)
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// Drops the least useful entries once over capacity: fewest visits first,
    /// oldest breaking ties, so a rarely-used folder goes before a habit.
    private mutating func pruneIfNeeded() {
        guard visits.count > Self.capacity else { return }
        let survivors = visits.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lastVisited > rhs.lastVisited
            }
            .prefix(Self.capacity)
        visits = Dictionary(uniqueKeysWithValues: survivors.map { ($0.path, $0) })
    }
}
