import AppKit
import FinderAICore
import Foundation
import Testing

@testable import FinderAIApp

/// サイドバーの名前は中ほどを省いて縮める。似た名前（`pws-nas03` と `pws-nas04`、
/// `OneDrive …大学` が並ぶ）は省くと見分けが付かないので、収まらないときは横に
/// 送れるようにした。列の最小幅が、いちばん長い名前が入る幅になっていること。
@MainActor
@Suite("サイドバーの横スクロール")
struct SidebarHorizontalScrollTests {
    @Test("列の最小幅は、いちばん長い名前が省かれずに入る幅")
    func columnFitsTheLongestName() throws {
        let longName = "OneDrive 国立大学法人福井大学 共有ライブラリの長い名前のフォルダ"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(longName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = try #require(UserDefaults(suiteName: "sidebar-hscroll-\(UUID().uuidString)"))
        let preferences = WorkspacePreferences(defaults: defaults)
        var pins = WorkspacePins()
        pins.pin(folder)
        preferences.pins = pins
        preferences.networkPlaces = NetworkPlaces([
            NetworkPlace(kind: .share, name: "pws-nas03", address: "smb://pws-nas03.local")
        ])
        let browser = WorkspaceBrowserViewController(initialDirectory: root, preferences: preferences)
        browser.loadView()
        browser.view.layoutSubtreeIfNeeded()

        let column = try #require(browser.sidebarTableForTesting.tableColumns.first)
        let textWidth = (longName as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]
        ).width
        #expect(column.minWidth >= textWidth + 30)
        #expect(column.width >= column.minWidth)
        #expect(browser.sidebarTableForTesting.enclosingScrollView?.hasHorizontalScroller == true)
    }
}
