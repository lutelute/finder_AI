import Foundation
import Testing
@testable import FinderAICore

@Test func workspaceHistoryBranchesLikeAFileBrowser() throws {
    var navigator = WorkspaceNavigator(
        initialDirectory: URL(fileURLWithPath: "/tmp/one", isDirectory: true)
    )
    navigator.navigate(to: URL(fileURLWithPath: "/tmp/two", isDirectory: true))
    navigator.navigate(to: URL(fileURLWithPath: "/tmp/three", isDirectory: true))

    #expect(navigator.goBack()?.path == "/tmp/two")
    #expect(navigator.goBack()?.path == "/tmp/one")
    #expect(navigator.goForward()?.path == "/tmp/two")

    navigator.navigate(to: URL(fileURLWithPath: "/tmp/branch", isDirectory: true))
    #expect(!navigator.canGoForward)
    #expect(navigator.currentDirectory.path == "/tmp/branch")
}

@Test func workspaceUpAddsAHistoryEntry() {
    var navigator = WorkspaceNavigator(
        initialDirectory: URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)
    )
    #expect(navigator.goUp()?.path == "/Users/example")
    #expect(navigator.canGoBack)
    #expect(navigator.goBack()?.path == "/Users/example/Documents")
}

@Test func workspaceRenameRelocatesCurrentFolderAndItsHistory() {
    var navigator = WorkspaceNavigator(
        initialDirectory: URL(fileURLWithPath: "/tmp/old/one", isDirectory: true)
    )
    navigator.navigate(to: URL(fileURLWithPath: "/tmp/old/two", isDirectory: true))
    navigator.navigate(to: URL(fileURLWithPath: "/tmp/old/three", isDirectory: true))
    _ = navigator.goBack()

    let moved = navigator.relocatePathPrefix(
        from: URL(fileURLWithPath: "/tmp/old", isDirectory: true),
        to: URL(fileURLWithPath: "/tmp/renamed", isDirectory: true)
    )

    #expect(moved)
    #expect(navigator.currentDirectory.path == "/tmp/renamed/two")
    #expect(navigator.goBack()?.path == "/tmp/renamed/one")
    #expect(navigator.goForward()?.path == "/tmp/renamed/two")
    #expect(navigator.goForward()?.path == "/tmp/renamed/three")
}

@Test func workspaceRenameDoesNotMistakeASimilarPathForADescendant() {
    var navigator = WorkspaceNavigator(
        initialDirectory: URL(fileURLWithPath: "/tmp/older/project", isDirectory: true)
    )

    let moved = navigator.relocatePathPrefix(
        from: URL(fileURLWithPath: "/tmp/old", isDirectory: true),
        to: URL(fileURLWithPath: "/tmp/new", isDirectory: true)
    )

    #expect(!moved)
    #expect(navigator.currentDirectory.path == "/tmp/older/project")
}

@Test func workspaceNamesRejectOnlyUnsafeOrAmbiguousComponents() {
    #expect(WorkspaceNameValidator.validated("日本語 folder") == "日本語 folder")
    #expect(WorkspaceNameValidator.validated("a$b 'quoted'") == "a$b 'quoted'")
    #expect(WorkspaceNameValidator.validated("") == nil)
    #expect(WorkspaceNameValidator.validated("   ") == nil)
    #expect(WorkspaceNameValidator.validated(".") == nil)
    #expect(WorkspaceNameValidator.validated("../escape") == nil)
    #expect(WorkspaceNameValidator.validated("folder:name") == nil)
}

@Test func workspaceListingIsDirectoriesFirstAndCanHideDotFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("finderai-workspace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("b".utf8).write(to: root.appendingPathComponent("b.txt"))
    try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Folder", isDirectory: true),
        withIntermediateDirectories: false
    )

    let visible = try WorkspaceDirectoryListing.contents(of: root)
    #expect(visible.map(\.name) == ["Folder", "a.txt", "b.txt"])
    let all = try WorkspaceDirectoryListing.contents(of: root, showHiddenFiles: true)
    #expect(all.contains(where: { $0.name == ".hidden" }))
}
