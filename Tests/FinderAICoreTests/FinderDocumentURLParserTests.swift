import Foundation
import Testing
@testable import FinderAICore

@Test func parsesEncodedFileURL() throws {
    let parsed = try #require(FinderDocumentURLParser.parse("file:///tmp/a%20b/%E6%97%A5%E6%9C%AC%E8%AA%9E/"))
    #expect(parsed.path == "/tmp/a b/日本語")
}

@Test func parsesLiteralPathWithoutShellInterpretation() throws {
    let path = "/tmp/-folder/quote'\"/line\nbreak"
    let parsed = try #require(FinderDocumentURLParser.parse(path))
    #expect(parsed.path == path)
}

@Test func rejectsNonFileURLsAndRelativePaths() {
    #expect(FinderDocumentURLParser.parse("https://example.com") == nil)
    #expect(FinderDocumentURLParser.parse("relative/path") == nil)
    #expect(FinderDocumentURLParser.parse("") == nil)
}

@Test func sessionKeyKeepsKindsSeparate() {
    let url = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
    #expect(
        TerminalSessionKey(directoryURL: url, kind: .shell)
            != TerminalSessionKey(directoryURL: url, kind: .codex)
    )
}

@Test func sessionKeyCanonicalizesSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("finder-ai-key-\(UUID().uuidString)", isDirectory: true)
    let target = root.appendingPathComponent("target", isDirectory: true)
    let link = root.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(
        TerminalSessionKey(directoryURL: target, kind: .shell)
            == TerminalSessionKey(directoryURL: link, kind: .shell)
    )
}
