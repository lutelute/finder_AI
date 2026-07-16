import FinderAICore
import Foundation

/// Durable UI state. Everything here is a convenience the user re-establishes by
/// hand otherwise, so a missing or corrupt value must fall back to the shipped
/// default rather than surface an error.
@MainActor
struct WorkspacePreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let sidebarWidth = "workspace.sidebarWidth"
        static let sortColumn = "workspace.sortColumn"
        static let sortAscending = "workspace.sortAscending"
        static let showHiddenFiles = "workspace.showHiddenFiles"
        static let terminalHeight = "workspace.terminalHeight"
        static let terminalExpanded = "workspace.terminalExpanded"
        static let lastDirectory = "workspace.lastDirectory"
        static let pins = "workspace.pins"
        static let visits = "workspace.visits"
        static let splitEnabled = "workspace.splitEnabled"
        static let splitRatio = "workspace.splitRatio"
        static let secondDirectory = "workspace.secondDirectory"
    }

    // MARK: - Split view

    var splitEnabled: Bool {
        get { defaults.bool(forKey: Key.splitEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.splitEnabled) }
    }

    /// Left pane's share of the width. Clamped so a restored value can never hide
    /// a pane outright.
    var splitRatio: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.splitRatio)
            guard stored > 0 else { return 0.5 }
            return min(max(CGFloat(stored), 0.2), 0.8)
        }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.splitRatio) }
    }

    /// Plain path, for the same reason as `lastDirectory`.
    var secondDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.secondDirectory),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.secondDirectory)
                return
            }
            defaults.set(newValue.standardizedFileURL.path, forKey: Key.secondDirectory)
        }
    }

    // MARK: - Sidebar

    /// Paths, not bookmarks — see `lastDirectory` for why.
    var pins: WorkspacePins {
        get { WorkspacePins(paths: defaults.stringArray(forKey: Key.pins) ?? []) }
        nonmutating set { defaults.set(newValue.storedPaths, forKey: Key.pins) }
    }

    /// A corrupt log costs the user nothing to rebuild, so a decode failure starts
    /// over instead of surfacing.
    var visitLog: WorkspaceVisitLog {
        get {
            guard let data = defaults.data(forKey: Key.visits),
                  let visits = try? JSONDecoder().decode(
                      [WorkspaceVisitLog.Visit].self,
                      from: data
                  ) else { return WorkspaceVisitLog() }
            return WorkspaceVisitLog(visits: visits)
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue.all) else { return }
            defaults.set(data, forKey: Key.visits)
        }
    }

    // MARK: - Sidebar

    var sidebarWidth: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.sidebarWidth)
            guard stored > 0 else { return 210 }
            return min(max(CGFloat(stored), 160), 360)
        }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.sidebarWidth) }
    }

    // MARK: - Sorting

    var sortColumn: String {
        get { defaults.string(forKey: Key.sortColumn) ?? "name" }
        nonmutating set { defaults.set(newValue, forKey: Key.sortColumn) }
    }

    var sortAscending: Bool {
        get {
            guard defaults.object(forKey: Key.sortAscending) != nil else { return true }
            return defaults.bool(forKey: Key.sortAscending)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.sortAscending) }
    }

    // MARK: - Listing

    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: Key.showHiddenFiles) }
        nonmutating set { defaults.set(newValue, forKey: Key.showHiddenFiles) }
    }

    // MARK: - Terminal

    var terminalHeight: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.terminalHeight)
            guard stored > 0 else { return 300 }
            return min(max(CGFloat(stored), 160), 600)
        }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.terminalHeight) }
    }

    var terminalExpanded: Bool {
        get { defaults.bool(forKey: Key.terminalExpanded) }
        nonmutating set { defaults.set(newValue, forKey: Key.terminalExpanded) }
    }

    // MARK: - Last directory

    /// A plain path, and deliberately not a bookmark: resolving a bookmark to a
    /// protected folder took ~15s before the first window could appear, because
    /// it reaches the filesystem and TCC. This getter touches nothing but
    /// `UserDefaults`, so it is safe on the launch path — whether the folder
    /// still exists is the caller's problem, checked off the main thread.
    ///
    /// The trade-off is that a folder moved between launches is not followed;
    /// that is worth 15 seconds.
    var lastDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastDirectory),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.lastDirectory)
                return
            }
            defaults.set(newValue.standardizedFileURL.path, forKey: Key.lastDirectory)
        }
    }
}
