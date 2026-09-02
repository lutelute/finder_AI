import AppKit
import FinderAICore
import Testing

@testable import FinderAIApp

/// 色を選ぶボタンが、押せる的として実際に並んでいることを固定する。
///
/// メニューの奥にだけ置くと、在ることに気付かれない。ボタンが消えても
/// メニューは生きているので、テストが無いと「機能はある」で見過ごされる。
@MainActor
@Suite("窓の色を選ぶボタン")
struct WindowTintButtonTests {
    private func loadedBrowser() -> WorkspaceBrowserViewController {
        let defaults = UserDefaults(suiteName: "tint-button-\(UUID().uuidString)")!
        let browser = WorkspaceBrowserViewController(
            initialDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            preferences: WorkspacePreferences(defaults: defaults)
        )
        browser.loadView()
        browser.view.layoutSubtreeIfNeeded()
        return browser
    }

    /// ツールバーに並んでいる、押せるボタンをぜんぶ拾う。
    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        for child in view.subviews {
            if let button = child as? NSButton { found.append(button) }
            found.append(contentsOf: buttons(in: child))
        }
        return found
    }

    @Test("ボタンが画面に在って、押せる")
    func theButtonIsOnScreen() {
        let browser = loadedBrowser()
        let tintButtons = buttons(in: browser.view).filter {
            ($0.accessibilityLabel() ?? "").contains("このウインドウの色")
                || ($0.image?.accessibilityDescription ?? "").contains("このウインドウの色")
        }
        #expect(!tintButtons.isEmpty)
        guard let button = tintButtons.first else { return }
        #expect(button.action != nil)
        #expect(button.isHidden == false)
    }

    @Test("色を掛けるとボタンの絵が変わり、外すと戻る")
    func theButtonFollowsTheTint() {
        let browser = loadedBrowser()
        let tintButtons = buttons(in: browser.view).filter {
            ($0.image?.accessibilityDescription ?? "").contains("このウインドウの色")
        }
        guard let button = tintButtons.first else {
            Issue.record("色のボタンが見つからない")
            return
        }
        let none = button.toolTip
        browser.applyTint(.amber)
        let amber = button.toolTip
        browser.applyTint(nil)
        let back = button.toolTip

        #expect(none != amber)
        #expect(back == none)
        #expect(amber?.contains("琥珀") == true)
    }

    @Test("選んだ結果はペインではなく窓へ渡る")
    func selectionIsHandedToTheWindow() {
        // ペインは自分の額縁しか塗れない。ここで自分だけ塗ると、
        // タイトルバーや反対側のペインと色が食い違う。
        let browser = loadedBrowser()
        var handed: [WorkspaceWindowTint?] = []
        browser.onSelectTint = { handed.append($0) }

        let item = NSMenuItem()
        item.representedObject = WorkspaceWindowTint.moss.rawValue
        browser.perform(NSSelectorFromString("pickTint:"), with: item)
        item.representedObject = ""
        browser.perform(NSSelectorFromString("pickTint:"), with: item)

        #expect(handed.count == 2)
        #expect(handed.first == .moss)
        #expect(handed.last == WorkspaceWindowTint?.none)
    }

    @Test("色なしの絵と、色付きの絵は別のもの")
    func swatchDiffersWithAndWithoutATint() {
        let none = WorkspaceWindowTintPalette.buttonImage(for: nil)
        let tinted = WorkspaceWindowTintPalette.buttonImage(for: .teal)
        #expect(none.size == tinted.size)
        #expect(none.tiffRepresentation != tinted.tiffRepresentation)
    }
}
