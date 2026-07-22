import Foundation

/// Separates the folder being browsed from the folder whose Terminal tabs are
/// mounted in a window. Pinning changes only presentation; it never lies about
/// or mutates a running process's actual starting directory.
struct TerminalDrawerLink: Equatable {
    enum Mode: Equatable {
        case followsFinder
        case fixed
    }

    private(set) var finderDirectoryURL: URL?
    private(set) var fixedDirectoryURL: URL?

    var mode: Mode { fixedDirectoryURL == nil ? .followsFinder : .fixed }

    var terminalDirectoryURL: URL? {
        fixedDirectoryURL ?? finderDirectoryURL
    }

    mutating func setFinderDirectory(_ url: URL) {
        finderDirectoryURL = url.standardizedFileURL
    }

    mutating func fixTerminalDirectory(_ url: URL) {
        fixedDirectoryURL = url.standardizedFileURL
    }

    mutating func followFinder() {
        fixedDirectoryURL = nil
    }
}
