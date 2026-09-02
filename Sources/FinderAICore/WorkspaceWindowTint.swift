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

    /// 明るい地に混ぜる色。彩度を落としてあるのは、薄めて使う前提だから。
    public var lightHex: UInt32 {
        switch self {
        case .teal: 0x3F7F8C
        case .moss: 0x5F7A4A
        case .azuki: 0x8C4A52
        case .wisteria: 0x6B6499
        case .amber: 0x96702C
        case .slate: 0x5A6472
        }
    }

    /// 暗い地に混ぜる色。明るい側と同じ色では、黒に近い地へ混ぜたときに
    /// 飲まれて灰にしか見えない。
    public var darkHex: UInt32 {
        switch self {
        case .teal: 0x6FB9C9
        case .moss: 0x96BE76
        case .azuki: 0xD0838C
        case .wisteria: 0xA79BD6
        case .amber: 0xD9A94A
        case .slate: 0x93A0B2
        }
    }

    /// 地に混ぜる割合。
    ///
    /// 暗い側を濃くしてあるのは、地が黒に近いほど混ぜた色が沈むから。同じ割合だと、
    /// ライトでははっきり色が付いてダークではほぼ灰に見える。
    ///
    /// 上限をこの値に置いたのは、色を敷く面（サイドバー232／見出し237）に載る
    /// 副文（110）のコントラストが、もともと4.4しかないため。ここを濃くすると
    /// 目印は強くなるが、その面の小さい字から先に読めなくなる。
    public static func strength(isDark: Bool) -> Double {
        isDark ? 0.18 : 0.14
    }

    /// 保存された文字列から戻す。読めない値は「色なし」に落とす——目印が消えるだけで、
    /// ウインドウは開く。
    public static func decoded(_ raw: String?) -> WorkspaceWindowTint? {
        guard let raw else { return nil }
        return WorkspaceWindowTint(rawValue: raw)
    }
}
