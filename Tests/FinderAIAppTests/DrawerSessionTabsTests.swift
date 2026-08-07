import Foundation
@testable import FinderAIApp
import Testing

@Suite("Drawer tab strip shows every session with its folder binding")
struct DrawerSessionTabsTests {
    private let home = URL(fileURLWithPath: "/Users/x/projectA", isDirectory: true)
    private let away = URL(fileURLWithPath: "/Users/x/projectB", isDirectory: true)

    private func source(
        id: UUID = UUID(),
        kind: String = "Claude",
        in directory: URL,
        running: Bool = true
    ) -> DrawerSessionTabs.Source {
        DrawerSessionTabs.Source(
            id: id,
            kindName: kind,
            directoryURL: directory,
            isRunning: running
        )
    }

    @Test("a session in the current folder shows no folder suffix")
    func currentFolderHasNoSuffix() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: home)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["●  Claude"])
        #expect(rows.map(\.belongsToCurrentFolder) == [true])
    }

    @Test("a session in another folder is suffixed with its folder name")
    func otherFolderIsSuffixed() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: away)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["●  Claude · projectB"])
        #expect(rows.map(\.belongsToCurrentFolder) == [false])
        #expect(rows[0].tooltip == "Claude — /Users/x/projectB/\nダブルクリックでこの場所をブラウザに表示")
    }

    @Test("stopped sessions lose the running dot but keep their identity")
    func stoppedSessionHasNoDot() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(kind: "Shell", in: away, running: false)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["Shell · projectB"])
        #expect(rows.map(\.isRunning) == [false])
    }

    @Test("only the active id is marked active")
    func activeMarking() {
        let active = UUID()
        let rows = DrawerSessionTabs.rows(
            sources: [source(id: active, in: home), source(in: away)],
            currentDirectory: home,
            activeID: active
        )
        #expect(rows.map(\.isActive) == [true, false])
    }

    @Test("without a current directory every session shows its folder")
    func noCurrentDirectorySuffixesEverything() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: home), source(kind: "Codex", in: away)],
            currentDirectory: nil,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["●  Claude · projectA", "●  Codex · projectB"])
    }

    @Test("an anchored shell wears the pin on its tab")
    func anchoredShellShowsPin() {
        let rows = DrawerSessionTabs.rows(
            sources: [
                DrawerSessionTabs.Source(
                    id: UUID(),
                    kindName: "Shell",
                    directoryURL: home,
                    isRunning: true,
                    isAnchored: true
                )
            ],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["📌 ●  Shell"])
    }

    @Test("a volume-root session falls back to its full path as the folder name")
    func rootFolderFallsBackToPath() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let rows = DrawerSessionTabs.rows(
            sources: [source(kind: "Shell", in: root)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["●  Shell · /"])
    }

    @Test("名前を付けたセッションはタブでそれを名乗り、種類はツールチップに残る")
    func customNameTakesOverTheTab() {
        let rows = DrawerSessionTabs.rows(
            sources: [
                DrawerSessionTabs.Source(
                    id: UUID(),
                    kindName: "Claude",
                    customName: "査読担当",
                    directoryURL: home,
                    isRunning: true
                )
            ],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["●  査読担当"])
        #expect(rows[0].tooltip.hasPrefix("査読担当（Claude） — "))
    }

    @Test("名前は他フォルダの接尾辞・固定ピンとも両立する")
    func customNameComposesWithSuffixAndPin() {
        let rows = DrawerSessionTabs.rows(
            sources: [
                DrawerSessionTabs.Source(
                    id: UUID(),
                    kindName: "Shell",
                    customName: "ビルド番",
                    directoryURL: away,
                    isRunning: true,
                    isAnchored: true
                )
            ],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["📌 ●  ビルド番 · projectB"])
    }

    @Test("名前が無ければこれまでどおり種類名のまま")
    func withoutCustomNameNothingChanges() {
        let rows = DrawerSessionTabs.rows(
            sources: [source(in: home)],
            currentDirectory: home,
            activeID: nil
        )
        #expect(rows.map(\.title) == ["●  Claude"])
        #expect(rows[0].tooltip.hasPrefix("Claude — "))
    }
}
