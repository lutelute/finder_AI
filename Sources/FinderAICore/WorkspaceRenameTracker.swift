import Foundation

/// 外（Finderやシェル）で名前を変えられたとき、束の定義を追わせるための見張り。
///
/// 束はメンバーを**名前**で持つ。外から見えるのは「Aが消えた」「Bが増えた」までで、
/// その二つが同じものかは分からない。**推測で結ぶと、別物を束に入れる。**
/// 同じ時刻にたまたま起きた削除と新規作成を取り違えるのは、外れているより悪い。
///
/// そこで推測はしない。アプリがその一覧を一度でも見ていれば、**そのときの
/// ファイルの同一性**（ボリューム・inode・作成時刻）を覚えていられる。
/// 増えた名前がそれと一致したときだけ、同じものだと確かめて書き換える。
/// 一致は偶然では起きない — 同じ inode が再利用されても、作成時刻まで揃わない。
///
/// **追えないもの**（そのまま「見つからない」に残す。勝手に外さない）:
/// - アプリを閉じているあいだの改名。覚えている同一性が無い
/// - 別のフォルダへの移動。束はフォルダに属するので、移った先は別の定義になる
/// - 同じ名前で別のファイルが作り直された場合。同一性が違うので結ばない（正しい）
public struct WorkspaceRenameTracker: Sendable {
    public struct Rename: Equatable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    private var directory: URL?
    /// 名前 → そのときのファイルの同一性。束に入っていて実在するものだけ持つ。
    private var identities: [String: String] = [:]
    private var lastPresent: Set<String> = []

    public init() {}

    /// 一覧を読み直すたびに呼ぶ。書き換えるべき名前の対を返す。
    ///
    /// - Parameters:
    ///   - present: いまこのフォルダに実在する名前（隠しファイルを含む）
    ///   - members: どれかの束に入っている名前
    ///   - identity: 名前からファイルの同一性を引く。実在しなければ`nil`
    public mutating func follow(
        directory: URL,
        present: Set<String>,
        members: Set<String>,
        identity: (String) -> String?
    ) -> [Rename] {
        // フォルダが変われば覚えていることは使えない。同じ名前が隣のフォルダにも
        // あるので、持ち越すと別のフォルダのファイルと結んでしまう。
        if self.directory != directory {
            self.directory = directory
            identities = [:]
            lastPresent = []
        }
        defer { lastPresent = present }

        let missing = members.subtracting(present)
        // 前に見たときから増えた名前だけを候補にする。全部を候補にすると、
        // 迷子が居るフォルダで読み直すたびに全項目を stat することになる。
        let appeared = present.subtracting(lastPresent)

        var renames: [Rename] = []
        // 覚えている同一性が無ければ確かめようがない。初回はただ覚えるだけ。
        if !missing.isEmpty, !identities.isEmpty, !appeared.isEmpty {
            var byIdentity: [String: String] = [:]
            for name in appeared where !members.contains(name) {
                guard let id = identity(name) else { continue }
                byIdentity[id] = name
            }
            for old in missing.sorted() {
                guard let id = identities[old], let new = byIdentity[id] else { continue }
                renames.append(Rename(from: old, to: new))
                identities[new] = id
                byIdentity[id] = nil
            }
        }

        // 消えた名前の記憶は捨てる。持ち続けると、あとで同じ名前の**別の**ファイルが
        // 作られたときに、古い同一性と突き合わせて誤って結ぶ。
        identities = identities.filter { present.contains($0.key) }
        for name in members.intersection(present) where identities[name] == nil {
            identities[name] = identity(name)
        }
        return renames
    }
}
