import Foundation

/// 一つのフォルダの中を、実体を動かさずに束ねる定義。
///
/// フォルダを作って中身を移す代わりに、そのフォルダ自身に置いた一枚のJSONが
/// 「どれとどれが同じ束か」を持つ。`~/Documents/GitHub`のように146個のリポジトリが
/// 平らに並ぶ場所で、gitのパスもsymlinkも壊さずに束ねるための入れ物。
///
/// メンバーは**フォルダ直下の名前**であって絶対パスではない。フォルダごと移動しても
/// 同期先の別マシンで開いても定義がそのまま生きるのは、これが相対名だから。
///
/// 一つの項目が複数の束に属してよい。「ツール開発」であり同時に「Swift」でもある、
/// というのは分類の失敗ではなく普通のことで、排他にすると片方を選ばせることになる。
public struct WorkspaceItemGroups: Equatable, Sendable, Codable {
    /// 隠しファイルにしてあるのは、束ねられる対象と同じ場所に並べたくないから。
    /// 定義の存在は一覧の見出しとして見えるので、ファイルまで見せる必要はない。
    public static let fileName = ".finderai-groups.json"

    public struct Group: Equatable, Sendable, Codable {
        public var name: String
        /// フォルダ直下の名前。順序は表示順ではなく、追加された順。
        public var members: [String]

        public init(name: String, members: [String] = []) {
            self.name = name
            self.members = members
        }
    }

    public var version: Int
    /// 表示順そのもの。並べ替えは配列の並べ替えで表す。
    public var groups: [Group]

    public init(version: Int = 1, groups: [Group] = []) {
        self.version = version
        self.groups = groups
    }

    // MARK: - 読み書き

    /// 定義を読む。ファイルが無ければ`nil` — それは正常な状態で、束のないフォルダ。
    ///
    /// 壊れたJSONは`nil`ではなく**throw**する。読めないものを「空の定義」として扱うと、
    /// 次の保存が壊れたファイルを正常な空ファイルで上書きして、ユーザーが手で書いた束を
    /// 本当に消してしまう。読めなかったことは読めなかったこととして返す。
    public static func load(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> WorkspaceItemGroups? {
        let url = definitionURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WorkspaceItemGroups.self, from: data)
    }

    public func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        // 手で開いて直せることを前提にした形式。キー順が毎回変わると、
        // このファイルをgitに入れている人の差分が意味のない行で埋まる。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.definitionURL(in: directory), options: .atomic)
    }

    public static func definitionURL(in directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - 問い合わせ

    /// その名前が属する束を、表示順で返す。どこにも属さなければ空。
    public func groupNames(for member: String) -> [String] {
        groups.filter { $0.members.contains(member) }.map(\.name)
    }

    // MARK: - 編集

    /// 束に加える。すでに入っていれば何もしない — 同じ名前が二度並ぶと、
    /// 一覧に同じ項目が二行出る。
    ///
    /// 知らない束の名前を渡されたら、その束を作って末尾に置く。ドラッグ先が
    /// 存在しない状況は呼び出し側では起きないが、手で書いたJSONとの往復では起きる。
    public mutating func add(_ member: String, to groupName: String) {
        guard let index = groups.firstIndex(where: { $0.name == groupName }) else {
            groups.append(Group(name: groupName, members: [member]))
            return
        }
        guard !groups[index].members.contains(member) else { return }
        groups[index].members.append(member)
    }

    /// 一つの束から外す。他の束に属したままなのは正しい状態で、
    /// 「ツール開発から外したらSwiftからも消えた」は起きない。
    ///
    /// 空になった束は残す。落とし先として見出しが要るし、消してしまうと
    /// 「最後の一個を出したら束ごと消えた」という取り返しのつかない操作になる。
    public mutating func remove(_ member: String, from groupName: String) {
        guard let index = groups.firstIndex(where: { $0.name == groupName }) else { return }
        groups[index].members.removeAll { $0 == member }
    }

    /// 名前ごと消えた項目を、全部の束から外す。フォルダを実際に削除したときに使う。
    public mutating func removeFromAllGroups(_ member: String) {
        for index in groups.indices {
            groups[index].members.removeAll { $0 == member }
        }
    }

    /// 束の名前を変える。並び順（＝地図での置き場所）は変わらない。
    ///
    /// すでに同じ名前の束があれば**何もしない**。黙って統合すると、二つの束が
    /// 一つに溶けて元に戻せない。呼び出し側が先に名前の重なりを確かめる。
    /// 戻り値は変えられたかどうか。
    @discardableResult
    public mutating func rename(_ groupName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != groupName else { return false }
        guard !groups.contains(where: { $0.name == trimmed }) else { return false }
        guard let index = groups.firstIndex(where: { $0.name == groupName }) else { return false }
        groups[index].name = trimmed
        return true
    }

    /// 束そのものを消す。中のものはどこにも移らず、束から外れるだけ。
    ///
    /// 実体には触れない。束は「どれとどれが同じか」の記述にすぎないので、
    /// 束を消してもフォルダは一つも減らない。
    public mutating func removeGroup(_ groupName: String) {
        groups.removeAll { $0.name == groupName }
    }

    /// 束の並びを動かす。地図では枡の位置が、一覧では見出しの順が変わる。
    public mutating func move(_ groupName: String, by offset: Int) {
        guard let index = groups.firstIndex(where: { $0.name == groupName }) else { return }
        let target = index + offset
        guard groups.indices.contains(target) else { return }
        let group = groups.remove(at: index)
        groups.insert(group, at: target)
    }
}

/// 見出しと、その下に並ぶもの。`name`が`nil`なら未分類。
public struct WorkspaceGroupSection: Equatable, Sendable {
    public let name: String?
    public let items: [WorkspaceItem]

    public init(name: String?, items: [WorkspaceItem]) {
        self.name = name
        self.items = items
    }

    public var isUngrouped: Bool { name == nil }
}

public extension WorkspaceItemGroups {
    /// 束に属するものと、そうでないものに分ける。
    ///
    /// 地図が使う。束に属さないものを力学配置に混ぜると、`~/Documents/GitHub` では
    /// 116個が29個を包囲して画面の八割を占め、見せたい重なりが埋もれた。関係が
    /// 無いものを散らしても情報は増えないので、名前順に並べて別の欄へ回す。
    func partition(
        _ items: [WorkspaceItem]
    ) -> (grouped: [WorkspaceItem], others: [WorkspaceItem]) {
        var grouped: [WorkspaceItem] = []
        var others: [WorkspaceItem] = []
        for item in items {
            if groupNames(for: item.name).isEmpty {
                others.append(item)
            } else {
                grouped.append(item)
            }
        }
        return (
            grouped,
            others.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    /// 定義にあるのに実物が無いメンバー。束ごと、名前順。
    ///
    /// 見出しを組むときは黙って落としている。別のマシンにしか無いフォルダの定義を
    /// 消さずに持っておくためで、それは正しい。ただし**本当に消したフォルダ**の
    /// 名前も同じように黙って落ちるので、定義にゴミが残り続けても気づけない。
    /// 数を数えて見せられるようにする。
    func missingMembers(among items: [WorkspaceItem]) -> [String: [String]] {
        missingMembers(amongNames: Set(items.map(\.name)))
    }

    /// 実在する名前を直接渡す版。
    ///
    /// **隠しファイルを含めた**名前を渡すこと。一覧に見えているものだけで判定すると、
    /// 束に入れた `.claude` のような隠しフォルダが、隠し表示をオフにしただけで
    /// 「見つからない」に化ける。実在するかどうかは表示設定とは無関係。
    func missingMembers(amongNames present: Set<String>) -> [String: [String]] {
        var missing: [String: [String]] = [:]
        for group in groups {
            let lost = group.members.filter { !present.contains($0) }
            guard !lost.isEmpty else { continue }
            missing[group.name] = lost.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return missing
    }

    /// 実物が無いメンバーを、全部の束から外す。名前は隠しファイルを含めて渡すこと。
    mutating func pruneMissingMembers(amongNames present: Set<String>) {
        for index in groups.indices {
            groups[index].members.removeAll { !present.contains($0) }
        }
    }

    /// 束を、共有でつながっているもの同士が隣り合う順に並べ替える。
    ///
    /// 地図では束を格子に並べる。共有のある束が離れた枡に入ると橋が画面を横断して
    /// 追いにくいので、つながっている束から先に並べる。
    func adjacencyOrderedNames() -> [String] {
        let names = groups.map(\.name)
        var sharedWith: [String: Set<String>] = [:]
        for group in groups {
            let mine = Set(group.members)
            for other in groups where other.name != group.name {
                if !mine.isDisjoint(with: other.members) {
                    sharedWith[group.name, default: []].insert(other.name)
                }
            }
        }

        var ordered: [String] = []
        var seen: Set<String> = []
        for name in names where !seen.contains(name) {
            // 定義順を骨にしたまま、つながっている先をその場で引き寄せる。
            var stack = [name]
            while let current = stack.popLast() {
                guard seen.insert(current).inserted else { continue }
                ordered.append(current)
                let neighbours = (sharedWith[current] ?? [])
                    .filter { !seen.contains($0) }
                    .sorted { lhs, rhs in
                        (names.firstIndex(of: lhs) ?? 0) < (names.firstIndex(of: rhs) ?? 0)
                    }
                stack.append(contentsOf: neighbours.reversed())
            }
        }
        return ordered
    }

    /// 一覧を見出し付きに組み直す。
    ///
    /// 複数の束に属する項目は**その全部に現れる**。一つを選ばせないための複数所属なので、
    /// 一箇所にしか出さないなら意味がない。同じ実体が二行に見えることになるが、
    /// それはタグで束ねたものを平らに並べたときに必ず起きることで、隠す道がない。
    ///
    /// 空の束も見出しを出す。ドラッグの落とし先が無ければ、最初の一個を入れられない。
    ///
    /// 定義にあるが実物が無い名前は黙って落ちる。別のマシンにしか無いフォルダの定義を
    /// 消さずに持っておけるのは、ここで存在を要求しないから。数は
    /// `missingMembers(among:)`で数えられる。
    ///
    /// 束の**中**の順序は`items`の順序をそのまま引き継ぐ。名前で並べるか更新日で並べるかは
    /// 一覧側がすでに決めていることで、束ねる側がそれを上書きすると、列見出しを
    /// クリックしても束の中だけ並び替わらない、という妙な挙動になる。
    /// 束**同士**の順序だけが定義の順。
    func sections(for items: [WorkspaceItem]) -> [WorkspaceGroupSection] {
        var grouped: [WorkspaceGroupSection] = []
        var claimed: Set<String> = []

        for group in groups {
            let members = Set(group.members)
            let matched = items.filter { members.contains($0.name) }
            matched.forEach { claimed.insert($0.name) }
            grouped.append(WorkspaceGroupSection(name: group.name, items: matched))
        }

        let rest = items.filter { !claimed.contains($0.name) }
        guard !rest.isEmpty else { return grouped }
        return grouped + [WorkspaceGroupSection(name: nil, items: rest)]
    }
}
