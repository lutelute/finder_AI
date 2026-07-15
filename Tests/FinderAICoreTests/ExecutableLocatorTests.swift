import Foundation
import Testing
@testable import FinderAICore

@Test func findsExecutableWithoutUsingShell() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("finder-ai-locator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = root.appendingPathComponent("codex")
    #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let found = ExecutableLocator.locate(
        command: "codex",
        environment: ["PATH": root.path],
        homeDirectory: root
    )
    #expect(found == executable.standardizedFileURL)
}

@Test func rejectsPathLikeCommand() {
    #expect(ExecutableLocator.locate(command: "../codex") == nil)
    #expect(ExecutableLocator.locate(command: "/bin/zsh") == nil)
}
