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

    @Test("それでも入らなければ、記号と2文字まで詰める")
    func thenNamesShrinkToTwoLetters() {
        // compact(48)なら900に17本まで。名前を出す余地は無いが、
        // 2文字は残るので場所の頭で見分けられる。
        let plan = DrawerTabStripPlanner.plan(tabCount: 17, availableWidth: 900)
        #expect(plan.display == .compact)
        #expect(plan.visibleCount == 17)
        #expect(plan.overflow == 0)
    }

    @Test("印だけでも入らないぶんは、隠さず数で示す")
    func theRestBecomesACount() {
        let plan = DrawerTabStripPlanner.plan(tabCount: 60, availableWidth: 400)
        #expect(plan.display == .compact)
        #expect(plan.overflow > 0)
        #expect(plan.visibleCount + plan.overflow == 60)
        // チップのぶんを空けてから並べる。詰め込んでチップが消えては、
        // 残りへ辿り着けない。
        let used = Double(plan.visibleCount) * 30
            + Double(max(0, plan.visibleCount - 1)) * 4
        #expect(used + Double(DrawerTabStripPlanner.overflowChipWidth) <= 400)
    }

    @Test("段を積めば本数を稼げる")
    func extraRowsBuyCapacity() {
        // 右辺のパネル幅の目安400pt。1段では詰めても7本ほど。
        let single = DrawerTabStripPlanner.plan(tabCount: 12, availableWidth: 400, rowCount: 1)
        let double = DrawerTabStripPlanner.plan(tabCount: 12, availableWidth: 400, rowCount: 2)
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
