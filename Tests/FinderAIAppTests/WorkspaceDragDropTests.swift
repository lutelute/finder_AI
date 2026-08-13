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
    /// `Sources/FinderAI`のSwiftファイル。下の階層まで辿る。
    /// contentsOfDirectoryだと、あとでフォルダを切ったときにその中を黙って見逃す
    /// （今はフォルダが無いので、見逃しても誰も気づけない）。
    static func sourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FinderAIAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリの根
            .appendingPathComponent("Sources/FinderAI")
        let walker = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "探し場所が違う: \(sources.path)"
        )
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "探し場所が違う: \(sources.path)")
        return files
    }

    @Test("マスクを直に設定している場所が、WorkspaceDragDrop以外に無い")
    func everyDragSourceGoesThroughTheHelper() throws {
        let files = try Self.sourceFiles().filter { $0.lastPathComponent != "WorkspaceDragDrop.swift" }

        var offenders: [String] = []
        var configured = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("setDraggingSourceOperationMask") {
                offenders.append(file.lastPathComponent)
            }
            configured += text.components(separatedBy: "WorkspaceDragDrop.configureDragSource(").count - 1
        }
        #expect(
            offenders.isEmpty,
            "WorkspaceDragDrop.configureDragSource(_:) を通すこと: \(offenders.joined(separator: ", "))"
        )
        // 呼び出し口が消えていたら、違反が無いのではなく検査が空を撫でている。
        #expect(configured > 0, "\(files.count)個のファイルに、ドラッグ元の名乗りが一つも無い")
    }

    /// 落とすだけで、そこから引くことはない場所。**理由を書いたものだけ**通る。
    ///
    /// ここに書いていない新顔は落とす。「直に書いた違反」しか見ない検査だと、
    /// 新しい一覧が**そもそも何も名乗らない**ときに素通りしてしまい、
    /// 引いても何も起きない（実際に二度起きた壊れ方と同じ見え方になる）。
    static let dropOnlySites: [String: String] = [
        "WorkspaceBrowserViewController.swift:sidebarTable":
            "よく使う場所。落として登録するだけで、ここから引いて出すことはない",
        "EdgeTabButton.swift:self":
            "袖のタブ。落として移す先で、ボタン自身は掴めない"
    ]

    @Test("落とせる場所は、引ける場所かどうかを言い切っている")
    func everyDropTargetSaysWhetherItCanBeDragged() throws {
        var sites: [(key: String, ok: Bool)] = []
        for file in try Self.sourceFiles() {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            // 落とし先として名乗る場所を全部出す（手で並べない）。
            for line in text.components(separatedBy: .newlines)
            where line.contains(".registerForDraggedTypes(") || line.contains("registerForDraggedTypes(") {
                guard let head = line.components(separatedBy: "registerForDraggedTypes(").first else { continue }
                let receiver = head
                    .trimmingCharacters(in: .whitespaces)
                    .hasSuffix(".")
                    ? String(head.trimmingCharacters(in: .whitespaces).dropLast())
                        .components(separatedBy: CharacterSet(charactersIn: " \t=("))
                        .last ?? "self"
                    : "self"
                let key = "\(name):\(receiver)"
                // 引けるなら、名乗り方は二つだけ。ヘルパを通すか、
                // NSDraggingSourceで`localSourceOperations`を返すか。
                let viaHelper = text.contains("WorkspaceDragDrop.configureDragSource(\(receiver))")
                // 「このファイルのどこかにNSDraggingSourceがある」では駄目。
                // それだと同じファイルに足した新顔まで免除されて、素通りする
                // （地図のファイルで実際に見逃した）。その受け手が引き手として
                // 渡されていることまで見る。
                let viaProtocol = text.contains("NSDraggingSource")
                    && text.contains("WorkspaceDragDrop.localSourceOperations")
                    && text.contains("source: \(receiver))")
                sites.append((key, viaHelper || viaProtocol || Self.dropOnlySites[key] != nil))
            }
        }

        #expect(!sites.isEmpty, "落とし先が一つも見つからない。検査が空を撫でている")
        let unexplained = sites.filter { !$0.ok }.map(\.key)
        #expect(
            unexplained.isEmpty,
            """
            落とせるのに、引けるかどうかを言っていない: \(unexplained.joined(separator: ", "))
            引けるなら WorkspaceDragDrop.configureDragSource(_:) を通す。
            落とすだけなら dropOnlySites に理由を書く。
            """
        )

        // 実体の消えた但し書きは、次に読む人を騙す。
        let stale = Self.dropOnlySites.keys.filter { key in !sites.contains { $0.key == key } }
        #expect(stale.isEmpty, "dropOnlySitesに、もう無い場所が残っている: \(stale.joined(separator: ", "))")
    }
}
