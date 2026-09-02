import Foundation
import Testing

@testable import FinderAICore

@Suite("ウインドウごとの目印の色")
struct WorkspaceWindowTintTests {
    @Test("保存された文字列から戻る")
    func decodesRoundTrip() {
        for tint in WorkspaceWindowTint.allCases {
            #expect(WorkspaceWindowTint.decoded(tint.rawValue) == tint)
        }
    }

    @Test("読めない値と未設定は「色なし」に落ちる")
    func unknownFallsBackToNone() {
        // 目印が消えるだけで、ウインドウは開かなければならない。
        #expect(WorkspaceWindowTint.decoded(nil) == nil)
        #expect(WorkspaceWindowTint.decoded("") == nil)
        #expect(WorkspaceWindowTint.decoded("むかしの色") == nil)
    }

    @Test("暗い側のほうが濃く混ぜる")
    func darkMixesStronger() {
        // 地が黒に近いほど混ぜた色が沈む。同じ割合ではダークだけ灰に見える。
        #expect(WorkspaceWindowTint.strength(isDark: true)
            > WorkspaceWindowTint.strength(isDark: false))
    }

    @Test("濃さは、色を敷く面の副文が読める範囲に収める")
    func strengthStaysReadable() {
        // 色を敷くのはサイドバー(232)と見出し(237)で、そこに副文(110)が載る。
        // 素の状態で既に4.4しかないので、混ぜて4.5をさらに下回らせる幅は狭い。
        // ここを緩めるなら、先に副文の濃さを変える必要がある。
        #expect(WorkspaceWindowTint.strength(isDark: false) <= 0.16)
        #expect(WorkspaceWindowTint.strength(isDark: true) <= 0.22)
    }

    @Test("6色はすべて違う色で、明暗それぞれに別の値を持つ")
    func colorsAreDistinct() {
        let light = Set(WorkspaceWindowTint.allCases.map(\.lightHex))
        let dark = Set(WorkspaceWindowTint.allCases.map(\.darkHex))
        #expect(light.count == WorkspaceWindowTint.allCases.count)
        #expect(dark.count == WorkspaceWindowTint.allCases.count)
        // 明るい側と暗い側が同じ値だと、片方で必ず沈む。
        for tint in WorkspaceWindowTint.allCases {
            #expect(tint.lightHex != tint.darkHex)
        }
    }

    @Test("暗い側の色は明るい側より明るい")
    func darkVariantsAreLighter() {
        // 黒に近い地へ混ぜるので、混ぜる色そのものが明るくないと色が出ない。
        func brightness(_ hex: UInt32) -> Double {
            let r = Double((hex >> 16) & 0xFF)
            let g = Double((hex >> 8) & 0xFF)
            let b = Double(hex & 0xFF)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        for tint in WorkspaceWindowTint.allCases {
            #expect(brightness(tint.darkHex) > brightness(tint.lightHex))
        }
    }

    @Test("名前が付いていて、重複しない")
    func titlesAreUniqueAndNonEmpty() {
        let titles = WorkspaceWindowTint.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }
}

@Suite("目印の色を持ち越すスナップショット")
struct WorkspaceRestorationSnapshotTintTests {
    @Test("色を付けて保存し、読み直すと戻る")
    func roundTripsTints() throws {
        let snapshot = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/a", "/b", "/c"],
            sessions: [],
            windowTints: ["teal", "", "azuki"]
        )
        let data = try #require(snapshot.encoded())
        let restored = try #require(WorkspaceRestorationSnapshot.decoded(from: data))
        #expect(restored.tint(at: 0) == .teal)
        #expect(restored.tint(at: 1) == nil)
        #expect(restored.tint(at: 2) == .azuki)
    }

    @Test("色の項目が無い古いスナップショットも読める")
    func decodesSnapshotWithoutTints() throws {
        // この機能より前に書かれたものが読めなくなると、そのぶんのウインドウが
        // まるごと復元されない。目印が戻らないだけで済ませる。
        let json = """
        {"windowDirectoryPaths":["/a","/b"],"sessions":[]}
        """
        let restored = try #require(
            WorkspaceRestorationSnapshot.decoded(from: Data(json.utf8))
        )
        #expect(restored.windowDirectoryPaths.count == 2)
        #expect(restored.windowTints == nil)
        #expect(restored.tint(at: 0) == nil)
    }

    @Test("並びが足りなくても、範囲の外を読まない")
    func toleratesShortTintList() {
        let snapshot = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/a", "/b", "/c"],
            sessions: [],
            windowTints: ["moss"]
        )
        #expect(snapshot.tint(at: 0) == .moss)
        #expect(snapshot.tint(at: 2) == nil)
        #expect(snapshot.tint(at: -1) == nil)
        #expect(snapshot.tint(at: 99) == nil)
    }

    @Test("色だけが違えば別の構成として書き直す")
    func tintChangeMakesADifferentSnapshot() {
        // 等値で弾いているので、色を変えただけでは保存されない作りだと
        // 次の起動で戻らない。
        let base = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/a"],
            sessions: [],
            windowTints: [""]
        )
        let tinted = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: ["/a"],
            sessions: [],
            windowTints: ["amber"]
        )
        #expect(base != tinted)
    }
}
