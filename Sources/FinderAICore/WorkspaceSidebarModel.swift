import Foundation

/// Assembles the sidebar's sections from the pieces that feed it.
///
/// Pure: callers hand in already-loaded data, because two of the sources (Finder
/// favourites, mounted volumes) can only be read off the main thread and the
/// composition rules should not be trapped behind that.
public enum WorkspaceSidebarModel {
    public struct Item: Equatable, Sendable {
        public let title: String
        public let url: URL
        public let symbol: String

        public init(title: String, url: URL, symbol: String) {
            self.title = title
            self.url = url.standardizedFileURL
            self.symbol = symbol
        }
    }

    public struct Section: Equatable, Sendable {
        public let title: String
        public let items: [Item]

        public init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public struct Input: Sendable {
        public var pins: [URL]
        public var favorites: [URL]
        public var volumes: [URL]
        public var frequent: [URL]
        public var recent: [URL]

        public init(
            pins: [URL] = [],
            favorites: [URL] = [],
            volumes: [URL] = [],
            frequent: [URL] = [],
            recent: [URL] = []
        ) {
            self.pins = pins
            self.favorites = favorites
            self.volumes = volumes
            self.frequent = frequent
            self.recent = recent
        }
    }

    /// Shown when Finder's favourites cannot be read, so the sidebar is never
    /// empty. Not merged with real favourites — duplicating what Finder already
    /// lists would be worse than a short section.
    public static func fallbackFavorites(home: URL) -> [URL] {
        [
            home,
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true)
        ]
    }

    /// Sections in display order, empty ones omitted.
    ///
    /// A folder appears once, in its highest-priority section: pinning something
    /// that is also a favourite and also frequent should move it, not clone it.
    public static func sections(_ input: Input, home: URL) -> [Section] {
        var claimed = Set<String>()

        func take(_ urls: [URL], symbol: (URL) -> String) -> [Item] {
            urls.compactMap { url in
                let standardized = url.standardizedFileURL
                guard claimed.insert(standardized.path).inserted else { return nil }
                return Item(
                    title: displayName(for: standardized, home: home),
                    url: standardized,
                    symbol: symbol(standardized)
                )
            }
        }

        let pins = take(input.pins) { _ in "pin.fill" }
        let favorites = take(input.favorites) { symbol(for: $0, home: home) }
        let volumes = take(input.volumes) { $0.path == "/" ? "internaldrive.fill" : "externaldrive.fill" }
        let frequent = take(input.frequent) { _ in "clock.arrow.trianglehead.counterclockwise.rotate.90" }
        let recent = take(input.recent) { _ in "clock" }

        return [
            Section(title: "ピン留め", items: pins),
            Section(title: "よく使う項目", items: favorites),
            Section(title: "場所", items: volumes),
            Section(title: "よく使うフォルダ", items: frequent),
            Section(title: "最近", items: recent)
        ].filter { !$0.items.isEmpty }
    }

    /// Finder shows the home folder under the account's short name rather than
    /// "shigenoburyuto"'s literal path component, and "/" as the startup disk.
    public static func displayName(for url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == home.standardizedFileURL.path { return NSUserName() }
        if path == "/" { return "Macintosh HD" }
        let name = url.standardizedFileURL.lastPathComponent
        // `URL(fileURLWithPath: "/").lastPathComponent` is "/", not "".
        return (name.isEmpty || name == "/") ? path : name
    }

    /// Compares paths rather than URLs: `URL` equality is sensitive to a trailing
    /// slash, and favourites arriving from bookmarks are not spelled consistently,
    /// so `Desktop` and `Desktop/` would take different branches.
    private static func symbol(for url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path

        if path == homePath { return "house.fill" }
        switch path {
        case "\(homePath)/Desktop": return "desktopcomputer"
        case "\(homePath)/Documents": return "doc.fill"
        case "\(homePath)/Downloads": return "arrow.down.circle.fill"
        case "\(homePath)/Movies": return "film.fill"
        case "\(homePath)/Music": return "music.note"
        case "\(homePath)/Pictures": return "photo.fill"
        case "/Applications": return "square.grid.3x3.fill"
        default:
            return path.contains("/CloudStorage/") ? "icloud.fill" : "folder.fill"
        }
    }
}
