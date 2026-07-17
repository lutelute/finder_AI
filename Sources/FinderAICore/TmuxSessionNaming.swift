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
}
