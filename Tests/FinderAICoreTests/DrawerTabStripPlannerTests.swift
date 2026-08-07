import FinderAICore
import Testing

@Suite("タブ帯の詰め方")
struct DrawerTabStripPlannerTests {
    @Test("余裕があれば名前もフォルダも出す")
    func roomyStripShowsEverything() {
        let plan = DrawerTabStripPlanner.plan(tabCount: 3, availableWidth: 900)
        #expect(plan == .init(display: .full, visibleCount: 3, overflow: 0))
    }

    @Test("入り切らなくなったら、まずフォルダを落とす")
    func firstSacrificeIsTheFolderName() {
        // full(148)なら6本で912。900には入らないが、nameOnly(92)なら576で入る。
        let plan = DrawerTabStripPlanner.plan(tabCount: 6, availableWidth: 900)
        #expect(plan.display == .nameOnly)
        #expect(plan.visibleCount == 6)
        #expect(plan.overflow == 0)
    }

    @Test("それでも入らなければ、名前も落として印だけにする")
    func thenNamesGoAndIconsRemain() {
        let plan = DrawerTabStripPlanner.plan(tabCount: 20, availableWidth: 900)
        #expect(plan.display == .iconOnly)
        #expect(plan.visibleCount == 20)
        #expect(plan.overflow == 0)
    }

    @Test("印だけでも入らないぶんは、隠さず数で示す")
    func theRestBecomesACount() {
        let plan = DrawerTabStripPlanner.plan(tabCount: 60, availableWidth: 400)
        #expect(plan.display == .iconOnly)
        #expect(plan.overflow > 0)
        #expect(plan.visibleCount + plan.overflow == 60)
        // チップのぶんを空けてから並べる。詰め込んでチップが消えては、
        // 残りへ辿り着けない。
        let used = Double(plan.visibleCount) * 30
            + Double(max(0, plan.visibleCount - 1)) * 4
        #expect(used + Double(DrawerTabStripPlanner.overflowChipWidth) <= 400)
    }

    @Test("右辺は段を積んで、細くても本数を稼ぐ")
    func extraRowsBuyCapacityOnTheNarrowEdge() {
        // 右辺のパネル幅の目安300pt。1段だと印だけで8本ほど。
        let single = DrawerTabStripPlanner.plan(tabCount: 16, availableWidth: 300, rowCount: 1)
        let double = DrawerTabStripPlanner.plan(tabCount: 16, availableWidth: 300, rowCount: 2)
        #expect(single.overflow > 0)
        #expect(double.overflow == 0)
    }

    @Test("1本も無ければ何も出さない")
    func emptyStripIsEmpty() {
        let plan = DrawerTabStripPlanner.plan(tabCount: 0, availableWidth: 900)
        #expect(plan.visibleCount == 0)
        #expect(plan.overflow == 0)
    }

    @Test("どんなに狭くても、今いる1本は帯に残す")
    func theCurrentTabAlwaysSurvives() {
        // 全部を数へ送ると、今どれを見ているかが帯から消える。並びは
        // 今いる場所を先頭にしてあるので、残す1本はそれになる。
        let plan = DrawerTabStripPlanner.plan(tabCount: 5, availableWidth: 20)
        #expect(plan.visibleCount == 1)
        #expect(plan.overflow == 4)
    }

    @Test("幅が負でも破綻しない")
    func negativeWidthIsSurvivable() {
        let plan = DrawerTabStripPlanner.plan(tabCount: 3, availableWidth: -100)
        #expect(plan.visibleCount == 1)
        #expect(plan.overflow == 2)
    }
}
