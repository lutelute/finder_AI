import Foundation

/// Works out which columns a column view should show.
///
/// Finder's column view keeps every ancestor of the current folder on screen and
/// scrolls right as you go deeper. Navigating sideways within a level replaces
/// the columns after it rather than starting over — that is what makes the view
/// feel like one continuous path instead of a reload per click.
public enum WorkspaceColumnPath {
    /// Ancestors of `directory`, root first, ending with `directory` itself.
    ///
    /// This is the column list: each entry is a folder whose contents fill one
    /// column. Pure — a folder that no longer exists still decomposes, and
    /// whether it can be read is the caller's problem.
    public static func columns(for directory: URL) -> [URL] {
        var ancestors: [URL] = []
        var url = directory.standardizedFileURL
        while true {
            ancestors.append(url)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent == url { break }
            url = parent
        }
        return ancestors.reversed()
    }

    /// The columns to keep when moving from `current` to `target`.
    ///
    /// Returns how many leading columns the two paths share. Everything from
    /// there on is replaced. Going deeper keeps all of `current`; stepping
    /// sideways keeps the common ancestors and drops the rest, so the already
    /// loaded columns are not thrown away and re-read.
    public static func sharedPrefixLength(from current: URL, to target: URL) -> Int {
        let a = columns(for: current)
        let b = columns(for: target)
        var shared = 0
        while shared < a.count, shared < b.count, a[shared] == b[shared] {
            shared += 1
        }
        return shared
    }
}
