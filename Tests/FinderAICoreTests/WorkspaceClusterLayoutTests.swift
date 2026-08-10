import CoreGraphics
import FinderAICore
import Foundation
import Testing

/// 一覧では表せない「重なり」を位置で見せるための配置。
/// 束が近くに集まること、両方に属するものが**その間**に来ることが要点。
@Suite("束を平面に散らす")
struct WorkspaceClusterLayoutTests {
    private let size = CGSize(width: 800, height: 600)

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

    private func settle(_ layout: inout WorkspaceClusterLayout, steps: Int = 600) {
        for _ in 0..<steps {
            layout.step()
            if layout.isSettled { return }
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    /// 同じ束のものが、違う束のものより近くにいる。これが成り立たなければ
    /// ただ点が散っているだけで、地図として何も言っていない。
    @Test("同じ束は近づき、違う束からは離れる")
    func groupsSeparate() {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2", "a3"] { groups.add(name, to: "A") }
        for name in ["b1", "b2", "b3"] { groups.add(name, to: "B") }
        var layout = WorkspaceClusterLayout(
            items: ["a1", "a2", "a3", "b1", "b2", "b3"].map(item),
            groups: groups,
            size: size
        )

        settle(&layout)

        let a = try! #require(layout.centroid(of: "A"))
        let b = try! #require(layout.centroid(of: "B"))
        let withinA = ["a1", "a2", "a3"].compactMap { layout.node(named: $0) }
            .map { distance($0.position, a) }.max() ?? .infinity
        #expect(withinA < distance(a, b))
    }

    /// 重なりの本題。両方の束から引かれた項目は、その間で釣り合う。
    /// 一覧では二行に分かれてしまうものが、ここでは一点として見える。
    @Test("両方の束に属するものは、二つの束の間に来る")
    func sharedNodeSitsBetween() {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2", "a3"] { groups.add(name, to: "A") }
        for name in ["b1", "b2", "b3"] { groups.add(name, to: "B") }
        groups.add("both", to: "A")
        groups.add("both", to: "B")

        var layout = WorkspaceClusterLayout(
            items: ["a1", "a2", "a3", "b1", "b2", "b3", "both"].map(item),
            groups: groups,
            size: size
        )
        settle(&layout)

        let a = try! #require(layout.centroid(of: "A"))
        let b = try! #require(layout.centroid(of: "B"))
        let both = try! #require(layout.node(named: "both"))

        // どちらの重心からも、二つの重心の間の距離より近い＝間に挟まっている。
        let separation = distance(a, b)
        #expect(distance(both.position, a) < separation)
        #expect(distance(both.position, b) < separation)
        #expect(both.isShared)
    }

    /// 開き直すたびに配置が変わると「前はここにあった」が通じない。
    @Test("同じフォルダは何度開いても同じ配置になる")
    func layoutIsDeterministic() {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2"] { groups.add(name, to: "A") }
        let items = ["a1", "a2", "loose"].map(item)

        var first = WorkspaceClusterLayout(items: items, groups: groups, size: size)
        var second = WorkspaceClusterLayout(items: items, groups: groups, size: size)
        settle(&first, steps: 120)
        settle(&second, steps: 120)

        #expect(first == second)
    }

    @Test("どのノードも画面の中に留まる")
    func nodesStayInsideBounds() {
        var groups = WorkspaceItemGroups()
        for index in 0..<24 { groups.add("n\(index)", to: "A") }
        var layout = WorkspaceClusterLayout(
            items: (0..<24).map { item("n\($0)") },
            groups: groups,
            size: size
        )

        settle(&layout)

        #expect(layout.nodes.allSatisfy {
            $0.position.x >= 0 && $0.position.x <= size.width
                && $0.position.y >= 0 && $0.position.y <= size.height
        })
    }

    /// 同じ点に重なったままだと一つにしか見えない。番号由来のずれで必ず離れる。
    @Test("同じ位置から始まっても重ならない")
    func overlappingNodesPushApart() {
        var layout = WorkspaceClusterLayout(
            items: [item("x"), item("y")],
            groups: nil,
            size: CGSize(width: 200, height: 200)
        )
        settle(&layout, steps: 200)

        let a = try! #require(layout.node(named: "x"))
        let b = try! #require(layout.node(named: "y"))
        #expect(distance(a.position, b.position) > 20)
    }

    @Test("束の無いフォルダでも、ただ散るだけで壊れない")
    func worksWithoutGroups() {
        var layout = WorkspaceClusterLayout(
            items: (0..<10).map { item("n\($0)") },
            groups: nil,
            size: size
        )
        settle(&layout, steps: 200)

        #expect(layout.nodes.count == 10)
        #expect(layout.nodes.allSatisfy { $0.groups.isEmpty })
        #expect(layout.centroid(of: "無い束") == nil)
    }

    /// 「絶えず動いている」と報告された。力の釣り合いに任せると、釣り合いの悪い
    /// 配置では速度の閾値に永久に届かない。手数の上限で必ず止める。
    @Test("いつか必ず止まる — 釣り合わない配置でも動き続けない")
    func alwaysStopsEventually() {
        var groups = WorkspaceItemGroups()
        // 全員が全員と引き合う一方で反発もする、釣り合いにくい形
        for index in 0..<40 { groups.add("n\(index)", to: "全部") }
        var layout = WorkspaceClusterLayout(
            items: (0..<40).map { item("n\($0)") },
            groups: groups,
            size: size
        )

        var steps = 0
        while !layout.isSettled, steps < 5_000 {
            layout.step()
            steps += 1
        }

        #expect(layout.isSettled)
        #expect(steps < 1_000)
    }

    /// 「なんか震えている」と報告された。止まったあとも呼ばれ続けても、
    /// 位置が動かないことを保証する。
    @Test("止まったあとは、何度呼んでも位置が動かない")
    func settledLayoutDoesNotTwitch() {
        var groups = WorkspaceItemGroups()
        for index in 0..<12 { groups.add("n\(index)", to: index < 6 ? "A" : "B") }
        var layout = WorkspaceClusterLayout(
            items: (0..<12).map { item("n\($0)") },
            groups: groups,
            size: size
        )
        settle(&layout, steps: 2_000)
        #expect(layout.isSettled)

        let frozen = layout.nodes.map(\.position)
        for _ in 0..<120 { layout.step() }

        #expect(layout.nodes.map(\.position) == frozen)
    }

    @Test("空のフォルダでも一手進められる")
    func emptyLayoutIsStable() {
        var layout = WorkspaceClusterLayout(items: [], groups: nil, size: size)
        layout.step()
        #expect(layout.nodes.isEmpty)
        #expect(layout.isSettled)
    }

    @Test("窓の大きさが変わっても、相対の位置関係は保たれる")
    func resizeKeepsRelativeLayout() {
        var groups = WorkspaceItemGroups()
        for name in ["a1", "a2"] { groups.add(name, to: "A") }
        var layout = WorkspaceClusterLayout(
            items: ["a1", "a2", "loose"].map(item),
            groups: groups,
            size: size
        )
        settle(&layout, steps: 200)
        let before = try! #require(layout.node(named: "a1"))
        let ratioX = before.position.x / size.width

        layout.resize(to: CGSize(width: 1600, height: 1200))

        let after = try! #require(layout.node(named: "a1"))
        #expect(abs(after.position.x / 1600 - ratioX) < 0.01)
    }

    @Test("その点にあるノードを拾える")
    func hitTesting() {
        var layout = WorkspaceClusterLayout(items: [item("only")], groups: nil, size: size)
        layout.step()
        let node = try! #require(layout.node(named: "only"))

        #expect(layout.node(at: node.position, radius: 14)?.name == "only")
        #expect(layout.node(
            at: CGPoint(x: node.position.x + 200, y: node.position.y),
            radius: 14
        ) == nil)
    }
}
