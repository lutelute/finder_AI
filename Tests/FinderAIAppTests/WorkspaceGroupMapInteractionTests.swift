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
