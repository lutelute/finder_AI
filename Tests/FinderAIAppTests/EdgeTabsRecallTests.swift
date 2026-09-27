import AppKit
import FinderAICore
@testable import FinderAIApp
import Testing

/// 隠れた帯を、縁に手を振り切って呼び戻す。
///
/// 取っ手（4pt）へのホバーだけに頼っていた版は、取っ手がモニタの継ぎ目に来ると
/// カーソルが止まらず隣へ抜けて当たらず、「左端に当てているのに出ない」になった。
@Suite("袖の呼び戻し")
@MainActor
struct EdgeTabsRecallTests {
    private func makeController() throws -> (EdgeTabsController, NSScreen) {
        let defaults = try #require(UserDefaults(suiteName: "finderai.edge.\(UUID().uuidString)"))
        let preferences = WorkspacePreferences(defaults: defaults)
        preferences.edgeTabsEnabled = true
        preferences.edgeTabsAutoHide = true
        preferences.edgeTabsEdge = .left
        preferences.edgeTabsFollowsPointer = false
        var tabs = WorkspaceEdgeTabs()
        tabs.toggle(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        preferences.edgeTabs = tabs
        let controller = EdgeTabsController(preferences: preferences)
        let screen = try #require(NSScreen.screens.first)
        return (controller, screen)
    }

    @Test("縁に手を振り切ると、取っ手から離れた高さでも帯がカーソルの高さに出る")
    func flingToEdgeRecallsTheStripAtTheCursorHeight() throws {
        let (controller, screen) = try makeController()
        defer { controller.setEnabled(false) }
        let visible = screen.visibleFrame
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)
        let hidden = try #require(controller.stripFrameForTesting(on: screen))
        // 隠れているあいだは、ほぼ画面の外。
        #expect(hidden.minX < visible.minX)

        // 画面を横切るだけ（縁から40pt）では出ない。
        controller.recallHiddenStrip(at: CGPoint(x: visible.minX + 40, y: visible.minY + 200))
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)
        // 隅はMission Controlのホットコーナーに譲る。
        controller.recallHiddenStrip(at: CGPoint(x: visible.minX + 1, y: visible.minY + 2))
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)
        // 反対の縁では出ない。
        controller.recallHiddenStrip(at: CGPoint(x: visible.maxX - 1, y: visible.minY + 200))
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)

        // 取っ手（画面の縦中央）から遠い高さでも、縁に当てれば出る。出る高さは手の高さ。
        let hand = CGPoint(x: visible.minX + 1, y: visible.minY + 200)
        controller.recallHiddenStrip(at: hand)
        #expect(controller.stripIsHiddenForTesting(on: screen) == false)
        let resting = try #require(controller.stripRestingFrameForTesting(on: screen))
        #expect(resting.minX == visible.minX)
        #expect(abs(resting.midY - hand.y) <= 1)
    }

    @Test("呼び戻しで出た帯は、カーソルが離れていればひとりでに引っ込む")
    func recalledStripHidesAgainWhenTheCursorIsAway() async throws {
        let (controller, screen) = try makeController()
        defer { controller.setEnabled(false) }
        let visible = screen.visibleFrame
        // 実機のカーソルが帯の上に載っていると引っ込まないので、そのときは見送る。
        let mouse = NSEvent.mouseLocation
        let hand = CGPoint(x: visible.minX + 1, y: visible.minY + 200)
        controller.recallHiddenStrip(at: hand)
        try #require(controller.stripIsHiddenForTesting(on: screen) == false)
        guard let out = controller.stripFrameForTesting(on: screen), !out.contains(mouse) else {
            return
        }
        // 見張り（200ms）が離れたのを見て、猶予（400ms）のあとで引っ込める。
        // 他のスイートと同時に走るとメインアクターが混むので、上限5秒まで様子を見る。
        var hiddenAgain = false
        for _ in 0..<50 where !hiddenAgain {
            try await Task.sleep(for: .milliseconds(100))
            hiddenAgain = controller.stripIsHiddenForTesting(on: screen) == true
        }
        #expect(hiddenAgain)
    }
}
