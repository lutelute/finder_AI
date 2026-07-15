import FinderAICore
import Foundation
import Testing

/// Pins the breadcrumb to pure URL work.
///
/// `pathControl.url = ...` had AppKit resolve a display name and icon per
/// component over synchronous XPC. On Desktop or Downloads that blocked the main
/// thread until TCC was answered: a stack sample showed 4347 of 4347 main-thread
/// samples inside `xpc_connection_send_message_with_reply_sync` under that one
/// assignment, with the spinner still turning and the app unresponsive.
@Suite("Breadcrumb never touches the filesystem")
struct WorkspaceBreadcrumbTests {
    @Test("every ancestor becomes a crumb, root first")
    func coversTheWholePath() {
        let crumbs = WorkspaceBreadcrumb.crumbs(
            for: URL(fileURLWithPath: "/Users/someone/Desktop", isDirectory: true)
        )
        #expect(crumbs.map(\.title) == ["Macintosh HD", "Users", "someone", "Desktop"])
        #expect(crumbs.map(\.url.path) == ["/", "/Users", "/Users/someone", "/Users/someone/Desktop"])
    }

    @Test("the root alone yields a single crumb")
    func rootIsOneCrumb() {
        let crumbs = WorkspaceBreadcrumb.crumbs(for: URL(fileURLWithPath: "/", isDirectory: true))
        // `URL(fileURLWithPath: "/").lastPathComponent` is "/", not "", so the
        // root needs handling beyond an isEmpty check.
        #expect(crumbs.map(\.title) == ["Macintosh HD"])
        #expect(crumbs.map(\.url.path) == ["/"])
    }

    @Test("a folder that does not exist still yields crumbs")
    func doesNotRequireTheFolderToExist() {
        // The proof that nothing here reaches the filesystem: an unstattable path
        // still decomposes.
        let ghost = URL(fileURLWithPath: "/nope-\(UUID().uuidString)/a/b", isDirectory: true)
        let crumbs = WorkspaceBreadcrumb.crumbs(for: ghost)

        #expect(crumbs.count == 4)
        #expect(crumbs.last?.title == "b")
        #expect(crumbs.first?.title == "Macintosh HD")
    }

    @Test("spaces and non-ASCII names survive intact")
    func awkwardNames() {
        let crumbs = WorkspaceBreadcrumb.crumbs(
            for: URL(fileURLWithPath: "/Users/someone/書類 と 空白/データ", isDirectory: true)
        )
        #expect(crumbs.map(\.title) == ["Macintosh HD", "Users", "someone", "書類 と 空白", "データ"])
    }

    @Test("trailing slashes do not produce an empty crumb")
    func normalizesTrailingSlash() {
        let withSlash = WorkspaceBreadcrumb.crumbs(for: URL(fileURLWithPath: "/Users/someone/", isDirectory: true))
        let without = WorkspaceBreadcrumb.crumbs(for: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        #expect(withSlash == without)
        #expect(withSlash.map(\.title) == ["Macintosh HD", "Users", "someone"])
    }
}
