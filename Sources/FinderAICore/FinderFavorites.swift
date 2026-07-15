import Foundation

/// Reads the folders registered in Finder's sidebar.
///
/// Finder keeps them in a Shared File List:
/// `~/Library/Application Support/com.apple.sharedfilelist/
///  com.apple.LSSharedFileList.FavoriteItems.sfl4`
///
/// The public `LSSharedFileList` API no longer returns these, so the file is read
/// directly. It is the user's own file — no extra entitlement — but the format is
/// Apple's and undocumented, so every step here fails soft: an unreadable or
/// re-shaped file yields no favourites rather than an error, and the sidebar
/// falls back to its built-in locations.
public enum FinderFavorites {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(
                "Library/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.FavoriteItems.sfl4",
                isDirectory: false
            )
    }

    /// Bookmark blobs in file order, which is the order Finder lists them.
    ///
    /// The archive is an `NSKeyedArchiver` graph of Apple's own `SFLListItem`
    /// classes, which cannot be unarchived without those classes, so `$objects` is
    /// scanned for bookmark blobs instead of being walked properly. That means the
    /// order is the archive's, not an explicit index — it has matched Finder's
    /// order in practice, and a wrong order is a cosmetic problem, not a
    /// correctness one.
    public static func bookmarkBlobs(at url: URL? = nil) -> [Data] {
        let url = url ?? defaultURL
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else {
            return []
        }

        return objects.compactMap { object in
            guard let blob = object as? Data,
                  blob.count > 4,
                  blob.prefix(4) == Data("book".utf8) else { return nil }
            return blob
        }
    }

    /// Resolves blobs to existing directories.
    ///
    /// **Call this off the main thread.** Resolving a bookmark reaches the
    /// filesystem and TCC; doing it on the launch path once pushed time-to-window
    /// from 363ms to 15.6s. `withoutUI` keeps it from raising a dialog and
    /// `withoutMounting` keeps an unplugged network favourite from trying to mount.
    ///
    /// Non-directories, unresolvable items (AirDrop, iCloud placeholders) and
    /// duplicates are dropped.
    public static func resolveDirectories(
        _ blobs: [Data],
        fileManager: FileManager = .default
    ) -> [URL] {
        var seen = Set<String>()
        var directories: [URL] = []

        for blob in blobs {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: blob,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(standardized.path).inserted else { continue }
            directories.append(standardized)
        }
        return directories
    }

    /// Convenience for callers already on a background thread.
    public static func directories(at url: URL? = nil) -> [URL] {
        resolveDirectories(bookmarkBlobs(at: url))
    }
}
