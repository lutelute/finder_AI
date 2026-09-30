import AppKit
import FinderAICore
import Foundation
import Testing

@testable import FinderAIApp

/// サイドバーは今いる場所の行を選び直す。サーバーのフォルダを見ているとき、それを
/// 「押した」と受け取ってサーバーを開き直すと、開く→移る→選び直す→開く…と
/// 4秒おきに繰り返した（実機、build 118）。
@MainActor
@Suite("サーバーの行の選び直し")
struct NetworkServerViewSelectionTests {
    @Test("そのサーバーのフォルダを見ているあいだは、行を選び直しても開き直さない")
    func reselectingTheServerRowDoesNotReopenIt() throws {
        let place = NetworkPlace(kind: .share, name: "zz-selection-test", address: "smb://192.0.2.1")
        let folder = NetworkServerFolder.folder(for: place)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let defaults = try #require(UserDefaults(suiteName: "server-selection-\(UUID().uuidString)"))
        let preferences = WorkspacePreferences(defaults: defaults)
        preferences.networkPlaces = NetworkPlaces([place])
        let browser = WorkspaceBrowserViewController(initialDirectory: folder, preferences: preferences)
        browser.loadView()
        browser.view.layoutSubtreeIfNeeded()

        let row = try #require(browser.sidebarRowForTesting(named: place.name))
        let table = browser.sidebarTableForTesting
        table.deselectAll(nil)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        #expect(NetworkPlaceConnector.shared.transientState(for: place.id) == nil)
        #expect(browser.currentDirectory.standardizedFileURL.path == folder.standardizedFileURL.path)
    }
}
