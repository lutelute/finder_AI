import CoreGraphics
import FinderAICore
import Foundation
import Testing

/// 一覧では表せない「重なり」を位置で見せるための配置。グループを島として格子に並べ、
/// 島の中は名前順に整列し、複数のグループに属するものだけを島の境界に置く。
///
/// 力学で解いていたころのテストは「いつか止まる」「止まったら動かない」を確かめて
/// いたが、止まる場所が読める配置とは限らなかった。決定的にしたので、確かめるのは
/// 「必ず全部の名前に席がある」「同じフォルダなら同じ地図」になる。
@Suite("グループを島として並べる")
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

    @Test("グループごとに島ができ、重ならない")
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
        for index in 0..<9 { groups.add("n\(index)", to: "グループ\(index)") }
        let map = layout((0..<9).map { "n\($0)" }, groups)

        let bounds = CGRect(origin: .zero, size: size)
        #expect(map.islands.allSatisfy { bounds.contains($0.frame) })
    }

    /// 円周に並べていたころは、2グループだと中央が大きく空き、15グループだと間隔が70ptまで
    /// 詰まってグループ名が衝突した。格子は領域の縦横比に合わせて枡を割る。
    @Test("グループの数に応じて枡の割り方が変わる")
    func gridAdaptsToCount() {
        let aspect = 875.0 / 624.0
        #expect(WorkspaceClusterLayout.gridShape(count: 1, aspect: aspect) == (1, 1))
        #expect(WorkspaceClusterLayout.gridShape(count: 2, aspect: aspect) == (2, 1))
        #expect(WorkspaceClusterLayout.gridShape(count: 6, aspect: aspect) == (3, 2))
        #expect(WorkspaceClusterLayout.gridShape(count: 15, aspect: aspect) == (5, 3))
    }

    @Test("枡はどの数でも全部のグループを収められる")
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
            groups.add(name, to: "グループ")
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

    /// 画面に配っていたころは、収まらないぶんが「ほか N」に落ちた。いまは島が
    /// 中身のぶんだけ伸び、足りないぶんは紙のほうが長くなる。
    @Test("300個あっても隠さない。紙のほうが長くなる")
    func everythingIsPlaced() {
        var groups = WorkspaceItemGroups()
        let names = (0..<300).map { "n\(String(format: "%03d", $0))" }
        for name in names { groups.add(name, to: "グループ") }
        let map = layout(names, groups)

        let island = try! #require(map.island(named: "グループ"))
        #expect(island.overflow == 0)
        #expect(map.nodes.count == names.count)
        // 見せた数と「ほか」の数を足せば、必ず元の数になる。
        #expect(map.nodes.count + island.overflow == names.count)
        // 画面より長い紙になっている。続きはスクロールで辿る。
        #expect(map.contentHeight > size.height)
    }

    /// 高さだけで数えていたころは、島が横に広くても一列しか使わず、置ける場所を
    /// 空けたまま「ほか N」と言っていた。島を全面に広げても表示数が変わらないのは
    /// これが理由で、「広げる」が何も広げていなかった。
    @Test("一列に入りきらないときは、余っている幅を列にして使う")
    func wideIslandsUseColumns() {
        var groups = WorkspaceItemGroups()
        let names = (0..<80).map { "n\(String(format: "%02d", $0))" }
        for name in names { groups.add(name, to: "グループ") }
        let map = layout(names, groups)

        let island = try! #require(map.island(named: "グループ"))
        #expect(island.overflow == 0)
        #expect(map.nodes.count == names.count)
        // 列に割れている＝横位置が一つではない。
        let columns = Set(map.nodes.map { ($0.position.x * 100).rounded() })
        #expect(columns.count > 1)
        // 列は名前の読める幅を保つ。狭い列を並べても意味がない。
        let xs = columns.map { $0 / 100 }.sorted()
        for (left, right) in zip(xs, xs.dropFirst()) {
            #expect(right - left >= WorkspaceClusterLayout.minColumnWidth - 0.01)
        }
        // 縦に読んでから隣の列へ。名前順が列の中で保たれる。
        #expect(map.nodes.prefix(2).map(\.name) == ["n00", "n01"])
    }

    /// 中身の量で場所を配ると、少ない束が痩せて消える。実測では2個しか入っていない
    /// 束が31ptになり、名前の帯すら入らず中身が一つも出なかった。
    @Test("中身の多い束と並んでも、少ない束は消えない")
    func smallIslandsKeepTheirContents() {
        var groups = WorkspaceItemGroups()
        let many = (0..<40).map { "m\(String(format: "%02d", $0))" }
        for name in many { groups.add(name, to: "多い") }
        for name in ["s1", "s2"] { groups.add(name, to: "少ない") }
        let map = layout(many + ["s1", "s2"], groups, size: CGSize(width: 420, height: 320))

        let small = try! #require(map.island(named: "少ない"))
        #expect(small.overflow == 0)
        #expect(map.nodes.filter { $0.groups.contains("少ない") }.count == 2)
        #expect(small.frame.height >= WorkspaceClusterLayout.minIslandHeight)
        // 多いほうも隠さない。中身のぶんだけ縦に伸びる。
        let big = try! #require(map.island(named: "多い"))
        #expect(big.overflow == 0)
        #expect(map.nodes.filter { $0.groups.contains("多い") }.count == many.count)
        #expect(big.frame.height > small.frame.height)
    }

    /// 縦に積むときは、中身の多い束のほうが高くなる。均等に割ると、8個入った島と
    /// 2個の島が同じ高さになり、多いほうだけが「ほか N」で隠れた。
    @Test("縦に並ぶときは、中身の多い束に高さを多く配る")
    func tallerIslandsForFullerGroups() {
        var groups = WorkspaceItemGroups()
        for name in (0..<12).map({ "m\($0)" }) { groups.add(name, to: "多い") }
        for name in ["s1", "s2"] { groups.add(name, to: "少ない") }
        // 狭い幅では縦一列に積む（横に割ると名前が読めなくなるため）。
        let map = layout((0..<12).map { "m\($0)" } + ["s1", "s2"], groups, size: CGSize(width: 240, height: 520))

        let big = try! #require(map.island(named: "多い"))
        let small = try! #require(map.island(named: "少ない"))
        #expect(big.frame.height > small.frame.height)
        #expect(small.frame.height >= WorkspaceClusterLayout.minIslandHeight)
    }

    /// 「子の場所を残すため親は四割まで」と決め打っていたので、子が小さくても
    /// 親の直下が頭打ちになり、空いているのに親のメンバーが「ほか N」に落ちた。
    @Test("子が小さければ、親は直下のメンバーに場所を使える")
    func parentTakesTheRoomItsChildrenDoNotNeed() {
        var groups = WorkspaceItemGroups()
        let mine = (0..<10).map { "p\($0)" }
        for name in mine { groups.add(name, to: "親") }
        groups.add("c1", to: "子")
        groups.nest("子", inside: "親")
        let map = layout(mine + ["c1"], groups, size: CGSize(width: 420, height: 560))

        let parent = try! #require(map.island(named: "親"))
        #expect(parent.overflow == 0)
        #expect(map.nodes.filter { $0.groups.contains("親") }.count == 10)
        // 子も潰れない。
        let child = try! #require(map.island(named: "子"))
        #expect(child.overflow == 0)
        #expect(parent.frame.contains(child.frame))
        #expect(!parent.contentFrame.intersects(child.frame))
    }

    @Test("入りきるなら「ほか」は出ない")
    func noOverflowWhenEverythingFits() {
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3"], twoGroups())

        #expect(map.islands.allSatisfy { $0.overflow == 0 })
        #expect(map.nodes.count == 6)
    }

    // MARK: - 入れ子（A ∈ B を島の入れ子で見せる）

    /// 親子が同列に並んでいると、それは嘘になる。子の枠は親の枠の**内側**に入る。
    @Test("子の島は親の島の中に収まる")
    func childIslandSitsInsideItsParent() {
        var groups = WorkspaceItemGroups()
        groups.add("x", to: "研究")
        groups.add("y", to: "電力系統")
        groups.nest("電力系統", inside: "研究")
        let map = layout(["x", "y"], groups)

        let parent = try! #require(map.island(named: "研究"))
        let child = try! #require(map.island(named: "電力系統"))

        #expect(parent.depth == 0)
        #expect(child.depth == 1)
        #expect(parent.frame.contains(child.frame))
        // 親のメンバーを置く場所は、子の枠と重ならない
        #expect(!parent.contentFrame.intersects(child.frame))
    }

    @Test("同じ親の子どもは、互いに重ならない")
    func siblingsDoNotOverlap() {
        var groups = WorkspaceItemGroups()
        for name in ["研究", "電力系統", "可視化"] { groups.add("x-\(name)", to: name) }
        groups.nest("電力系統", inside: "研究")
        groups.nest("可視化", inside: "研究")
        let map = layout(["x-研究", "x-電力系統", "x-可視化"], groups)

        let a = try! #require(map.island(named: "電力系統")).frame
        let b = try! #require(map.island(named: "可視化")).frame
        #expect(!a.intersects(b))
    }

    /// 親の枠は子を含むので、点で島を引くときは内側から返す必要がある。
    /// そうでないと、子に落としたつもりが親に入る。
    @Test("島を点で引くと、いちばん内側の島が返る")
    func islandHitTestPrefersTheInnermost() {
        var groups = WorkspaceItemGroups()
        groups.add("x", to: "研究")
        groups.add("y", to: "電力系統")
        groups.nest("電力系統", inside: "研究")
        let map = layout(["x", "y"], groups)

        let child = try! #require(map.island(named: "電力系統")).frame
        let hit = map.island(at: CGPoint(x: child.midX, y: child.midY))
        #expect(hit?.name == "電力系統")
    }

    @Test("入れ子が無ければ、今までどおり平らな格子になる")
    func flatDefinitionKeepsTheOldLayout() {
        let map = layout(["a1", "b1"], twoGroups())

        #expect(map.islands.allSatisfy { $0.depth == 0 })
        #expect(map.islands.allSatisfy { $0.frame == $0.contentFrame })
    }

    // MARK: - 重なり

    /// 重なりの本題。
    ///
    /// 島のあいだに**点**として置いていたが、島が中身のぶんだけ縦に伸びるように
    /// なってから破綻した — 置き場所が細い線しかなく、件数が増えると島の外へ
    /// 長くぶら下がり、橋が束になって交差した。重なりは**面**として置く。
    /// 「AとBの両方」という枠を作り、その中に行として並べる。行が増えるだけなので
    /// 何件でも伸びていける。
    @Test("両方に属するものは「A × B」の枠に集まる")
    func sharedItemsGetTheirOwnBox() throws {
        var groups = twoGroups()
        groups.add("both", to: "A")
        groups.add("both", to: "B")
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3", "both"], groups)

        let box = try #require(
            map.islands.first { $0.overlapOf != nil },
            "交わりの枠が無い"
        )
        #expect(box.overlapOf == ["A", "B"])

        let both = try #require(map.node(named: "both"))
        #expect(both.isShared)
        // 行として並ぶので、名前は点の右（島の中と同じ読み方）。
        #expect(both.labelPlacement == .trailing)
        #expect(box.frame.contains(both.position), "自分の枠の中に居る")
        // 元の束の島には入らない。入ると、その束だけのものに見える。
        for island in map.islands where island.overlapOf == nil {
            #expect(!island.frame.contains(both.position), "「\(island.name)」の中に入った")
        }
    }

    /// 件数が増えても崩れないこと。**これが点で置けなくなった理由**。
    @Test("重なりが何件あっても、枠の中に行として収まる")
    func manySharedItemsStayInTheBox() throws {
        var groups = twoGroups()
        var names = ["a1", "a2", "a3", "b1", "b2", "b3"]
        for index in 1...12 {
            let name = "both\(index)"
            names.append(name)
            groups.add(name, to: "A")
            groups.add(name, to: "B")
        }
        let map = layout(names, groups)

        let box = try #require(map.islands.first { $0.overlapOf == ["A", "B"] })
        for index in 1...12 {
            let node = try #require(map.node(named: "both\(index)"))
            #expect(box.frame.contains(node.position), "both\(index) が枠から出ている")
        }
        #expect(box.overflow == 0, "「ほか N」に落ちたものがある")
    }

    /// 三つ以上の交わりも同じ。二つの交わりとは別の枠になる。
    @Test("三つに属するものは「A × B × C」の枠に入る。二つの交わりとは別の枠")
    func tripleSharedGetsItsOwnBox() throws {
        var groups = WorkspaceItemGroups()
        for name in ["A", "B", "C"] {
            groups.add("only-\(name)", to: name)
            groups.add("triple", to: name)
        }
        groups.add("pair", to: "A")
        groups.add("pair", to: "B")

        let map = layout(["only-A", "only-B", "only-C", "triple", "pair"], groups)

        let boxes = map.islands.compactMap(\.overlapOf)
        #expect(boxes.contains(["A", "B", "C"]))
        #expect(boxes.contains(["A", "B"]))
        #expect(boxes.count == 2, "組み合わせごとに一つの枠: \(boxes)")

        let triple = try #require(map.node(named: "triple"))
        #expect(Set(triple.groups) == ["A", "B", "C"])
        let tripleBox = try #require(map.islands.first { $0.overlapOf == ["A", "B", "C"] })
        #expect(tripleBox.frame.contains(triple.position))
    }

    /// 重なりを枠にしたので、点から島へ橋を引く必要がなくなった。
    /// 点ごとに引いていたころは、件数のぶんだけ線が束になって交差した。
    @Test("橋は引かない。重なりは枠として在る")
    func noBridgesAnyMore() {
        var groups = twoGroups()
        for index in 1...5 {
            groups.add("both\(index)", to: "A")
            groups.add("both\(index)", to: "B")
        }
        let map = layout(
            ["a1", "b1"] + (1...5).map { "both\($0)" },
            groups
        )
        #expect(map.bridges.isEmpty)
        #expect(map.islands.contains { $0.overlapOf == ["A", "B"] })
    }

    /// 一つのグループにしか属さないものは、その島から出ない。出ていたら、島という
    /// 見せ方そのものが嘘になる。
    @Test("一つのグループのものは、その島から出ない")
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

    @Test("グループに属さないものは受け取らない — 呼び出し側で分けてある")
    func partitionSeparatesGroupedFromOthers() {
        var groups = WorkspaceItemGroups()
        groups.add("a1", to: "A")
        let (grouped, others) = groups.partition([item("zebra"), item("a1"), item("apple")])

        #expect(grouped.map(\.name) == ["a1"])
        // その他は名前順。探せることが目的なので並びが要る。
        #expect(others.map(\.name) == ["apple", "zebra"])
    }

    @Test("共有でつながったグループが隣り合う順に並ぶ")
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

    // MARK: - 矢印キーの行き先

    /// 島の中は縦に並んでいるので、上下は素直に前後の行になる。
    @Test("下は次の行、上は前の行")
    func verticalMovesBetweenRows() {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2", "a3"] { groups.add(name, to: "A") }
        let map = layout(["a1", "a2", "a3"], groups)

        #expect(map.node(from: "a1", towards: .down)?.name == "a2")
        #expect(map.node(from: "a2", towards: .down)?.name == "a3")
        #expect(map.node(from: "a3", towards: .up)?.name == "a2")
    }

    @Test("島の端では、その向きに何も無い")
    func verticalStopsAtTheEdge() {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2"] { groups.add(name, to: "A") }
        let map = layout(["a1", "a2"], groups)

        #expect(map.node(from: "a1", towards: .up) == nil)
        #expect(map.node(from: "a2", towards: .down) == nil)
    }

    /// 配列の前後で動かすと、島をまたぐ瞬間に画面の反対側へ飛ぶ（`nodes`は島ごとに
    /// 並び、島の並びは蛇行しているため）。位置で決めれば見えている通りに動く。
    @Test("右へ動くと、右にある島のものへ移る")
    func horizontalCrossesToTheNeighbourIsland() {
        let groups = twoGroups()
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3"], groups)

        let a = try! #require(map.island(named: "A")).frame
        let b = try! #require(map.island(named: "B")).frame
        // 2グループなら横に並ぶ（A が左、B が右）
        #expect(a.midX < b.midX)

        let moved = try! #require(map.node(from: "a1", towards: .right))
        #expect(moved.groups == ["B"])
    }

    @Test("何も選んでいなければ、先頭が行き先になる")
    func movingWithoutSelectionStartsAtTheFirst() {
        let groups = twoGroups()
        let map = layout(["a1", "a2", "b1"], groups)

        // 知らない名前から動かそうとしたときも、止まらずに先頭を返す
        #expect(map.node(from: "居ない", towards: .down)?.name == map.nodes.first?.name)
    }

    /// 境界に立つ点は島の中の行と横位置がずれている。真上・真下だけを見ると
    /// そこから島へ戻れなくなるので、進む距離に応じて横のずれを許す。
    @Test("境界に立つ点からも、島の中へ戻れる")
    func canReturnFromTheBoundary() {
        var groups = twoGroups()
        groups.add("both", to: "A")
        groups.add("both", to: "B")
        let map = layout(["a1", "a2", "a3", "b1", "b2", "b3", "both"], groups)

        let up = map.node(from: "both", towards: .up)
        let left = map.node(from: "both", towards: .left)
        let right = map.node(from: "both", towards: .right)
        // どの向きかは配置次第だが、どこへも行けないのは行き止まりなので困る
        #expect(up != nil || left != nil || right != nil)
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

    @Test("グループがなければ島もノードも無い")
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
        for name in ["a1", "a2"] { groups.add(name, to: "グループ") }
        let map = layout(["a1", "a2"], groups, size: CGSize(width: 60, height: 50))

        #expect(map.nodes.count + (map.island(named: "グループ")?.overflow ?? 0) == 2)
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

    /// 伸びる高さに上限を置いていたころは、そこを超えたぶんが「ほか N」に落ちて
    /// いた。しかも**打ち切ったことが分からない**ので、なぜここだけ隠れているのか
    /// 読めなかった。いまは上限を置かず、伸びたぶんはスクロールに任せる。
    @Test("項目が数千あっても、隠さずに紙が伸びる")
    func nothingIsTruncatedAtScale() {
        for (count, size) in [
            (3000, CGSize(width: 1600, height: 900)),
            // 狭い窓でも同じ。窓の大きさで隠す量が変わってはいけない。
            (3000, CGSize(width: 300, height: 200))
        ] {
            var groups = WorkspaceItemGroups()
            let names = (1...count).map { "項目\($0)" }
            for (index, name) in names.enumerated() { groups.add(name, to: "束\(index % 3)") }
            let map = layout(names, groups, size: size)

            #expect(map.nodes.count == count, "\(size)で \(map.nodes.count)/\(count)")
            #expect(map.islands.allSatisfy { $0.overflow == 0 }, "「ほか N」に落ちたものがある")
            #expect(map.contentHeight > size.height, "収めるために紙が伸びている")
        }
    }

    @Test("島の上の点から、その島を引ける — ドロップ先の判定に使う")
    func islandHitTesting() {
        let map = layout(["a1", "b1"], twoGroups())
        let island = try! #require(map.island(named: "A")).frame

        #expect(map.island(at: CGPoint(x: island.midX, y: island.midY))?.name == "A")
        #expect(map.island(at: CGPoint(x: island.minX - 6, y: island.midY))?.name != "A")
    }
}

/// 島は畳める。畳んだら名前を出さず、数だけを一行で出す。
///
/// 「地図は重なり専用と割り切って島は概要だけにする」案もあったが、そうすると
/// 島へ引いて入れるときに何が入っているか見えない。既定は開いたままにして、
/// 畳みたい人が畳む形にした。
@Suite("島を畳む")
struct WorkspaceCollapsedIslandTests {
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

    private func fixture() -> (names: [String], groups: WorkspaceItemGroups) {
        var groups = WorkspaceItemGroups()
        var names: [String] = []
        for index in 1...20 {
            let name = "a\(index)"
            names.append(name)
            groups.add(name, to: "A")
        }
        for index in 1...3 {
            let name = "b\(index)"
            names.append(name)
            groups.add(name, to: "B")
        }
        for index in 1...4 {
            let name = "c\(index)"
            names.append(name)
            groups.add(name, to: "子")
        }
        // 束を作ってから入れ子にする。順が逆だと`nest`は空振りして最上位のまま。
        let nested = groups.nest("子", inside: "A")
        #expect(nested)
        return (names, groups)
    }

    private func layout(collapsed: Set<String>) -> WorkspaceClusterLayout {
        let fixture = fixture()
        return WorkspaceClusterLayout(
            groupedItems: fixture.names.map(item),
            groups: fixture.groups,
            size: CGSize(width: 875, height: 624),
            collapsedGroups: collapsed
        )
    }

    @Test("畳むと、その島の行は消えて高さも縮む")
    func collapsingHidesTheRows() throws {
        let open = layout(collapsed: [])
        let folded = layout(collapsed: ["A"])

        let openA = try #require(open.island(named: "A"))
        let foldedA = try #require(folded.island(named: "A"))
        #expect(foldedA.isCollapsed)
        #expect(!openA.isCollapsed)
        #expect(foldedA.frame.height < openA.frame.height, "畳んでも高さが変わっていない")
        #expect(foldedA.frame.height <= WorkspaceClusterLayout.minIslandHeight + 1)

        #expect(open.nodes.contains { $0.groups == ["A"] })
        #expect(!folded.nodes.contains { $0.groups == ["A"] }, "畳んだ島の行が残っている")
        // 畳んでいない束はそのまま。
        #expect(folded.nodes.filter { $0.groups == ["B"] }.count == 3)
    }

    /// 中身を出さないのに子だけ出ていたら、何を畳んだのか分からない。
    @Test("親を畳むと、子の島も連れて畳まれる")
    func collapsingTakesChildrenAlong() {
        let folded = layout(collapsed: ["A"])
        #expect(folded.island(named: "子") == nil, "子の島が残っている")
        #expect(!folded.nodes.contains { $0.groups == ["子"] })
    }

    @Test("畳めば、ほかの島に場所が回る")
    func foldingGivesRoomToTheRest() throws {
        let open = try #require(layout(collapsed: []).island(named: "B"))
        let folded = try #require(layout(collapsed: ["A"]).island(named: "B"))
        #expect(folded.frame.height >= open.frame.height)
    }
}
