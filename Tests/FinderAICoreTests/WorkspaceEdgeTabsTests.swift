import CoreGraphics
import Foundation
import Testing
@testable import FinderAICore

@Suite("Edge tabs")
struct WorkspaceEdgeTabsTests {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `#expect`はマクロが式をクロージャへ包むので、mutatingの呼び出しは結果を
    /// 先に受けてから渡す。
    @Test("adding is idempotent and stops at the capacity")
    func addingRespectsCapacity() {
        var tabs = WorkspaceEdgeTabs()
        let first = tabs.add(url("/tmp/a"))
        #expect(first)
        // 2回目は何も起きない。すでに縁にあるものを押して並びが動くほうが困る。
        let duplicate = tabs.add(url("/tmp/a"))
        #expect(!duplicate)
        #expect(tabs.contains(url("/tmp/a")))

        for index in 1..<WorkspaceEdgeTabs.capacity {
            let added = tabs.add(url("/tmp/folder\(index)"))
            #expect(added)
        }
        #expect(tabs.isFull)
        let overflow = tabs.add(url("/tmp/one-too-many"))
        #expect(!overflow)
        #expect(tabs.storedPaths.count == WorkspaceEdgeTabs.capacity)
    }

    @Test("stored paths survive a round trip and drop duplicates")
    func roundTrip() {
        let tabs = WorkspaceEdgeTabs(paths: ["/tmp/a", "/tmp/b", "/tmp/a"])
        #expect(tabs.storedPaths == ["/tmp/a", "/tmp/b"])
        #expect(WorkspaceEdgeTabs(paths: tabs.storedPaths).storedPaths == tabs.storedPaths)
    }

    @Test("a stored list longer than the capacity is truncated, not refused")
    func oversizedStorageIsTruncated() {
        let paths = (0...WorkspaceEdgeTabs.capacity).map { "/tmp/f\($0)" }
        #expect(WorkspaceEdgeTabs(paths: paths).storedPaths.count == WorkspaceEdgeTabs.capacity)
    }

    @Test("toggle removes what it finds and adds what it does not")
    func toggleGoesBothWays() {
        var tabs = WorkspaceEdgeTabs()
        tabs.toggle(url("/tmp/a"))
        #expect(tabs.contains(url("/tmp/a")))
        tabs.toggle(url("/tmp/a"))
        #expect(!tabs.contains(url("/tmp/a")))
        #expect(tabs.isEmpty)
    }
}

@Suite("Edge tab sorting")
struct WorkspaceEdgeTabSortTests {
    private func item(
        _ name: String,
        isDirectory: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil
    ) -> WorkspaceItem {
        WorkspaceItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            fileSize: size,
            modifiedAt: modified,
            typeDescription: nil
        )
    }

    /// 並べ替えの軸が何であれ、フォルダとファイルが混ざると目で追えない。
    @Test("folders lead regardless of the sort key or direction")
    func foldersAlwaysLead() {
        let items = [
            item("z-file", size: 10),
            item("a-folder", isDirectory: true),
            item("m-file", size: 5)
        ]
        for sort in WorkspaceEdgeTabSort.allCases {
            for ascending in [true, false] {
                let sorted = sort.sorted(items, ascending: ascending)
                #expect(sorted.first?.isDirectory == true, "\(sort) \(ascending)")
            }
        }
    }

    @Test("name, size, and date each order by their own key")
    func eachKeyOrders() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let items = [
            item("b", size: 30, modified: old),
            item("a", size: 10, modified: new),
            item("c", size: 20, modified: old)
        ]
        #expect(WorkspaceEdgeTabSort.name.sorted(items, ascending: true).map(\.name) == ["a", "b", "c"])
        #expect(WorkspaceEdgeTabSort.name.sorted(items, ascending: false).map(\.name) == ["c", "b", "a"])
        #expect(WorkspaceEdgeTabSort.size.sorted(items, ascending: true).map(\.name) == ["a", "c", "b"])
        // 同じ日付のものは名前で決める。順番が実行ごとに変わらないこと。
        #expect(WorkspaceEdgeTabSort.modified.sorted(items, ascending: true).map(\.name) == ["b", "c", "a"])
    }

    @Test("missing sizes and dates sort as the smallest, never crash")
    func missingValuesAreTolerated() {
        let items = [item("has", size: 5, modified: Date(timeIntervalSince1970: 5)), item("none")]
        #expect(WorkspaceEdgeTabSort.size.sorted(items, ascending: true).first?.name == "none")
        #expect(WorkspaceEdgeTabSort.modified.sorted(items, ascending: true).first?.name == "none")
    }
}

@Suite("Edge tab placement")
struct EdgeTabPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test("the strip hugs the chosen edge and centres vertically")
    func stripHugsTheEdge() throws {
        let right = try #require(EdgeTabPlacement.stripFrame(
            tabCount: 3,
            edge: .right,
            visibleFrame: screen
        ))
        #expect(right.maxX == screen.maxX)
        #expect(abs(right.midY - screen.midY) <= 1)

        let left = try #require(EdgeTabPlacement.stripFrame(
            tabCount: 3,
            edge: .left,
            visibleFrame: screen
        ))
        #expect(left.minX == screen.minX)
        #expect(left.width == EdgeTabPlacement.tabWidth)
    }

    @Test("no tabs means no strip")
    func emptyStripIsNil() {
        #expect(EdgeTabPlacement.stripFrame(tabCount: 0, edge: .right, visibleFrame: screen) == nil)
    }

    /// 縁に貼り付くUIで最も困るのは、開いた先が画面外で読めないこと。
    @Test("a popover near the top or bottom is pushed back on screen")
    func popoverStaysOnScreen() {
        let nearBottom = CGRect(x: 1410, y: 4, width: 30, height: 58)
        let frame = EdgeTabPlacement.popoverFrame(
            anchor: nearBottom,
            preferredHeight: 400,
            edge: .right,
            visibleFrame: screen
        )
        #expect(frame.minY >= screen.minY)
        #expect(frame.maxY <= screen.maxY)
        // 右の縁からは内側（左）へ開く。
        #expect(frame.maxX <= nearBottom.minX + 1)

        let nearTop = CGRect(x: 0, y: screen.maxY - 58, width: 30, height: 58)
        let left = EdgeTabPlacement.popoverFrame(
            anchor: nearTop,
            preferredHeight: 400,
            edge: .left,
            visibleFrame: screen
        )
        #expect(left.maxY <= screen.maxY)
        #expect(left.minX >= nearTop.maxX - 1)
    }

    @Test("popover height is bounded on both ends")
    func popoverHeightIsBounded() {
        let tall = EdgeTabPlacement.popoverFrame(
            anchor: CGRect(x: 1410, y: 400, width: 30, height: 58),
            preferredHeight: 5_000,
            edge: .right,
            visibleFrame: screen
        )
        #expect(tall.height <= EdgeTabPlacement.popoverMaximumHeight)

        let short = EdgeTabPlacement.popoverFrame(
            anchor: CGRect(x: 1410, y: 400, width: 30, height: 58),
            preferredHeight: 10,
            edge: .right,
            visibleFrame: screen
        )
        #expect(short.height == EdgeTabPlacement.popoverMinimumHeight)
    }

    /// 画面より縦に長い帯は出しようがない。無理に出さず、出さないと答える。
    @Test("a strip taller than the screen is refused")
    func oversizedStripIsRefused() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 100)
        #expect(EdgeTabPlacement.stripFrame(tabCount: 8, edge: .right, visibleFrame: tiny) == nil)
    }

    /// 隠すときも取っ手だけは画面に残す。丸ごと消すと、どこに当てれば戻るのかが
    /// 画面のどこにも無いことになり、それを取り繕う仕掛けで動きが読めなくなる。
    @Test("hiding leaves a handle on screen")
    func hiddenStripLeavesAHandle() throws {
        let right = try #require(EdgeTabPlacement.stripFrame(
            tabCount: 3,
            edge: .right,
            visibleFrame: screen
        ))
        let hiddenRight = EdgeTabPlacement.hiddenStripFrame(visible: right, edge: .right)
        #expect(hiddenRight.size == right.size)
        #expect(hiddenRight.minY == right.minY)
        // 画面に残るのは取っ手のぶんだけ。
        #expect(screen.maxX - hiddenRight.minX == EdgeTabPlacement.handleWidth)

        let left = try #require(EdgeTabPlacement.stripFrame(
            tabCount: 3,
            edge: .left,
            visibleFrame: screen
        ))
        let hiddenLeft = EdgeTabPlacement.hiddenStripFrame(visible: left, edge: .left)
        #expect(hiddenLeft.maxX - screen.minX == EdgeTabPlacement.handleWidth)
    }

    /// 呼び出す高さを指定できる。指定しなければ画面の中央。
    @Test("the strip can be centred on a given height, clamped to the screen")
    func stripHonoursPreferredCentre() throws {
        let middle = try #require(EdgeTabPlacement.stripFrame(
            tabCount: 2,
            edge: .right,
            visibleFrame: screen,
            preferredCenterY: 700
        ))
        #expect(abs(middle.midY - 700) <= 1)

        // 画面からはみ出す高さを求められても、中に収める。
        let high = try #require(EdgeTabPlacement.stripFrame(
            tabCount: 2,
            edge: .right,
            visibleFrame: screen,
            preferredCenterY: screen.maxY + 500
        ))
        #expect(high.maxY <= screen.maxY)
        #expect(high.minY >= screen.minY)
    }

    @Test("the trigger sits in the edge's last few points, within the strip's rows")
    func triggerIsAThinBandBesideTheStrip() throws {
        let strip = try #require(EdgeTabPlacement.stripFrame(
            tabCount: 3,
            edge: .right,
            visibleFrame: screen
        ))
        func hits(_ x: CGFloat, _ y: CGFloat) -> Bool {
            EdgeTabPlacement.triggerContains(
                mouse: CGPoint(x: x, y: y),
                stripFrame: strip,
                edge: .right,
                visibleFrame: screen
            )
        }

        #expect(hits(screen.maxX - 1, strip.midY))
        // 縁から離れれば踏まない。画面を横切るだけの動きで開かないための線。
        #expect(!hits(screen.maxX - 40, strip.midY))
        // 縦は帯の位置に縛られない。縁に手を振り切れば当たる、が要る——帯の前後
        // だけを見ていた版は「端に当てているのに出ない」になった。
        #expect(hits(screen.maxX - 1, strip.maxY + 6))
        #expect(hits(screen.maxX - 1, strip.maxY + 200))
        #expect(hits(screen.maxX - 1, screen.maxY - 100))
        #expect(hits(screen.maxX - 1, screen.minY + 100))
        // 隅だけはMission Controlのホットコーナーに譲る。
        #expect(!hits(screen.maxX - 1, screen.maxY - 2))
        #expect(!hits(screen.maxX - 1, screen.minY + 2))
        // 反対の縁では反応しない。
        #expect(!EdgeTabPlacement.triggerContains(
            mouse: CGPoint(x: screen.minX, y: strip.midY),
            stripFrame: strip,
            edge: .right,
            visibleFrame: screen
        ))
    }
}
