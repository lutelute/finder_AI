import AppKit
import Testing

@testable import FinderAIApp

/// The menu is the only place a keyboard shortcut is declared, so a collision
/// is silent: AppKit picks one item and the other key simply stops working.
/// ⌘D shipped as "サイドバーにピン留め" while Finder uses it for 複製, and 複製
/// itself was reachable only from the context menu.
@MainActor
@Suite("Main menu keyboard shortcuts")
struct MainMenuShortcutTests {
    /// Built with no coordinator: every assertion here is about titles and keys,
    /// and passing nil keeps the app's real state out of the test.
    private func menu() -> NSMenu {
        WorkspaceAppCoordinator.makeMainMenu(coordinator: nil)
    }

    private func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.compactMap(\.submenu).flatMap(\.items).filter { !$0.isSeparatorItem }
    }

    private func item(_ title: String) -> NSMenuItem? {
        items(in: menu()).first { $0.title == title }
    }

    @Test("no two commands claim the same key and modifier")
    func noCollisions() {
        var seen: [String: String] = [:]
        for entry in items(in: menu()) where !entry.keyEquivalent.isEmpty {
            let chord = "\(entry.keyEquivalentModifierMask.rawValue):\(entry.keyEquivalent)"
            #expect(
                seen[chord] == nil,
                "\(chord) is claimed by both “\(seen[chord] ?? "")” and “\(entry.title)”"
            )
            seen[chord] = entry.title
        }
    }

    /// ⌃Tabはターミナルが自分宛ての入力として食べてしまい、メニューまで
    /// 届かなかった（実機で確認）。⌘つきなら通る。
    @Test("セッションの巡回は⌘⌥←／⌘⌥→。ターミナルに食われない組み合わせ")
    func sessionCyclingUsesCommandOptionArrows() {
        let next = item("次のTerminalセッション")
        #expect(next?.keyEquivalent == String(UnicodeScalar(NSRightArrowFunctionKey)!))
        #expect(next?.keyEquivalentModifierMask == [.command, .option])

        let previous = item("前のTerminalセッション")
        #expect(previous?.keyEquivalent == String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        #expect(previous?.keyEquivalentModifierMask == [.command, .option])
    }

    @Test("⌘D duplicates and pinning moves to ⌃⌘T, as in Finder")
    func duplicateOwnsCommandD() {
        let duplicate = item("複製")
        #expect(duplicate?.keyEquivalent == "d")
        #expect(duplicate?.keyEquivalentModifierMask == [.command])

        let pin = item("サイドバーにピン留め／解除")
        #expect(pin?.keyEquivalent == "t")
        #expect(pin?.keyEquivalentModifierMask == [.command, .control])
    }

    @Test("⌘2/⌘3/⌘4 select a view mode directly and ⌘⌥2 still cycles")
    func viewModesAreDirectlyReachable() {
        let expected = [("リスト表示", "2"), ("カラム表示", "3"), ("ギャラリー表示", "4")]
        for (title, key) in expected {
            let entry = item(title)
            #expect(entry?.keyEquivalent == key, "\(title) should be ⌘\(key)")
            #expect(entry?.keyEquivalentModifierMask == [.command])
        }

        let cycle = item("表示モードを切り替え")
        #expect(cycle?.keyEquivalent == "2")
        #expect(cycle?.keyEquivalentModifierMask == [.command, .option])
    }

    @Test("commands that only existed in the context menu are now in ファイル")
    func contextOnlyCommandsAreDiscoverable() {
        let fileMenu = menu().items.compactMap(\.submenu).first { $0.title == "ファイル" }
        let titles = fileMenu?.items.map(\.title) ?? []
        for title in ["情報を見る", "複製", "エイリアスを作成", "圧縮"] {
            #expect(titles.contains(title), "ファイルメニューに“\(title)”がない")
        }
        #expect(item("情報を見る")?.keyEquivalent == "i")
        #expect(item("エイリアスを作成")?.keyEquivalentModifierMask == [.command, .control])
    }
}
