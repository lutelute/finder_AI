import Foundation

/// 鍵の組み合わせひとつ。メニュー項目にもシステム側の登録にも使う。
///
/// `modifiers`は`NSEvent.ModifierFlags`のrawValueと同じビット割り当て
/// （⇧=0x20000／⌃=0x40000／⌥=0x80000／⌘=0x100000）。AppKitを持ち込まずに
/// 突き合わせるために、生の値のまま扱う。
public struct SystemShortcut: Hashable, Sendable {
    public static let shift: UInt = 0x20000
    public static let control: UInt = 0x40000
    public static let option: UInt = 0x80000
    public static let command: UInt = 0x100000
    /// 見比べるのはこの4つだけ。plistには他のビットが混ざることがある。
    public static let comparedModifiers = shift | control | option | command

    /// 小文字化した1文字、または`↑` `F5` `Del`のような鍵の名前。
    public let key: String
    public let modifiers: UInt

    public init(key: String, modifiers: UInt) {
        self.key = key
        self.modifiers = modifiers & Self.comparedModifiers
    }

    /// `⇧⌘T`のような、人が読める並び。
    public var label: String {
        var text = ""
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (key.count == 1 ? key.uppercased() : key)
    }
}

/// macOSが先に食べてしまう鍵を、機械に訊く。
///
/// ⌥⌘Tと⌥⌘Sは「メニューに書いてあるのに押しても何も起きない」まま出荷して
/// いた。どちらも実機でキーを送って初めて気付いたもので、気付くまでに要った
/// のは人の手と時間だった。書いてある鍵が死んでいるのは、鍵が無いより悪い。
///
/// システム環境設定に登録されているぶん（`com.apple.symbolichotkeys`）は
/// 読めば分かるので、そこだけでも自動で突き合わせる。読めない相手——AppKitが
/// 自前で足す項目や、他の常駐アプリが握るもの——はここでは捕まらない。
/// **ここが通っても「届く」の証明にはならない**。潰せるのは一種類だけ。
public enum ReservedSystemShortcuts {
    public static let defaultsDomain = "com.apple.symbolichotkeys"
    private static let defaultsKey = "AppleSymbolicHotKeys"

    /// 文字を持たない鍵。`parameters[0]`が65535のとき、keyCodeで引く。
    ///
    /// 文字を持つ鍵をkeyCodeで引いてはいけない。JISでは33が`@`、ANSIでは`[`で、
    /// keyCodeを信じると「⌘[が押さえられている」という嘘の警告が出る
    /// （実際に一度出した。システム側の登録は⌘@のほうだった）。
    static let keyCodeNames: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        48: "Tab", 49: "Space", 51: "Del", 53: "esc",
        114: "Help", 115: "Home", 116: "PgUp", 117: "FwdDel", 119: "End", 121: "PgDn"
    ]

    private static let noCharacter = 65535

    /// `parameters`の3つ組から鍵の名前を決める。分からなければnil。
    public static func keyName(character: Int, keyCode: Int) -> String? {
        if character != noCharacter,
           character > 0,
           let scalar = UnicodeScalar(UInt32(character)) {
            return String(scalar).lowercased()
        }
        return keyCodeNames[keyCode]
    }

    /// `AppleSymbolicHotKeys`の生の辞書から、有効なものだけを取り出す。
    ///
    /// 生の形は`{ "27": { enabled: 1, value: { parameters: [文字, keyCode, 修飾] } } }`。
    /// 無効なもの、形が違うもの、鍵の名前が決まらないものは黙って落とす——
    /// 読めなかったぶんを衝突として報告するより、取りこぼすほうが害が小さい。
    public static func enabled(from raw: [String: Any]) -> Set<SystemShortcut> {
        var found: Set<SystemShortcut> = []
        for entry in raw.values {
            guard let entry = entry as? [String: Any] else { continue }
            let isEnabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? false)
            guard isEnabled else { continue }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let character = (parameters[0] as? NSNumber)?.intValue,
                  let keyCode = (parameters[1] as? NSNumber)?.intValue,
                  let modifiers = (parameters[2] as? NSNumber)?.uint64Value,
                  let key = keyName(character: character, keyCode: keyCode) else { continue }
            found.insert(SystemShortcut(key: key, modifiers: UInt(truncatingIfNeeded: modifiers)))
        }
        return found
    }

    /// 今動いているMacに登録されているぶん。読めなければ空。
    public static func current() -> Set<SystemShortcut> {
        guard let defaults = UserDefaults(suiteName: defaultsDomain),
              let raw = defaults.dictionary(forKey: defaultsKey) else { return [] }
        return enabled(from: raw)
    }

    /// メニューの`keyEquivalent`を、システム側と同じ語彙へ揃える。
    ///
    /// AppKitは矢印や削除をプライベート領域の文字で表す。文字のままでは
    /// システム側の`↑`と並べられない。
    public static func normalizedKey(_ keyEquivalent: String) -> String {
        switch keyEquivalent {
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        case "\u{8}", "\u{7F}": return "Del"
        case "\u{1B}": return "esc"
        case "\u{9}": return "Tab"
        case " ": return "Space"
        default: return keyEquivalent.lowercased()
        }
    }
}
