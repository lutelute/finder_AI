import AppKit
import FinderAICore
@testable import FinderAIApp
import Testing

/// 地図の「ほか N を開く →」から、その束を広げて戻るまで。
///
/// クリックを合成してGUIごと確かめる手もあるが、それは使っている人のマウスを
/// 奪うことになる。押す場所は描画のときに決まるので、**実際に描いてから**
/// その場所へクリックを渡す — 経路は本物と同じで、奪うものが無い。
@Suite("地図でグループを広げる")
@MainActor
struct WorkspaceGroupMapInteractionTests {
    /// 島に入りきらない数のメンバーを持つ束と、枡を割るためのもう一つの束。
    private static func fixture(
        members: Int = 20
    ) -> (items: [WorkspaceItem], groups: WorkspaceItemGroups) {
        let root = URL(fileURLWithPath: "/tmp/finderai-map-test", isDirectory: true)
        func item(_ name: String) -> WorkspaceItem {
            WorkspaceItem(
                url: root.appendingPathComponent(name),
                name: name,
                isDirectory: true,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                typeDescription: "フォルダ"
            )
        }
        var groups = WorkspaceItemGroups()
        var items: [WorkspaceItem] = []
        for index in 1...members {
            let name = "大きい束の\(index)"
            items.append(item(name))
            groups.add(name, to: "大きい束")
        }
        for index in 1...2 {
            let name = "小さい束の\(index)"
            items.append(item(name))
            groups.add(name, to: "小さい束")
        }
        return (items, groups)
    }

    /// 描かないと的が決まらない。窓に入れて一度描かせる。
    private static func render(_ view: WorkspaceMapView) {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.renderForTesting()
    }

    private static func click(_ view: WorkspaceMapView, at point: NSPoint, clickCount: Int = 1) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )
        view.handleMapClick(at: point, event: event ?? NSEvent())
        render(view)
    }

    @Test("入りきらなくても隠さない。紙のほうが伸びて全部出る")
    func everythingIsVisible() throws {
        _ = NSApplication.shared
        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 700, height: 320))
        let fixture = Self.fixture()
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        Self.render(view)

        // 20個は320ptの窓には入らない。以前はここで「ほか N」に落としていた。
        #expect(view.visibleNodeCountForTesting(inGroup: "大きい束") == 20)
        #expect(view.visibleNodeCountForTesting(inGroup: "小さい束") == 2)
        #expect(view.overflowHitRectsForTesting.isEmpty)
        // 収めるために紙が伸びている。続きはスクロールで辿る。
        #expect(view.mapContentHeightForTesting > 320)
    }

    @Test("島の名前を二度押すと、その束だけが地図いっぱいになる")
    func doubleClickOnTitleFocuses() throws {
        _ = NSApplication.shared
        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 700, height: 320))
        let fixture = Self.fixture()
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        Self.render(view)
        #expect(view.focusedGroupForTesting == nil)
        #expect(view.focusBackHitRectForTesting == nil)

        let title = try #require(view.islandTitlePointForTesting(named: "大きい束"))
        Self.click(view, at: title, clickCount: 2)

        #expect(view.focusedGroupForTesting == "大きい束")
        // 広げているあいだ、ほかの束は退く。
        #expect(view.visibleNodeCountForTesting(inGroup: "小さい束") == 0)
        // 戻り道が出ていること。出ていないと、広げたきり戻れない。
        #expect(view.focusBackHitRectForTesting != nil)
    }

    @Test("「← すべての島に戻る」を押すと元の地図に戻る")
    func backReturnsToAllIslands() throws {
        _ = NSApplication.shared
        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 700, height: 320))
        let fixture = Self.fixture()
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        Self.render(view)
        let title = try #require(view.islandTitlePointForTesting(named: "大きい束"))
        Self.click(view, at: title, clickCount: 2)

        let back = try #require(view.focusBackHitRectForTesting)
        Self.click(view, at: NSPoint(x: back.midX, y: back.midY))

        #expect(view.focusedGroupForTesting == nil)
        #expect(view.visibleNodeCountForTesting(inGroup: "小さい束") == 2)
    }

    @Test("escでも戻る。広げていないときは何も起きない")
    func escapeClosesOnlyWhenOpen() throws {
        _ = NSApplication.shared
        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 700, height: 320))
        let fixture = Self.fixture()
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        Self.render(view)

        // 広げていないときに握ってしまうと、escで消したい他のもの（選択や検索）が
        // 消えなくなる。
        #expect(view.closeFocusIfNeeded() == false)

        let title = try #require(view.islandTitlePointForTesting(named: "大きい束"))
        Self.click(view, at: title, clickCount: 2)
        #expect(view.closeFocusIfNeeded() == true)
        #expect(view.focusedGroupForTesting == nil)
    }

    @Test("フォルダを見直したら、広げるのはやめる")
    func showResetsFocus() throws {
        _ = NSApplication.shared
        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 700, height: 320))
        let fixture = Self.fixture()
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        Self.render(view)
        let title = try #require(view.islandTitlePointForTesting(named: "大きい束"))
        Self.click(view, at: title, clickCount: 2)
        #expect(view.focusedGroupForTesting == "大きい束")

        // 別のフォルダを開いたのと同じこと。同じ名前の束が隣のフォルダにもあると、
        // 開いた覚えのない島が広がったまま出てしまう。
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        Self.render(view)
        #expect(view.focusedGroupForTesting == nil)
    }
}

/// 地図の点を掴んで、別の島へ張り替える。
@Suite("地図で点を掴んで張り替える")
@MainActor
struct WorkspaceMapRegroupTests {
    private static func fixture() -> (items: [WorkspaceItem], groups: WorkspaceItemGroups) {
        let root = URL(fileURLWithPath: "/tmp/finderai-regroup-test", isDirectory: true)
        func item(_ name: String) -> WorkspaceItem {
            WorkspaceItem(
                url: root.appendingPathComponent(name),
                name: name,
                isDirectory: true,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                typeDescription: "フォルダ"
            )
        }
        var groups = WorkspaceItemGroups()
        groups.add("あ", to: "束A")
        groups.add("い", to: "束A")
        groups.add("う", to: "束B")
        return ([item("あ"), item("い"), item("う")], groups)
    }

    private static func mapView() -> WorkspaceMapView {
        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let fixture = Self.fixture()
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.renderForTesting()
        return view
    }

    private static func pasteboard(for name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("finderai-test-\(name)"))
        board.clearContents()
        let url = URL(fileURLWithPath: "/tmp/finderai-regroup-test", isDirectory: true)
            .appendingPathComponent(name)
        if let writer = WorkspaceDragDrop.pasteboardWriter(for: url) {
            board.writeObjects([writer])
        }
        return board
    }

    @Test("島の中の点は掴める。どの島から出たかも分かる")
    func nodesAreGrabbable() throws {
        _ = NSApplication.shared
        let view = Self.mapView()
        let node = try #require(view.nodePositionForTesting(named: "あ"))
        #expect(view.nodeIsGrabbable(at: node))
        let payload = try #require(view.dragPayload(at: node))
        #expect(payload.items.map(\.name) == ["あ"])
        #expect(payload.from == "束A")
        // 何も無いところは掴めない。掴めると、地図の余白を撫でただけで物が動く。
        #expect(!view.nodeIsGrabbable(at: CGPoint(x: 2, y: 2)))
    }

    @Test("別の島に落とすと、掴んだ島から外れて落とした島に入る")
    func draggingBetweenIslandsMoves() throws {
        _ = NSApplication.shared
        let view = Self.mapView()
        var moved: (urls: [URL], from: String, to: String)?
        var linked: (urls: [URL], to: String)?
        view.onMoveBetweenGroups = { urls, from, to in
            moved = (urls, from, to)
            return true
        }
        view.onLinkToGroup = { urls, to in
            linked = (urls, to)
            return true
        }

        let from = try #require(view.nodePositionForTesting(named: "あ"))
        let into = try #require(view.islandCentreForTesting(named: "束B"))
        view.grabForTesting(at: from)
        #expect(view.performMapDrop(at: into, pasteboard: Self.pasteboard(for: "あ")))

        let move = try #require(moved)
        #expect(move.from == "束A")
        #expect(move.to == "束B")
        #expect(move.urls.map(\.lastPathComponent) == ["あ"])
        // 張り替えなので、ただ入れるほうは呼ばれない（両方呼ぶと二重に効く）。
        #expect(linked == nil)
    }

    @Test("島の外から引いてきたものは、外さずに入れるだけ")
    func draggingFromOutsideOnlyLinks() throws {
        _ = NSApplication.shared
        let view = Self.mapView()
        var moved = false
        var linkedTo: String?
        view.onMoveBetweenGroups = { _, _, _ in moved = true; return true }
        view.onLinkToGroup = { _, to in linkedTo = to; return true }

        // 右の一覧から引いてきた場合。掴んだ島が無い。
        let into = try #require(view.islandCentreForTesting(named: "束B"))
        #expect(view.performMapDrop(at: into, pasteboard: Self.pasteboard(for: "う")))
        #expect(!moved)
        #expect(linkedTo == "束B")
    }
}


/// 紙は中身のぶんだけ伸びる。伸びた先で「いまどの島に居るか」が読めないと、
/// 全部出ていても探せない。
@Suite("長い地図でも、いまどの島に居るか読める")
@MainActor
struct WorkspaceMapStickyTitleTests {
    @Test("上端が画面の外へ出たら、島の名前は見えている上端に留まる")
    func titleSticksWhileScrolling() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/finderai-sticky-test", isDirectory: true)
        var groups = WorkspaceItemGroups()
        var items: [WorkspaceItem] = []
        for index in 1...120 {
            let name = "項目\(index)"
            items.append(WorkspaceItem(
                url: root.appendingPathComponent(name),
                name: name,
                isDirectory: true,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                typeDescription: "フォルダ"
            ))
            groups.add(name, to: "大きい束")
        }

        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        view.show(items: items, groups: groups, presentNames: Set(items.map(\.name)))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.renderForTesting()

        let frame = try #require(view.islandFrameForTesting(named: "大きい束"))
        // 紙が窓より長いこと。長くなければ留める必要も無く、この検査は何も見ていない。
        #expect(view.mapContentHeightForTesting > 300)
        #expect(frame.height > 300, "島そのものが画面より高いこと")

        let atTop = try #require(view.islandTitlePointForTesting(named: "大きい束"))
        #expect(abs(atTop.y - (frame.minY + 6)) < 20, "スクロールしていなければ島の上端")

        view.scrollForTesting(toY: 200)
        let visible = view.visibleMapRectForTesting
        #expect(visible.minY > frame.minY, "島の上端は画面の外へ出た")
        let stuck = try #require(view.islandTitlePointForTesting(named: "大きい束"))
        #expect(stuck.y > atTop.y, "名前は下へ移った（＝紙と一緒に流れていない）")
        #expect(
            abs(stuck.y - (visible.minY + 6)) < 20,
            "見えている上端に留まる: 名前 \(stuck.y) / 上端 \(visible.minY)"
        )
        // 島より下へは行かない（次の島に被って嘘になる）。
        #expect(stuck.y < frame.maxY)
    }
}

/// 深い入れ子では、降りていく手が要る。子を広げるのが「入れ替え」だと、
/// 一段目から先へ進めない。
@Suite("広げた島の中から、さらに子へ降りる")
@MainActor
struct WorkspaceMapNestedFocusTests {
    /// 研究 ∋ 電力系統 ∋ 潮流計算。それぞれに中身がある。
    private static func fixture() -> (items: [WorkspaceItem], groups: WorkspaceItemGroups) {
        let root = URL(fileURLWithPath: "/tmp/finderai-nested-test", isDirectory: true)
        func item(_ name: String) -> WorkspaceItem {
            WorkspaceItem(
                url: root.appendingPathComponent(name),
                name: name,
                isDirectory: true,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                typeDescription: "フォルダ"
            )
        }
        var groups = WorkspaceItemGroups()
        var items: [WorkspaceItem] = []
        for (group, count) in [("研究", 3), ("電力系統", 3), ("潮流計算", 3), ("別の束", 2)] {
            for index in 1...count {
                let name = "\(group)の\(index)"
                items.append(item(name))
                groups.add(name, to: group)
            }
        }
        groups.nest("電力系統", inside: "研究")
        groups.nest("潮流計算", inside: "電力系統")
        return (items, groups)
    }

    private static func make() -> WorkspaceMapView {
        _ = NSApplication.shared
        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let fixture = Self.fixture()
        view.show(
            items: fixture.items,
            groups: fixture.groups,
            presentNames: Set(fixture.items.map(\.name))
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.renderForTesting()
        return view
    }

    private static func doubleClickTitle(_ view: WorkspaceMapView, of name: String) throws {
        let point = try #require(
            view.islandTitlePointForTesting(named: name),
            "「\(name)」の島が地図に出ていない"
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        view.handleMapClick(at: point, event: event)
        view.renderForTesting()
    }

    @Test("子の名前を叩くと、入れ替わらずに降りる")
    func drillsDownIntoChildren() throws {
        let view = Self.make()
        try Self.doubleClickTitle(view, of: "研究")
        #expect(view.focusPathForTesting == ["研究"])

        // 広げているあいだも子の島は連れてきている。そこをさらに叩く。
        try Self.doubleClickTitle(view, of: "電力系統")
        #expect(view.focusPathForTesting == ["研究", "電力系統"], "入れ替えではなく積む")

        try Self.doubleClickTitle(view, of: "潮流計算")
        #expect(view.focusPathForTesting == ["研究", "電力系統", "潮流計算"])
        #expect(view.focusedGroupForTesting == "潮流計算")
    }

    @Test("戻り道は一段ずつ。降りた道をそのまま辿れる")
    func backGoesOneStep() throws {
        let view = Self.make()
        try Self.doubleClickTitle(view, of: "研究")
        try Self.doubleClickTitle(view, of: "電力系統")
        try Self.doubleClickTitle(view, of: "潮流計算")

        let back = try #require(view.focusBackHitRectForTesting)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        view.handleMapClick(at: CGPoint(x: back.midX, y: back.midY), event: event)
        view.renderForTesting()
        #expect(view.focusPathForTesting == ["研究", "電力系統"], "一気に最上位へ戻さない")

        // escも同じ一段ずつ。
        #expect(view.closeFocusIfNeeded())
        #expect(view.focusPathForTesting == ["研究"])
        #expect(view.closeFocusIfNeeded())
        #expect(view.focusPathForTesting.isEmpty)
        #expect(!view.closeFocusIfNeeded(), "広げていないときは何も起きない")
    }

    /// 全体の地図から深い島を直に指したときに、通ってもいない道を戻り道として
    /// 積むと、押した覚えのない階層へ戻される。
    @Test("関係のない束を指したら、そこから始め直す")
    func focusingElsewhereRestartsThePath() throws {
        let view = Self.make()
        try Self.doubleClickTitle(view, of: "研究")
        try Self.doubleClickTitle(view, of: "電力系統")

        view.focus(on: "別の束")
        #expect(view.focusPathForTesting == ["別の束"])
    }
}

/// 「地図にした時の右側は、普通のFinderのリスト表示として理解すればいい」。
/// 一覧表示が持っている列は、こちらにも在るべき。
@Suite("地図の右の一覧の列")
@MainActor
struct WorkspaceMapOthersColumnTests {
    private static func view() -> WorkspaceMapView {
        _ = NSApplication.shared
        return WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
    }

    @Test("一覧表示と同じ五つの列を持っている")
    func hasTheSameColumnsAsTheList() {
        let mapColumns = Self.view().othersColumnsForTesting(width: 900).map(\.id)
        // 一覧表示の列（"name" など）と、地図の右の列（"other.name" など）を突き合わせる。
        let listColumns = WorkspaceBrowserViewController.makeFileColumns()
            .map(\.identifier.rawValue)
        #expect(mapColumns == listColumns.map { "other.\($0)" })
    }

    /// 狭いまま列を並べると、名前が読めなくなって本末転倒になる。
    @Test("幅に応じて右の列から畳まれる。名前は最後まで残る")
    func columnsFoldFromTheRight() {
        let view = Self.view()
        func visible(_ width: Double) -> [String] {
            view.othersColumnsForTesting(width: width).filter(\.visible).map(\.id)
        }
        #expect(visible(200) == ["other.name"])
        #expect(visible(300) == ["other.name", "other.modified"])
        #expect(visible(370) == ["other.name", "other.modified", "other.size"])
        #expect(visible(460).contains("other.kind"))
        // 「グループ」は言われるまで出さない（名前の幅を削るため）。
        #expect(!visible(900).contains("other.groups"))
    }

    /// 出せと言った列が幅の都合で消えると、切り替えを押しても何も起きないように見える。
    @Test("「グループ」を出すと言われたら、ほかの列より先に入れる")
    func theGroupColumnWinsWhenAsked() {
        let view = Self.view()
        view.setShowsGroupColumn(true)
        let narrow = view.othersColumnsForTesting(width: 280).filter(\.visible).map(\.id)
        #expect(narrow == ["other.name", "other.groups"])
        let wide = view.othersColumnsForTesting(width: 900).filter(\.visible).map(\.id)
        #expect(Set(wide) == ["other.name", "other.groups", "other.modified", "other.size", "other.kind"])
    }
}

/// 「見つからない N →」は、押した島のことを聞いている。
@Suite("見つからないの整理は、押した島だけに効く")
@MainActor
struct WorkspaceMapPruneScopeTests {
    @Test("押した島の名前が渡る")
    func pressingReportsTheIsland() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/finderai-prune-test", isDirectory: true)
        func item(_ name: String) -> WorkspaceItem {
            WorkspaceItem(
                url: root.appendingPathComponent(name),
                name: name,
                isDirectory: true,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                typeDescription: "フォルダ"
            )
        }
        var groups = WorkspaceItemGroups()
        groups.add("居るもの", to: "ツール開発")
        groups.add("消えたA", to: "ツール開発")
        groups.add("居るもの2", to: "研究")
        groups.add("消えたB", to: "研究")

        let view = WorkspaceMapView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        var asked: [String?] = []
        view.onPruneMissing = { asked.append($0) }
        view.show(
            items: [item("居るもの"), item("居るもの2")],
            groups: groups,
            presentNames: ["居るもの", "居るもの2"]
        )
        view.layoutSubtreeIfNeeded()
        view.renderForTesting()

        // どちらの島にも迷子が一つずつ居る。
        let rects = view.missingHitRectsForTesting
        #expect(rects.count == 2, "島ごとに的が要る: \(rects.keys.sorted())")
        let target = try #require(rects["研究"])

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        view.handleMapClick(at: CGPoint(x: target.midX, y: target.midY), event: event)

        // 全部まとめて（nil）ではなく、押した島だけ。
        #expect(asked == ["研究"])
    }
}

/// 畳んだ束は、一覧と地図の右で同じものを見る。
@Suite("畳んだ束は表示をまたいで残る")
@MainActor
struct WorkspaceCollapsedGroupsTests {
    @Test("片方で畳めば、もう片方でも畳まれている")
    func collapseIsShared() {
        let shared = WorkspaceCollapsedGroups()
        #expect(!shared.contains("研究"))

        // 一覧で畳む
        #expect(shared.toggle("研究") == true)
        // 地図の右も同じものを見ているので、畳まれている
        #expect(shared.contains("研究"))

        // 地図で開く
        #expect(shared.toggle("研究") == false)
        #expect(!shared.contains("研究"))
    }
}
