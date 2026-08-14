import AppKit
import FinderAICore
@testable import FinderAIApp
import Testing

/// 落とす側（NSDraggingInfo）の代わり。GUIのドラッグを合成せずに、
/// 受け側の経路をそのまま叩くために立てる。
final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var mask: NSDragOperation

    init(urls: [URL], mask: NSDragOperation) {
        pasteboard = NSPasteboard(name: .init("finderai-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.compactMap(WorkspaceDragDrop.pasteboardWriter(for:)))
        self.mask = mask
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set { _ = newValue }
    }
    var animatesToDestination: Bool {
        get { false }
        set { _ = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set { _ = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

/// 「移動がドラッグドロップでできない」「そのフォルダに入れられない」という
/// 報告を、受け側の経路をそのまま叩いて確かめる。
@Suite("引いて落として、動かす")
@MainActor
struct WorkspaceFileDropTests {
    private static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 読み込みは別のタスクで走る。出てくるまで回す。
    private static func waitForListing(
        _ controller: WorkspaceBrowserViewController,
        count: Int
    ) async {
        for _ in 0..<200 {
            if controller.displayedItemsForTesting.count >= count { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func controller(at folder: URL) -> WorkspaceBrowserViewController {
        _ = NSApplication.shared
        let preferences = WorkspacePreferences(
            defaults: UserDefaults(suiteName: "finderai-drop-\(UUID().uuidString)")!
        )
        let controller = WorkspaceBrowserViewController(
            initialDirectory: folder,
            preferences: preferences
        )
        controller.loadViewIfNeeded()
        // 一覧の読み込みは viewDidAppear から始まる。
        controller.viewDidAppear()
        return controller
    }

    @Test("フォルダの行に落とすと、その中へ移る")
    func droppingOnAFolderRowMovesInto() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("動かすもの.txt")
        let destination = folder.appendingPathComponent("行き先", isDirectory: true)
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let controller = Self.controller(at: folder)
        await Self.waitForListing(controller, count: 2)
        let table = controller.fileTableForTesting
        let row = try #require(controller.rowForTesting(named: "行き先"), "行き先の行が無い")

        let info = StubDraggingInfo(urls: [file], mask: WorkspaceDragDrop.localSourceOperations)
        let operation = controller.tableView(
            table,
            validateDrop: info,
            proposedRow: row,
            proposedDropOperation: .on
        )
        #expect(operation == .move, "フォルダの行に落としたら移動になること")

        #expect(controller.tableView(table, acceptDrop: info, row: row, dropOperation: .on))
        #expect(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("動かすもの.txt").path),
            "行き先の中に入っていない"
        )
        #expect(!FileManager.default.fileExists(atPath: file.path), "元の場所に残っている")
    }

    @Test("同じフォルダの中へ落としても、何も起きない")
    func droppingOnTheSameFolderDoesNothing() async throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("そのまま.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let controller = Self.controller(at: folder)
        await Self.waitForListing(controller, count: 1)
        let table = controller.fileTableForTesting

        let info = StubDraggingInfo(urls: [file], mask: WorkspaceDragDrop.localSourceOperations)
        let operation = controller.tableView(
            table,
            validateDrop: info,
            proposedRow: -1,
            proposedDropOperation: .on
        )
        #expect(operation.isEmpty, "同じ場所への移動は成り立たない")
    }

    @Test("外から引いてきたものは、そのフォルダに入る")
    func droppingFromOutsideMovesIn() async throws {
        let source = try Self.temporaryFolder()
        let folder = try Self.temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = source.appendingPathComponent("よそから.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let controller = Self.controller(at: folder)
        await Self.waitForListing(controller, count: 0)
        let table = controller.fileTableForTesting

        let info = StubDraggingInfo(urls: [file], mask: WorkspaceDragDrop.localSourceOperations)
        let operation = controller.tableView(
            table,
            validateDrop: info,
            proposedRow: -1,
            proposedDropOperation: .on
        )
        #expect(operation == .move)
        #expect(controller.tableView(table, acceptDrop: info, row: -1, dropOperation: .on))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("よそから.txt").path))
    }
}

/// 地図の右の一覧は「普通のFinderのリスト表示」。引いてきたものを落とせないと
/// おかしいが、**落とし先として名乗っていなかった**ので何も起きなかった。
@Suite("地図の右の一覧にも落とせる")
@MainActor
struct WorkspaceMapListDropTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-mapdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(_ url: URL, isDirectory: Bool) -> WorkspaceItem {
        WorkspaceItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isHidden: false,
            fileSize: nil,
            modifiedAt: nil,
            typeDescription: isDirectory ? "フォルダ" : "書類"
        )
    }

    @Test("フォルダの行に落とせばその中へ、地に落とせばこのフォルダへ")
    func mapListAcceptsDrops() throws {
        _ = NSApplication.shared
        let folder = try temporaryFolder()
        let outside = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let file = outside.appendingPathComponent("よそから.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let destination = folder.appendingPathComponent("行き先", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        view.currentDirectory = folder
        var asked: [(URL, Bool)] = []
        view.onTransfer = { _, destination, copy in
            asked.append((destination, copy))
            return true
        }
        view.show(
            items: [item(destination, isDirectory: true)],
            groups: nil,
            presentNames: ["行き先"]
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        let table = try #require(view.othersTableForTesting)
        // 落とし先として名乗っていること。名乗っていないと、そもそも呼ばれない。
        #expect(table.registeredDraggedTypes.contains(.fileURL), "落とし先として名乗っていない")

        let info = StubDraggingInfo(urls: [file], mask: WorkspaceDragDrop.localSourceOperations)
        // 「行き先」の行へ
        let row = try #require(view.listRowForTesting(named: "行き先"))
        #expect(view.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: .on) == .move)
        #expect(view.tableView(table, acceptDrop: info, row: row, dropOperation: .on))
        #expect(asked.last?.0 == destination)
        #expect(asked.last?.1 == false, "移動であってコピーではない")

        // 地（行の無いところ）へ
        #expect(view.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on) == .move)
        #expect(view.tableView(table, acceptDrop: info, row: -1, dropOperation: .on))
        #expect(asked.last?.0 == folder)
    }
}
