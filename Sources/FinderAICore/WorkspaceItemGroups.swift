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
    /// 一覧を見出し付きに組み直す。
    ///
    /// 複数の束に属する項目は**その全部に現れる**。一つを選ばせないための複数所属なので、
    /// 一箇所にしか出さないなら意味がない。同じ実体が二行に見えることになるが、
    /// それはタグで束ねたものを平らに並べたときに必ず起きることで、隠す side がない。
    ///
    /// 空の束も見出しを出す。ドラッグの落とし先が無ければ、最初の一個を入れられない。
    ///
    /// 定義にあるが実物が無い名前は黙って落ちる。別のマシンにしか無いフォルダの定義を
    /// 消さずに持っておけるのは、ここで存在を要求しないから。
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
