import FinderAICore
import Foundation
import Testing

@Suite("Column view keeps the columns it already has")
struct WorkspaceColumnPathTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test("every ancestor is a column, root first")
    func columns() {
        let columns = WorkspaceColumnPath.columns(for: url("/Users/someone/Desktop"))
        #expect(columns.map(\.path) == ["/", "/Users", "/Users/someone", "/Users/someone/Desktop"])
    }

    @Test("the root alone is one column")
    func rootIsOneColumn() {
        #expect(WorkspaceColumnPath.columns(for: url("/")).map(\.path) == ["/"])
    }

    @Test("a folder that does not exist still decomposes")
    func doesNotRequireTheFolderToExist() {
        // Pure path work; whether it can be read is the caller's problem.
        let ghost = url("/nope-\(UUID().uuidString)/a/b")
        #expect(WorkspaceColumnPath.columns(for: ghost).count == 4)
    }

    /// Going deeper must keep every column already on screen, or each click would
    /// re-read folders the user is already looking at.
    @Test("descending keeps all current columns")
    func descendingKeepsEverything() {
        let shared = WorkspaceColumnPath.sharedPrefixLength(
            from: url("/Users/someone"),
            to: url("/Users/someone/Desktop")
        )
        #expect(shared == 3) // /, /Users, /Users/someone
    }

    @Test("stepping sideways keeps the common ancestors and drops the rest")
    func sidewaysKeepsAncestors() {
        let shared = WorkspaceColumnPath.sharedPrefixLength(
            from: url("/Users/someone/Desktop"),
            to: url("/Users/someone/Documents")
        )
        // /, /Users, /Users/someone survive; Desktop is replaced by Documents.
        #expect(shared == 3)
    }

    @Test("going up keeps the ancestors of where you land")
    func ascending() {
        let shared = WorkspaceColumnPath.sharedPrefixLength(
            from: url("/Users/someone/Desktop"),
            to: url("/Users")
        )
        #expect(shared == 2)
    }

    @Test("an unrelated path shares only the root")
    func unrelated() {
        let shared = WorkspaceColumnPath.sharedPrefixLength(
            from: url("/Users/someone/Desktop"),
            to: url("/Applications")
        )
        #expect(shared == 1)
    }

    @Test("the same folder shares all of itself")
    func identical() {
        let path = url("/Users/someone")
        #expect(WorkspaceColumnPath.sharedPrefixLength(from: path, to: path) == 3)
    }

    @Test("different spellings of one folder are the same folder")
    func normalises() {
        #expect(WorkspaceColumnPath.sharedPrefixLength(
            from: url("/Users/someone/"),
            to: url("/Users/x/../someone")
        ) == 3)
    }

    @Test("spaces and non-ASCII survive")
    func awkwardNames() {
        let columns = WorkspaceColumnPath.columns(for: url("/Users/someone/書籍 (L)/001"))
        #expect(columns.map(\.lastPathComponent) == ["/", "Users", "someone", "書籍 (L)", "001"])
    }
}
