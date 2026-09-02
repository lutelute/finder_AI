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

    @Test("混ぜる割合は明暗で変えない")
    func strengthIsTheSameBothWays() {
        // 一度は暗い側だけ濃くしていた（黒に近い地では色が沈むから、という理屈）。
        // 効いていたのは割合ではなく**混ぜる色の明度**のほうで、いまはどちらも
        // 地の明度に寄せてあるので、同じ割合で同じだけ色が出る。
        #expect(WorkspaceWindowTint.strength(isDark: true)
            == WorkspaceWindowTint.strength(isDark: false))
    }

    @Test("混ぜる割合は0と1のあいだにある")
    func strengthIsAProportion() {
        // **読めるかどうかはここでは測れない。** 同じ割合でも混ぜる色を変えれば
        // コントラストは変わる。実際、数字だけを縛っていたときに暗い側の副文が
        // 4.5を割ったまま通り抜けた。実際の比は
        // `WindowTintContrastTests`（AppKitの色を解ける側）が測る。
        for isDark in [true, false] {
            let amount = WorkspaceWindowTint.strength(isDark: isDark)
            #expect(amount > 0)
            #expect(amount < 1)
        }
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

    @Test("暗い側の色は、明るい側より暗くて色味が強い")
    func darkVariantsAreDeepNotBright() {
        // 最初は逆にしていた（暗い地に負けないよう明るい色にする）。実機で外した——
        // 暗い地の上の字は明るいので、面の明度を上げると字が読みにくくなる。
        // 明度ではなく彩度で出す。
        func brightness(_ hex: UInt32) -> Double {
            let r = Double((hex >> 16) & 0xFF)
            let g = Double((hex >> 8) & 0xFF)
            let b = Double(hex & 0xFF)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        func spread(_ hex: UInt32) -> Double {
            let channels = [
                Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)
            ]
            return channels.max()! - channels.min()!
        }
        for tint in WorkspaceWindowTint.allCases {
            #expect(brightness(tint.darkHex) < brightness(tint.lightHex))
            // 灰では目印にならない。
            #expect(spread(tint.darkHex) >= 20)
            #expect(spread(tint.lightHex) >= 20)
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
