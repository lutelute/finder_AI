import CoreGraphics
import FinderAICore
import Foundation
import Testing

/// 一覧では表せない「重なり」を位置で見せるための配置。束を島として格子に並べ、
/// 島の中は名前順に整列し、複数の束に属するものだけを島の境界に置く。
///
/// 力学で解いていたころのテストは「いつか止まる」「止まったら動かない」を確かめて
/// いたが、止まる場所が読める配置とは限らなかった。決定的にしたので、確かめるのは
/// 「必ず全部の名前に席がある」「同じフォルダなら同じ地図」になる。
@Suite("束を島として並べる")
struct WorkspaceClusterLayoutTests {
    private let size = CGSize(width: 875, height: 624)

    private func item(_ name: String) -> WorkspaceItem {
        WorkspaceItem(
            url: URL(fileURLWithPath: "/tmp/GitHub").appendingPathComponent(name),
            name: name,
            isDirectory: true,
            isHidden: false,
            fileSize: nil,
            modifiedAt: nil,
            typeDescription: "フォルダ"
        )
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    private func twoGroups() -> WorkspaceItemGroups {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2", "a3"] { groups.add(name, to: "A") }
        for name in ["b1", "b2", "b3"] { groups.add(name, to: "B") }
        return groups
    }

    private func layout(
        _ names: [String],
        _ groups: WorkspaceItemGroups?,
        size: CGSize? = nil
    ) -> WorkspaceClusterLayout {
        WorkspaceClusterLayout(
            groupedItems: names.map(item),
            groups: groups,
            size: size ?? self.size
        )
    }

    // MARK: - 島

    @Test("束ごとに島ができ、重ならない")
    func islandsDoNotOverlap() {
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3"], twoGroups())

        #expect(map.islands.count == 2)
        let first = try! #require(map.island(named: "A")).frame
        let second = try! #require(map.island(named: "B")).frame
        #expect(!first.intersects(second))
    }

    @Test("島は領域の中に収まる")
    func islandsStayInsideTheArea() {
        var groups = WorkspaceItemGroups()
        for index in 0..<9 { groups.add("n\(index)", to: "束\(index)") }
        let map = layout((0..<9).map { "n\($0)" }, groups)

        let bounds = CGRect(origin: .zero, size: size)
        #expect(map.islands.allSatisfy { bounds.contains($0.frame) })
    }

    /// 円周に並べていたころは、2束だと中央が大きく空き、15束だと間隔が70ptまで
    /// 詰まって束名が衝突した。格子は領域の縦横比に合わせて枡を割る。
    @Test("束の数に応じて枡の割り方が変わる")
    func gridAdaptsToCount() {
        let aspect = 875.0 / 624.0
        #expect(WorkspaceClusterLayout.gridShape(count: 1, aspect: aspect) == (1, 1))
        #expect(WorkspaceClusterLayout.gridShape(count: 2, aspect: aspect) == (2, 1))
        #expect(WorkspaceClusterLayout.gridShape(count: 6, aspect: aspect) == (3, 2))
        #expect(WorkspaceClusterLayout.gridShape(count: 15, aspect: aspect) == (5, 3))
    }

    @Test("枡はどの数でも全部の束を収められる")
    func gridAlwaysFitsEveryGroup() {
        for count in 1...40 {
            let shape = WorkspaceClusterLayout.gridShape(count: count, aspect: 1.4)
            #expect(shape.columns * shape.rows >= count, "count=\(count)")
        }
    }

    // MARK: - 島の中の整列

    /// 力学で散らしていたころは席が競合し、7項目のうち3つしか名前が出なかった。
    /// 整列なら全部に席がある — これがこの配置に変えた理由そのもの。
    @Test("島の中の点は、名前を置ける間隔で縦に並ぶ")
    func membersAreEvenlySpacedForLabels() {
        var groups = WorkspaceItemGroups()
        for name in ["gamma", "alpha", "beta", "delta", "epsilon", "zeta", "eta"] {
            groups.add(name, to: "束")
        }
        let map = layout(["gamma", "alpha", "beta", "delta", "epsilon", "zeta", "eta"], groups)

        #expect(map.nodes.count == 7)
        // 名前順に、上から下へ
        #expect(map.nodes.map(\.name) == ["alpha", "beta", "delta", "epsilon", "eta", "gamma", "zeta"])
        // どの二点も、名前が重ならない縦の間隔を保つ
        let ys = map.nodes.map(\.position.y)
        for (a, b) in zip(ys, ys.dropFirst()) {
            #expect(b - a >= WorkspaceClusterLayout.rowHeight - 0.01)
        }
        // 整列なので横位置は揃う
        #expect(Set(map.nodes.map { ($0.position.x * 100).rounded() }).count == 1)
        #expect(map.nodes.allSatisfy { $0.labelPlacement == .trailing })
    }

    @Test("島に入りきらない分は数で示す")
    func overflowIsReported() {
        var groups = WorkspaceItemGroups()
        let names = (0..<80).map { "n\(String(format: "%02d", $0))" }
        for name in names { groups.add(name, to: "束") }
        let map = layout(names, groups)

        let island = try! #require(map.island(named: "束"))
        #expect(island.overflow > 0)
        // 見せた数と「ほか」の数を足せば、必ず元の数になる。
        #expect(map.nodes.count + island.overflow == names.count)
    }

    @Test("入りきるなら「ほか」は出ない")
    func noOverflowWhenEverythingFits() {
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3"], twoGroups())

        #expect(map.islands.allSatisfy { $0.overflow == 0 })
        #expect(map.nodes.count == 6)
    }

    // MARK: - 重なり

    /// 重なりの本題。両方の島に属する項目は、その間に立つ。
    @Test("両方の束に属するものは、二つの島の間に来る")
    func sharedNodeSitsBetweenIslands() {
        var groups = twoGroups()
        groups.add("both", to: "A")
        groups.add("both", to: "B")
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3", "both"], groups)

        let a = try! #require(map.island(named: "A")).frame
        let b = try! #require(map.island(named: "B")).frame
        let both = try! #require(map.node(named: "both"))
        let centreA = CGPoint(x: a.midX, y: a.midY)
        let centreB = CGPoint(x: b.midX, y: b.midY)

        #expect(both.isShared)
        #expect(both.labelPlacement == .below)
        let separation = distance(centreA, centreB)
        #expect(distance(both.position, centreA) < separation)
        #expect(distance(both.position, centreB) < separation)
    }

    /// 同じ組み合わせの重なりが複数あると、同じ点に積もって一つにしか見えない。
    /// 境界に沿ってずらす。
    @Test("同じ組み合わせの重なりは、境界に沿って並ぶ")
    func severalSharedItemsSpreadAlongTheBorder() {
        var groups = twoGroups()
        for name in ["both1", "both2", "both3"] {
            groups.add(name, to: "A")
            groups.add(name, to: "B")
        }
        let map = layout(["a1", "b1", "both1", "both2", "both3"], groups)

        let shared = ["both1", "both2", "both3"].compactMap { map.node(named: $0) }
        #expect(shared.count == 3)
        for (a, b) in zip(shared, shared.dropFirst()) {
            #expect(distance(a.position, b.position) > 40)
        }
    }

    /// 三つ以上の束に属することもある。重心は枡の並び次第で**属していない島**の
    /// 真ん中に落ちるので、そこに置くとその島のメンバーに見えてしまう。
    @Test("三つの束に属するものが、属していない島の中に入らない")
    func tripleSharedStaysOutOfForeignIslands() {
        var groups = WorkspaceItemGroups()
        for (index, name) in ["A", "B", "C", "D", "E", "F"].enumerated() {
            groups.add("member\(index)", to: name)
        }
        // A・C・E の三つに属する。この三つは枡の上で離れている。
        for name in ["A", "C", "E"] { groups.add("triple", to: name) }

        let map = layout((0..<6).map { "member\($0)" } + ["triple"], groups)
        let triple = try! #require(map.node(named: "triple"))

        #expect(triple.groups.count == 3)
        for island in map.islands where !triple.groups.contains(island.name) {
            #expect(
                !island.frame.contains(triple.position),
                "属していない島「\(island.name)」の中に入った"
            )
        }
    }

    @Test("三つの束に属するものは、その三つ全部が橋になる")
    func tripleSharedBridgesToAll() {
        var groups = WorkspaceItemGroups()
        for name in ["A", "B", "C"] {
            groups.add("only-\(name)", to: name)
            groups.add("triple", to: name)
        }

        let map = layout(["only-A", "only-B", "only-C", "triple"], groups)

        #expect(map.bridges.count == 1)
        #expect(Set(map.nodes[map.bridges[0]].groups) == ["A", "B", "C"])
    }

    @Test("複数所属のものだけが橋として挙がる")
    func onlySharedNodesBecomeBridges() {
        var groups = twoGroups()
        groups.add("both", to: "A")
        groups.add("both", to: "B")
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3", "both"], groups)

        #expect(map.bridges.count == 1)
        let bridged = map.nodes[map.bridges[0]]
        #expect(bridged.name == "both")
        #expect(Set(bridged.groups) == ["A", "B"])
    }

    /// 一つの束にしか属さないものは、その島から出ない。出ていたら、島という
    /// 見せ方そのものが嘘になる。
    @Test("一つの束のものは、その島から出ない")
    func exclusiveMembersStayHome() {
        var groups = twoGroups()
        groups.add("both", to: "A")
        groups.add("both", to: "B")
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3", "both"], groups)

        let a = try! #require(map.island(named: "A")).frame
        for name in ["a1", "a2", "a3"] {
            let node = try! #require(map.node(named: name))
            #expect(a.contains(node.position), "\(name) が島Aから出た")
        }
    }

    // MARK: - 呼び出し側との分担

    @Test("束に属さないものは受け取らない — 呼び出し側で分けてある")
    func partitionSeparatesGroupedFromOthers() {
        var groups = WorkspaceItemGroups()
        groups.add("a1", to: "A")
        let (grouped, others) = groups.partition([item("zebra"), item("a1"), item("apple")])

        #expect(grouped.map(\.name) == ["a1"])
        // その他は名前順。探せることが目的なので並びが要る。
        #expect(others.map(\.name) == ["apple", "zebra"])
    }

    @Test("共有でつながった束が隣り合う順に並ぶ")
    func adjacentOrderPutsSharedGroupsTogether() {
        var groups = WorkspaceItemGroups()
        groups.add("x", to: "先頭")
        groups.add("y", to: "真ん中")
        groups.add("z", to: "最後")
        // 「先頭」と「最後」だけが共有する
        groups.add("shared", to: "先頭")
        groups.add("shared", to: "最後")

        let ordered = groups.adjacencyOrderedNames()

        let first = try! #require(ordered.firstIndex(of: "先頭"))
        let last = try! #require(ordered.firstIndex(of: "最後"))
        #expect(abs(first - last) == 1)
        #expect(Set(ordered) == ["先頭", "真ん中", "最後"])
    }

    // MARK: - 素性

    /// 開き直すたびに配置が変わると「前はここにあった」が通じない。
    @Test("同じフォルダは何度開いても同じ配置になる")
    func layoutIsDeterministic() {
        var groups = twoGroups()
        groups.add("both", to: "A")
        groups.add("both", to: "B")
        let names = ["a1", "a2", "a3", "b1", "b2", "b3", "both"]

        #expect(layout(names, groups) == layout(names, groups))
    }

    @Test("並びの入力順が違っても、同じ地図になる")
    func inputOrderDoesNotMatter() {
        let groups = twoGroups()
        let forward = layout(["a1", "a2", "a3", "b1", "b2", "b3"], groups)
        let shuffled = layout(["b3", "a2", "b1", "a3", "a1", "b2"], groups)

        #expect(forward.nodes.map(\.name) == shuffled.nodes.map(\.name))
        #expect(forward.nodes.map(\.position) == shuffled.nodes.map(\.position))
    }

    @Test("束がなければ島もノードも無い")
    func emptyWithoutGroups() {
        let map = layout(["loose"], nil)

        #expect(map.islands.isEmpty)
        #expect(map.nodes.isEmpty)
        #expect(map.bridges.isEmpty)
    }

    @Test("窓の大きさが変わったら、新しい領域で組み直す")
    func resizeRebuildsForTheNewArea() {
        var map = layout(["a1", "a2", "a3", "b1", "b2", "b3"], twoGroups())
        let wider = CGSize(width: 1400, height: 900)

        map.resize(to: wider)

        let bounds = CGRect(origin: .zero, size: wider)
        #expect(map.islands.count == 2)
        #expect(map.islands.allSatisfy { bounds.contains($0.frame) })
        #expect(map.nodes.count == 6)
        #expect(map.nodes.allSatisfy { bounds.contains($0.position) })
        // 組み直しても決定的。同じ大きさで作ったものと一致する。
        #expect(map.nodes.map(\.position) == layout(
            ["a1", "a2", "a3", "b1", "b2", "b3"],
            twoGroups(),
            size: wider
        ).nodes.map(\.position))
    }

    /// 狭すぎる島では一行も置けない。落ちずに、全部を「ほか」として数える。
    @Test("置く場所が無くても壊れない")
    func survivesAnImpossiblySmallArea() {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2"] { groups.add(name, to: "束") }
        let map = layout(["a1", "a2"], groups, size: CGSize(width: 60, height: 50))

        #expect(map.nodes.count + (map.island(named: "束")?.overflow ?? 0) == 2)
    }

    /// 点だけを的にすると半径10ptを狙わせることになる。島の中は行として並んで
    /// いるので、行ぜんぶ — 名前の上をクリックしても選べる。
    @Test("行のどこをクリックしても、その項目が拾える")
    func hitTestingCoversTheWholeRow() {
        var groups = WorkspaceItemGroups()
        groups.add("only", to: "A")
        let map = layout(["only"], groups)
        let node = try! #require(map.node(named: "only"))
        let island = try! #require(map.island(named: "A")).frame

        // 点の上
        #expect(map.node(at: node.position)?.name == "only")
        // 名前が並ぶあたり（点より右）
        #expect(map.node(at: CGPoint(x: node.position.x + 60, y: node.position.y))?.name == "only")
        // 行の右端近く
        #expect(map.node(
            at: CGPoint(x: island.maxX - WorkspaceClusterLayout.islandInset.width - 2, y: node.position.y)
        )?.name == "only")
        // 別の行の高さには無い
        #expect(map.node(at: CGPoint(
            x: node.position.x,
            y: node.position.y + WorkspaceClusterLayout.rowHeight * 3
        )) == nil)
    }

    @Test("島の上の点から、その島を引ける — ドロップ先の判定に使う")
    func islandHitTesting() {
        let map = layout(["a1", "b1"], twoGroups())
        let island = try! #require(map.island(named: "A")).frame

        #expect(map.island(at: CGPoint(x: island.midX, y: island.midY))?.name == "A")
        #expect(map.island(at: CGPoint(x: island.minX - 6, y: island.midY))?.name != "A")
    }
}
