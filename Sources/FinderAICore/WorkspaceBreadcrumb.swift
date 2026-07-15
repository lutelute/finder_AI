import Foundation

/// Splits a directory into the crumbs shown above the file list.
///
/// This is deliberately pure string/URL work. Handing the URL to `NSPathControl`
/// instead makes AppKit resolve a display name and icon per component over
/// synchronous XPC, which blocks the main thread until TCC answers — clicking
/// Desktop or Downloads froze the app outright.
public enum WorkspaceBreadcrumb {
    public struct Crumb: Equatable, Sendable {
        public let title: String
        public let url: URL

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    /// Root first, `directory` last. Never touches the filesystem, so a folder
    /// that no longer exists still produces crumbs.
    public static func crumbs(for directory: URL, rootTitle: String = "Macintosh HD") -> [Crumb] {
        var ancestors: [URL] = []
        var url = directory.standardizedFileURL
        while true {
            ancestors.append(url)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent == url { break }
            url = parent
        }

        return ancestors.reversed().map { url in
            let name = url.lastPathComponent
            // `URL(fileURLWithPath: "/").lastPathComponent` is "/", not "".
            let title = (name.isEmpty || name == "/") ? rootTitle : name
            return Crumb(title: title, url: url)
        }
    }
}
