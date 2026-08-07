import Foundation

/// セッションを前後へ回す鍵の判定。
///
/// メニューの`keyEquivalent`任せにできない。ターミナルは自分宛ての入力を
/// 広く食べるので、素直に流すとメニューまで届かない（⌃Tabも⌘⌥矢印も
/// 実機で届かなかった）。ドロワーの根で先に見て、当たれば自分で処理する。
///
/// 押された鍵の判定だけを切り出してあるのは、修飾キーの取りこぼし——
/// たとえば⌘⌥⇧→まで拾ってしまう類——を目で確かめずに済ませるため。
public enum SessionCycleShortcut: Equatable, Sendable {
    case next
    case previous

    /// 矢印キーのUnicode。AppKitの`NSLeftArrowFunctionKey`と同じ値。
    public static let leftArrow: Character = "\u{F702}"
    public static let rightArrow: Character = "\u{F703}"

    /// - Parameters:
    ///   - characters: 修飾を除いた文字（AppKitの`charactersIgnoringModifiers`）。
    ///   - hasCommand: ⌘が押されているか。
    ///   - hasOption: ⌥が押されているか。
    ///   - hasOtherModifiers: ⌃や⇧など、他の修飾が混ざっているか。
    public static func match(
        characters: String?,
        hasCommand: Bool,
        hasOption: Bool,
        hasOtherModifiers: Bool
    ) -> SessionCycleShortcut? {
        // ⌘⌥ちょうど。他の修飾が混ざっていたら別の意図とみなして手を出さない。
        guard hasCommand, hasOption, !hasOtherModifiers else { return nil }
        guard let character = characters?.first, characters?.count == 1 else { return nil }
        switch character {
        case rightArrow: return .next
        case leftArrow: return .previous
        default: return nil
        }
    }

    /// 並びを辿る向き。
    public var offset: Int {
        switch self {
        case .next: 1
        case .previous: -1
        }
    }
}
