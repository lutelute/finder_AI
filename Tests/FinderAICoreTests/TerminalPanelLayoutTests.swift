import CoreGraphics
import Testing
@testable import FinderAICore

@Suite("Terminal panel layout")
struct TerminalPanelLayoutTests {
    @Test("each edge keeps its own floor, ceiling, and default")
    func edgesHaveDistinctBounds() {
        #expect(TerminalPanelLayout.minimumThickness(for: .bottom) == 160)
        #expect(TerminalPanelLayout.minimumThickness(for: .right) == 280)
        #expect(TerminalPanelLayout.defaultThickness(for: .bottom) == 300)
        #expect(TerminalPanelLayout.defaultThickness(for: .right) == 420)
        #expect(TerminalPanelEdge.bottom.opposite == .right)
        #expect(TerminalPanelEdge.right.opposite == .bottom)
    }

    @Test("the browser's minimum comes off the top before anything else")
    func clampLeavesRoomForTheBrowser() {
        let thickness = TerminalPanelLayout.clamped(
            5_000,
            edge: .bottom,
            available: 760,
            browserMinimum: 220
        )
        #expect(thickness == 540)

        // 上限は辺の最大値でも頭打ちになる。
        #expect(
            TerminalPanelLayout.clamped(5_000, edge: .bottom, available: 4_000, browserMinimum: 220)
                == 600
        )
    }

    /// 両方の最小を満たせないほど狭い窓でも、レイアウトを組める数を返さなければ
    /// ならない——ここで0や負を返すと制約が壊れる。
    @Test("a window too small for both still returns the floor")
    func clampNeverReturnsNonsense() {
        #expect(
            TerminalPanelLayout.clamped(300, edge: .bottom, available: 260, browserMinimum: 220)
                == 160
        )
        #expect(
            TerminalPanelLayout.clamped(-500, edge: .right, available: 0, browserMinimum: 380)
                == 280
        )
    }

    @Test("snapping walks collapsed → half → full → collapsed")
    func snapCycleIsAWalk() {
        let available: CGFloat = 760
        let browserMinimum: CGFloat = 220
        func next(_ thickness: CGFloat, expanded: Bool = true) -> TerminalPanelLayout.Snap {
            TerminalPanelLayout.nextSnap(
                currentThickness: thickness,
                isExpanded: expanded,
                edge: .bottom,
                available: available,
                browserMinimum: browserMinimum
            )
        }

        // 畳んでいるときはまず半分まで開く。
        #expect(next(34, expanded: false) == .half)
        #expect(next(380) == .full)
        #expect(next(540) == .collapsed)
        // 手で半端な大きさにしたあとも、必ず一段大きい側へ進む。
        #expect(next(200) == .half)
    }

    @Test("half and full resolve to real sizes, collapsed to none")
    func snapThicknessResolves() {
        let half = TerminalPanelLayout.thickness(
            for: .half,
            edge: .bottom,
            available: 760,
            browserMinimum: 220
        )
        #expect(half == 380)
        let full = TerminalPanelLayout.thickness(
            for: .full,
            edge: .bottom,
            available: 760,
            browserMinimum: 220
        )
        #expect(full == 540)
        #expect(
            TerminalPanelLayout.thickness(
                for: .collapsed,
                edge: .bottom,
                available: 760,
                browserMinimum: 220
            ) == nil
        )
    }

    /// 半分と最大が同じ値に潰れるほど狭いときは、開く／畳むの2段階に縮退する。
    @Test("a narrow window degrades to open and closed")
    func snapDegradesGracefully() {
        let available: CGFloat = 620
        let browserMinimum: CGFloat = 380
        let half = TerminalPanelLayout.thickness(
            for: .half,
            edge: .right,
            available: available,
            browserMinimum: browserMinimum
        )
        let full = TerminalPanelLayout.thickness(
            for: .full,
            edge: .right,
            available: available,
            browserMinimum: browserMinimum
        )
        #expect(half == full)
        #expect(
            TerminalPanelLayout.nextSnap(
                currentThickness: half ?? 0,
                isExpanded: true,
                edge: .right,
                available: available,
                browserMinimum: browserMinimum
            ) == .collapsed
        )
    }
}
