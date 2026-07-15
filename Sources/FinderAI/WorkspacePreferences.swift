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

    /// Stored as a security-scoped bookmark so a restart still resolves the folder
    /// after the user moves or renames it, and so resolution failure is detectable
    /// rather than silently landing on a path that no longer exists.
    var lastDirectory: URL? {
        get {
            guard let data = defaults.data(forKey: Key.lastDirectory) else { return nil }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return url.standardizedFileURL
        }
        nonmutating set {
            guard let newValue,
                  let data = try? newValue.bookmarkData(
                      options: [],
                      includingResourceValuesForKeys: nil,
                      relativeTo: nil
                  ) else {
                defaults.removeObject(forKey: Key.lastDirectory)
                return
            }
            defaults.set(data, forKey: Key.lastDirectory)
        }
    }
}
