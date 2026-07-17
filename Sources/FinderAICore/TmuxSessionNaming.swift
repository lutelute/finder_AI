import CryptoKit
import Foundation

/// FinderAIのセッション識別（正規化フォルダ×種類）をtmuxセッション名へ写す。
/// 再接続とは「同じ名前を引くこと」なので、名前は起動をまたいで安定していなければ
/// ならない。tmuxは`.`と`:`を含む名前を拒否するため、パスはハッシュにする。
/// 種類だけは読める形で残し、`tmux ls`の出力を人間が診断できるようにする。
public enum TmuxSessionNaming {
    public static let namePrefix = "finderai-"

    public static func sessionName(for key: TerminalSessionKey) -> String {
        let digest = SHA256.hash(data: Data(key.directoryKey.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(namePrefix)\(key.kind.rawValue)-\(hex)"
    }

    /// 名前からの種類の逆引き。パスはハッシュなので戻せないが、種類は読める形で
    /// 埋めてあるのでここだけは復元できる。FinderAI名義でない名前はnil。
    public static func kind(fromSessionName name: String) -> TerminalSessionKind? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let rest = name.dropFirst(namePrefix.count)
        return TerminalSessionKind.allCases.first { rest.hasPrefix("\($0.rawValue)-") }
    }
}

/// `tmux list-sessions`の1行分。パスはセッション名からは戻せないため、
/// tmux自身に`#{session_path}`を答えさせる。
public struct TmuxSessionInfo: Equatable, Sendable {
    public let name: String
    public let workingDirectoryPath: String
    public let isAttached: Bool

    public init(name: String, workingDirectoryPath: String, isAttached: Bool) {
        self.name = name
        self.workingDirectoryPath = workingDirectoryPath
        self.isAttached = isAttached
    }

    public var kind: TerminalSessionKind? {
        TmuxSessionNaming.kind(fromSessionName: name)
    }

    /// `-F '#{session_name}\t#{session_path}\t#{session_attached}'`の出力行を読む。
    /// tmuxのセッション名はタブを含めないので、区切りはタブで安全。
    public static func parse(line: String) -> TmuxSessionInfo? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[0].isEmpty else { return nil }
        return TmuxSessionInfo(
            name: String(parts[0]),
            workingDirectoryPath: String(parts[1]),
            isAttached: (Int(parts[2]) ?? 0) > 0
        )
    }
}
