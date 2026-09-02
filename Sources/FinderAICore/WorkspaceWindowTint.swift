import Foundation

/// ウインドウ一枚ごとの目印になる色。
///
/// 何十枚と開く道具なので、タイトルだけでは「どれがどれか」が読めない。フォルダ名は
/// 重なるし（`logs`を3枚）、副題に親を添えても目で追う手掛かりとしては弱い。色は
/// 名前を読まずに済む唯一の手掛かりで、視界の端でも効く。
///
/// **色を載せるのは額縁だけ**（タイトルバー・ツールバー・サイドバー・下帯・
/// ターミナルの見出し）。ファイル一覧の地には載せない——一覧は名前を読む場所で、
/// そこへ色を敷くと薄い色でも副文のコントラストが落ちる。窓を重ねたときに
/// 見えているのも端のほうなので、額縁は目印としても効く面になる。
///
/// 自由な色ではなく決め打ちの6色にしてある。色は「隣と違うこと」しか要らないので、
/// 選べる幅より**互いに離れていること**のほうが役に立つ。自由に選ばせると、
/// 隣り合う2枚が見分けの付かない2色になる事故のほうが起きやすい。
public enum WorkspaceWindowTint: String, CaseIterable, Sendable, Codable {
    case teal
    case moss
    case azuki
    case wisteria
    case amber
    case slate

    /// メニューに出す名前。
    public var title: String {
        switch self {
        case .teal: "藍鼠"
        case .moss: "苔"
        case .azuki: "小豆"
        case .wisteria: "藤"
        case .amber: "琥珀"
        case .slate: "鈍色"
        }
    }

    /// 明るい地に混ぜる色。**淡くて彩度の高い色**を使う。
    ///
    /// はじめは中間調の色を薄く混ぜていた（`0x3F7F8C`など）。地が白に近いので
    /// 混ぜるほど面が暗くなり、その上の暗い字とのコントラストが落ちる。実測で
    /// 副文は4.16→3.44まで下がり、それでいて色味は3〜15しか出ていなかった。
    ///
    /// 地と同じくらい明るく色相だけが強い色にすると、面の明度がほとんど下がらない。
    /// 副文の比は3.63〜4.08に戻り、色味は15〜33へ上がる——**両方良くなる。**
    /// 暗い側と原理は同じで、向きが逆なだけ（あちらは深く濃い色）。
    public var lightHex: UInt32 {
        switch self {
        case .teal: 0xA8DCE8
        case .moss: 0xC3E0A8
        case .azuki: 0xF0C2C8
        case .wisteria: 0xCFC6EC
        case .amber: 0xF2DCA8
        case .slate: 0xBACADC
        }
    }

    /// 暗い地に混ぜる色。**明るい色ではなく、深く濃い色を使う。**
    ///
    /// 最初は明るい側を明度で持ち上げた色にしていた（`0x6FB9C9`など）。黒に近い地へ
    /// 混ぜると飲まれるので明るくする、という考えだったが、実機で二つとも外した——
    /// **色は見えないのに、載っている小さい字は読みにくくなった。**
    ///
    /// 暗い地の上の字は明るい（本文215・副文153）。明るい色を混ぜると面の明度が
    /// 上がり、その字とのコントラストが落ちる。実測で副文は5.79→4.09まで落ちて
    /// 4.5を割っていた。濃さを上げれば色は出るが、比はさらに下がる（0.45で2.24）。
    ///
    /// **明度ではなく彩度で出す。** 地と同じくらい暗く、色相だけが強い色を、
    /// 大きめの割合で混ぜる。面の明度はほとんど上がらないので副文の比はむしろ
    /// 改善し（4.7〜5.5）、色ははっきり出る。
    public var darkHex: UInt32 {
        switch self {
        case .teal: 0x0E4A57
        case .moss: 0x24421A
        case .azuki: 0x4A1A22
        case .wisteria: 0x2A2154
        case .amber: 0x4A3408
        case .slate: 0x1E2A3A
        }
    }

    /// 帯や印に**そのまま置く**色。地に混ぜるものとは別に持つ。
    ///
    /// 混ぜる色は地の明度に寄せてあるので、単体で置くと薄すぎる（明るい側は
    /// ほとんど白、暗い側はほとんど黒に見える）。帯は4ptしかなく、面ではなく
    /// 線として読ませるものなので、明暗どちらの地の上でも成立する中間調が要る。
    ///
    /// 混ぜる用として最初に置いていた中間調をここへ回した。混ぜるには
    /// 都合が悪かった明度が、単体で置くぶんにはちょうどよい。
    public var barHex: UInt32 {
        switch self {
        case .teal: 0x3F8B9C
        case .moss: 0x66853F
        case .azuki: 0x9E4A55
        case .wisteria: 0x726BA8
        case .amber: 0xA67C1F
        case .slate: 0x5F6C7D
        }
    }

    /// 帯の太さ。面の色だけでは弱いときの、もう一段の手掛かり。
    public static let barThickness: Double = 4

    /// 地に混ぜる割合。
    ///
    /// 地に混ぜる既定の割合。明暗で変えない。
    ///
    /// 混ぜる色を**地と同じ明度に寄せて彩度だけ上げて**あるので、たくさん混ぜても
    /// 面の明るさがほとんど動かない。動かないから、上に載る字とのコントラストも保たれる。
    ///
    /// 薄く混ぜるほど安全、ではない。中間調の色を薄く混ぜていたときは、色が出ない
    /// うえに面の明度だけ動いて**字も読みにくかった**（明るい側で副文4.16→3.44、
    /// 暗い側で5.79→4.09）。効くのは割合ではなく混ぜる色のほう。
    ///
    /// この値は暗い側の副文が4.5を保つ上限でもある（実測4.52）。
    /// 実際の比は `WindowTintContrastTests` が測る——数字だけを縛っても何も守れない。
    public static let defaultStrength: Double = 0.45

    /// 設定で動かせる幅。
    ///
    /// 下限は「色が付いていると分かる」下限、上限は**読みやすさを進んで手放す側**。
    /// 既定より濃くすると副文の比は落ちる（0.80で暗い側3.82・明るい側3.26）。
    /// それでも開けてあるのは、何十枚と開く人にとって「どれがどれか」のほうが
    /// 切実な場面があるため。既定は落とさない側に置いてある。
    public static let strengthRange: ClosedRange<Double> = 0.15...0.80

    /// 範囲へ収める。壊れた値や古い値が入っていても、極端な見た目にしない。
    public static func clampedStrength(_ value: Double) -> Double {
        guard value.isFinite else { return defaultStrength }
        return min(max(value, strengthRange.lowerBound), strengthRange.upperBound)
    }

    /// 保存された文字列から戻す。読めない値は「色なし」に落とす——目印が消えるだけで、
    /// ウインドウは開く。
    public static func decoded(_ raw: String?) -> WorkspaceWindowTint? {
        guard let raw else { return nil }
        return WorkspaceWindowTint(rawValue: raw)
    }
}
