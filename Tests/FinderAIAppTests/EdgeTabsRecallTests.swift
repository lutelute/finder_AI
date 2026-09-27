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

    @Test("縁に手を振り切ると、取っ手から離れた高さでも帯が出る。出る高さは中央付近まで")
    func flingToEdgeRecallsTheStripNearTheMiddle() throws {
        let (controller, screen) = try makeController()
        defer { controller.setEnabled(false) }
        let visible = screen.visibleFrame
        let reach = visible.height * EdgeTabPlacement.recallReach
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)
        let hidden = try #require(controller.stripFrameForTesting(on: screen))
        // 隠れているあいだは、ほぼ画面の外。
        #expect(hidden.minX < visible.minX)

        // 画面を横切るだけ（縁から40pt）では出ない。
        controller.recallHiddenStrip(at: CGPoint(x: visible.minX + 40, y: visible.maxY - 30))
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)
        // 隅はMission Controlのホットコーナーに譲る。
        controller.recallHiddenStrip(at: CGPoint(x: visible.minX + 1, y: visible.maxY - 2))
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)
        // 反対の縁では出ない。
        controller.recallHiddenStrip(at: CGPoint(x: visible.maxX - 1, y: visible.maxY - 30))
        #expect(controller.stripIsHiddenForTesting(on: screen) == true)

        // 画面の上のほうで縁に近づいても出る。ただし出る高さは中央付近で、
        // 上の端——窓のボタンを押しに行く場所——には被さらない。
        let hand = CGPoint(x: visible.minX + 20, y: visible.maxY - 30)
        controller.recallHiddenStrip(at: hand)
        #expect(controller.stripIsHiddenForTesting(on: screen) == false)
        let resting = try #require(controller.stripRestingFrameForTesting(on: screen))
        #expect(resting.minX == visible.minX)
        #expect(abs(resting.midY - (visible.midY + reach)) <= 1)
        #expect(resting.maxY < visible.maxY - visible.height / 5)
    }

    @Test("中央付近で呼び戻せば、帯は手の高さに出る")
    func recallNearTheMiddleFollowsTheHand() throws {
        let (controller, screen) = try makeController()
        defer { controller.setEnabled(false) }
        let visible = screen.visibleFrame
        let hand = CGPoint(x: visible.minX + 1, y: visible.midY - 40)
        controller.recallHiddenStrip(at: hand)
        #expect(controller.stripIsHiddenForTesting(on: screen) == false)
        let resting = try #require(controller.stripRestingFrameForTesting(on: screen))
        #expect(abs(resting.midY - hand.y) <= 1)
    }

    /// 上のほうで呼んだ帯は手から離れた高さに出る。縁に沿って帯まで手を運ぶ
    /// あいだに引っ込めると、縁にいる手がすぐまた呼び戻して出入りを繰り返す。
    @Test("縁に手を沿わせているあいだは、帯から離れていても引っ込めない")
    func stripStaysOutWhileTheHandIsAlongTheEdge() throws {
        let (controller, screen) = try makeController()
        defer { controller.setEnabled(false) }
        let visible = screen.visibleFrame
        #expect(!controller.keepsStripsOut(at: CGPoint(x: visible.minX + 1, y: visible.maxY - 30)))

        controller.recallHiddenStrip(at: CGPoint(x: visible.minX + 1, y: visible.maxY - 30))
        try #require(controller.stripIsHiddenForTesting(on: screen) == false)
        #expect(controller.keepsStripsOut(at: CGPoint(x: visible.minX + 1, y: visible.maxY - 30)))
        #expect(controller.keepsStripsOut(at: CGPoint(x: visible.minX + 20, y: visible.minY + 100)))
        // 縁から離れれば、引っ込めてよい。
        #expect(!controller.keepsStripsOut(at: CGPoint(x: visible.minX + 40, y: visible.maxY - 30)))
        #expect(!controller.keepsStripsOut(at: CGPoint(x: visible.midX, y: visible.midY)))
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
        // 縁に沿っているあいだも引っ込めないので、同じく見送る。
        guard let out = controller.stripFrameForTesting(on: screen), !out.contains(mouse),
              !controller.keepsStripsOut(at: mouse) else {
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
