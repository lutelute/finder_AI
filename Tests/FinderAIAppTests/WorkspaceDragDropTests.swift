import AppKit
@testable import FinderAIApp
import Testing

@Suite("Finder-like workspace drag and drop")
struct WorkspaceDragDropTests {
    @Test("Option chooses copy and a plain drag prefers move")
    func operationFollowsFinderModifiers() {
        #expect(WorkspaceDragDrop.localSourceOperations == [.copy, .move, .link])
        #expect(WorkspaceDragDrop.externalSourceOperations == .copy)
        // .linkが要る。グループの見出しや地図の島は、ファイルを動かさないので.linkを
        // 返して受ける。引く側が許していない操作はOSが弾くので、ここに.linkが無いと
        // 「一覧の行をグループへ引いても入らない」になる。
        #expect(WorkspaceDragDrop.localSourceOperations.contains(.link))
        // .linkが増えても、移動とコピーの選び方は変わらない（.linkは選ばれない）。
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy, .move, .link],
            optionKeyPressed: false
        ) == .move)
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy, .move, .link],
            optionKeyPressed: true
        ) == .copy)
        // .linkしか許されていないときは、ファイルを動かす操作は成立しない。
        #expect(!WorkspaceDragDrop.allows(
            sources: [URL(fileURLWithPath: "/tmp/a")],
            destination: URL(fileURLWithPath: "/tmp/b"),
            operation: .link
        ))
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy, .move],
            optionKeyPressed: false
        ) == .move)
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy, .move],
            optionKeyPressed: true
        ) == .copy)
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [.copy],
            optionKeyPressed: false
        ) == .copy)
        #expect(WorkspaceDragDrop.operation(
            allowedOperations: [],
            optionKeyPressed: false
        ).isEmpty)
    }

    @Test("moving to the same parent is a no-op but Option-copy is valid")
    func sameFolderPolicy() {
        let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let file = folder.appendingPathComponent("draft.txt")

        #expect(!WorkspaceDragDrop.allows(
            sources: [file],
            destination: folder,
            operation: .move
        ))
        #expect(WorkspaceDragDrop.allows(
            sources: [file],
            destination: folder,
            operation: .copy
        ))
        #expect(!WorkspaceDragDrop.allows(
            sources: [folder],
            destination: folder,
            operation: .move
        ))
    }

    @Test("file URLs round-trip through the drag pasteboard")
    @MainActor
    func pasteboardCarriesFileURLs() {
        let pasteboard = NSPasteboard(name: .init("finderai-drag-\(UUID().uuidString)"))
        let first = URL(fileURLWithPath: "/tmp/日本語 file.txt")
        let second = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        pasteboard.clearContents()
        let writers = [first, second].compactMap(WorkspaceDragDrop.pasteboardWriter(for:))
        #expect(pasteboard.writeObjects(writers))
        #expect(pasteboard.types?.contains(.fileURL) == true)

        #expect(WorkspaceDragDrop.fileURLs(from: pasteboard) == [
            first.standardizedFileURL,
            second.standardizedFileURL
        ])
    }
}

/// 引いて入れる操作は、`.link`をドラッグ元が許していないとOSに弾かれる。
/// マスクを各所で書くと、書き忘れた場所だけ静かに死ぬ（実際に二度起きた）。
@Suite("ドラッグ元の名乗りは一箇所に集める")
struct WorkspaceDragSourcePolicyTests {
    @Test("マスクを直に設定している場所が、WorkspaceDragDrop以外に無い")
    func everyDragSourceGoesThroughTheHelper() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FinderAIAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリの根
            .appendingPathComponent("Sources/FinderAI")
        let files = try FileManager.default.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "WorkspaceDragDrop.swift" }
        #expect(!files.isEmpty, "探し場所が違う: \(sources.path)")

        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("setDraggingSourceOperationMask") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(
            offenders.isEmpty,
            "WorkspaceDragDrop.configureDragSource(_:) を通すこと: \(offenders.joined(separator: ", "))"
        )
    }
}
