import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@Suite("Drawer tab strip shows every session with its folder binding")
struct DrawerSessionTabsTests {
    private let home = URL(fileURLWithPath: "/Users/x/projectA", isDirectory: true)
    private let away = URL(fileURLWithPath: "/Users/x/projectB", isDirectory: true)

    private func source(
        id: UUID = UUID(),
        kind: TerminalSessionKind = .claude,
        customName: String? = nil,
        role: String? = nil,
        in directory: URL,
        running: Bool = true,
        anchored: Bool = false
    ) -> DrawerSessionTabs.Source {
        DrawerSessionTabs.Source(
            id: id,
            kind: kind,
            customName: customName,
            role: role,
            directoryURL: directory,
            isRunning: running,
            isAnchored: anchored
        )
    }

    @Test("今いる場所のものはフォルダ名を添えない")
    func currentFolderHasNoSuffix() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: home)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.fullTitle) == ["Claude"])
        #expect(rows[0].folderName == nil)
        #expect(rows[0].belongsToCurrentFolder)
    }

    @Test("よその場所のものは、どこにいるかを添える")
    func otherFolderIsSuffixed() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: away)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.fullTitle) == ["Claude · projectB"])
        #expect(rows[0].folderName == "projectB")
        // 幅が無いときはフォルダを落とす。
        #expect(rows.map(\.compactTitle) == ["Claude"])
    }

    @Test("今いる場所のものを先頭へ寄せる。削られてよいのはよその場所のほう")
    func currentFolderSessionsComeFirst() {
        let awayFirst = UUID()
        let hereLater = UUID()
        let rows = DrawerSessionTabs.rows(
            sources: [
                source(id: awayFirst, in: away),
                source(id: hereLater, in: home)
            ],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.id) == [hereLater, awayFirst])
    }

    @Test("同じ組の中では渡された順のまま。押す先が動かない")
    func orderIsStableWithinAGroup() {
        let a = UUID(), b = UUID(), c = UUID()
        let rows = DrawerSessionTabs.rows(
            sources: [source(id: a, in: away), source(id: b, in: away), source(id: c, in: away)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.id) == [a, b, c])
    }

    @Test("前後の巡回は端で折り返す")
    func cyclingWrapsAround() {
        let a = UUID(), b = UUID(), c = UUID()
        let order = [a, b, c]
        #expect(DrawerSessionTabs.adjacentID(in: order, from: a, offset: 1) == b)
        #expect(DrawerSessionTabs.adjacentID(in: order, from: c, offset: 1) == a)
        #expect(DrawerSessionTabs.adjacentID(in: order, from: a, offset: -1) == c)
        #expect(DrawerSessionTabs.adjacentID(in: order, from: b, offset: -1) == a)
    }

    @Test("まだ選んでいなければ、進むなら先頭・戻るなら末尾から始める")
    func cyclingWithoutASelectionStartsAtAnEnd() {
        let a = UUID(), b = UUID()
        #expect(DrawerSessionTabs.adjacentID(in: [a, b], from: nil, offset: 1) == a)
        #expect(DrawerSessionTabs.adjacentID(in: [a, b], from: nil, offset: -1) == b)
        // 並びから消えたセッションを起点にされても、同じ扱いで拾う。
        #expect(DrawerSessionTabs.adjacentID(in: [a, b], from: UUID(), offset: 1) == a)
    }

    @Test("1本も無ければ巡回先も無い")
    func cyclingAnEmptyStripGoesNowhere() {
        #expect(DrawerSessionTabs.adjacentID(in: [], from: nil, offset: 1) == nil)
    }

    @Test("種類はタブが持つ。記号と色で読まずに見分けるため")
    func kindTravelsWithTheRow() {
        let rows = DrawerSessionTabs.rows(
            sources: [
                source(kind: .shell, in: home),
                source(kind: .codex, in: home),
                source(kind: .claude, in: home)
            ],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.kind) == [.shell, .codex, .claude])
    }

    @Test("止まっているものは実行中として扱わない")
    func stoppedSessionIsNotRunning() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: home, running: false)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows[0].isRunning == false)
    }

    @Test("選んでいる1本だけが選択中")
    func activeMarking() {
        let chosen = UUID()
        let rows = DrawerSessionTabs.rows(
            sources: [source(id: chosen, in: home), source(in: home)],
            currentDirectory: home,
            activeID: chosen
        )
        #expect(rows.filter(\.isActive).map(\.id) == [chosen])
    }

    @Test("行き先が決まっていなければ、どれも今いる場所のものではない")
    func noCurrentDirectoryMeansEverythingIsElsewhere() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: home), source(in: away)],
            currentDirectory: nil,
            activeID: nil
        )
        #expect(rows.allSatisfy { !$0.belongsToCurrentFolder })
        #expect(rows.map(\.folderName) == ["projectA", "projectB"])
    }

    @Test("固定したシェルには📌が付く")
    func anchoredShellShowsPin() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(kind: .shell, in: home, anchored: true)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.fullTitle) == ["📌 Shell"])
    }

    @Test("ボリュームの根はフルパスを名乗る")
    func rootFolderFallsBackToPath() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let rows = DrawerSessionTabs.rows(
            sources: [source(kind: .shell, in: root)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.fullTitle) == ["Shell · /"])
    }

    @Test("名前を付けたセッションはタブでそれを名乗り、種類はツールチップに残る")
    func customNameTakesOverTheTab() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(customName: "査読担当", in: home)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.fullTitle) == ["査読担当"])
        #expect(rows[0].tooltip.hasPrefix("査読担当（Claude） — "))
    }

    @Test("役割を持たせたタブには印が付き、全文はツールチップに出る")
    func roleGetsAMarkAndTooltipLine() {
        let rows = DrawerSessionTabs.rows(
            sources: [
                source(customName: "査読担当", role: "査読者として振る舞う", in: home)
            ],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.fullTitle) == ["査読担当 ✳︎"])
        #expect(rows[0].hasRole)
        #expect(rows[0].tooltip.contains("役割: 査読者として振る舞う"))
    }

    @Test("役割が無ければ印は付かず、ツールチップにも役割の行は出ない")
    func withoutRoleNoMark() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: home)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows[0].hasRole == false)
        #expect(rows[0].fullTitle.contains("✳︎") == false)
        #expect(rows[0].tooltip.contains("役割:") == false)
    }

    @Test("固定・役割・よその場所は同時に成り立つ")
    func marksCompose() {
        let rows = DrawerSessionTabs.rows(
            sources: [
                source(
                    kind: .shell,
                    customName: "ビルド番",
                    role: "ビルドだけ回す",
                    in: away,
                    anchored: true
                )
            ],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.fullTitle) == ["📌 ビルド番 · projectB ✳︎"])
        #expect(rows.map(\.compactTitle) == ["📌 ビルド番 ✳︎"])
    }
}
