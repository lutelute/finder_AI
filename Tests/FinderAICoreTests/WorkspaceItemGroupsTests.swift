import FinderAICore
import Foundation
import Testing

/// フォルダを作らずに束ねるための定義。実体を動かさないことが目的なので、
/// 「定義をいじってもフォルダは無事」「フォルダが動いても定義は無事」の両方が要る。
@Suite("実体を動かさずに束ねる")
struct WorkspaceItemGroupsTests {
    private func item(_ name: String, isDirectory: Bool = true) -> WorkspaceItem {
        WorkspaceItem(
            url: URL(fileURLWithPath: "/tmp/GitHub").appendingPathComponent(name),
            name: name,
            isDirectory: isDirectory,
            isHidden: false,
            fileSize: nil,
            modifiedAt: nil,
            typeDescription: isDirectory ? "フォルダ" : "ファイル"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - 複数所属

    /// 「ツール開発でもありSwiftでもある」を分類の失敗にしない。排他にすると
    /// どちらかを選ばせることになる、というのがそもそも複数所属を許す理由。
    @Test("一つの項目が複数の束に属せる")
    func memberBelongsToSeveralGroups() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "Swift")

        #expect(groups.groupNames(for: "finder_AI") == ["ツール開発", "Swift"])
    }

    @Test("複数所属の項目は、属する束の全部に並ぶ")
    func multiGroupItemAppearsInEachSection() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "Swift")

        let sections = groups.sections(for: [item("finder_AI")])

        #expect(sections.map(\.name) == ["ツール開発", "Swift"])
        #expect(sections.allSatisfy { $0.items.map(\.name) == ["finder_AI"] })
    }

    /// 片方から外しても、もう片方には残る。ここが排他との一番の違いで、
    /// 「ツール開発から出したらSwiftからも消えた」は複数所属の意味を壊す。
    @Test("一つの束から外しても、他の束には残る")
    func removingFromOneGroupKeepsTheOther() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "Swift")

        groups.remove("finder_AI", from: "ツール開発")

        #expect(groups.groupNames(for: "finder_AI") == ["Swift"])
    }

    @Test("同じ束に二度入れても、一行しか並ばない")
    func addingTwiceIsIdempotent() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "ツール開発")

        #expect(groups.sections(for: [item("finder_AI")])[0].items.count == 1)
    }

    @Test("削除された項目は、全部の束から外せる")
    func removingFromEverywhere() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "Swift")
        groups.add("claude-skills", to: "ツール開発")

        groups.removeFromAllGroups("finder_AI")

        #expect(groups.groupNames(for: "finder_AI").isEmpty)
        #expect(groups.groupNames(for: "claude-skills") == ["ツール開発"])
    }

    // MARK: - 見出し

    @Test("どこにも属さないものは、最後に未分類として並ぶ")
    func ungroupedGoesLast() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")

        let sections = groups.sections(for: [item("finder_AI"), item("lecture_control")])

        #expect(sections.count == 2)
        #expect(sections[0].name == "ツール開発")
        #expect(sections[1].isUngrouped)
        #expect(sections[1].items.map(\.name) == ["lecture_control"])
    }

    @Test("全部が束に入っていれば、未分類の見出しは出ない")
    func noUngroupedSectionWhenEverythingIsGrouped() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")

        let sections = groups.sections(for: [item("finder_AI")])

        #expect(sections.count == 1)
        #expect(sections.contains { $0.isUngrouped } == false)
    }

    /// 空の束にも見出しが要る。落とし先が無ければ最初の一個を入れられない。
    @Test("空の束にも見出しが出る")
    func emptyGroupStillGetsAHeader() {
        let groups = WorkspaceItemGroups(groups: [.init(name: "研究", members: [])])

        let sections = groups.sections(for: [item("finder_AI")])

        #expect(sections[0].name == "研究")
        #expect(sections[0].items.isEmpty)
    }

    /// 別のマシンにしか無いフォルダの定義を消さずに持っておけるのは、
    /// 見出しを組むときに実物の存在を要求しないから。
    @Test("実物が無いメンバーは黙って落ちるだけで、定義からは消えない")
    func missingMemberIsSkippedNotDeleted() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("別マシンにしかない", to: "ツール開発")

        let sections = groups.sections(for: [item("finder_AI")])

        #expect(sections[0].items.map(\.name) == ["finder_AI"])
        #expect(groups.groups[0].members.contains("別マシンにしかない"))
    }

    @Test("束同士の順序は定義した順")
    func groupOrderFollowsDefinition() {
        var groups = WorkspaceItemGroups()
        groups.add("zebra", to: "あとの束")
        groups.add("mango", to: "さきの束")
        groups.groups.reverse()

        let sections = groups.sections(for: [item("zebra"), item("mango")])

        #expect(sections.map(\.name) == ["さきの束", "あとの束"])
    }

    /// 並び順を決めるのは一覧の列見出しであって、束ねる側ではない。ここで並べ替えると
    /// 「更新日で並べたのに束の中だけ名前順のまま」になる。
    @Test("束の中の順序は、渡された並びのまま")
    func itemOrderIsPreserved() {
        var groups = WorkspaceItemGroups()
        for name in ["zebra", "apple", "mango"] { groups.add(name, to: "束") }

        // 更新日順のつもりで、名前順ではない並びを渡す
        let sections = groups.sections(for: [item("zebra"), item("mango"), item("apple")])

        #expect(sections[0].items.map(\.name) == ["zebra", "mango", "apple"])
    }

    @Test("未分類の中も、渡された並びのまま")
    func ungroupedOrderIsPreserved() {
        let groups = WorkspaceItemGroups(groups: [.init(name: "束", members: ["mango"])])

        let sections = groups.sections(for: [item("zebra"), item("mango"), item("apple")])

        #expect(sections[1].items.map(\.name) == ["zebra", "apple"])
    }

    // MARK: - 束そのものを直す

    /// 作れるのに名前を変えられないと、間違えた名前を直すにはJSONを手で開くしかない。
    @Test("束の名前を変えても、中身と並び順は変わらない")
    func renamingKeepsMembersAndOrder() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール")
        groups.add("lec_mpc", to: "講義")

        let renamed = groups.rename("ツール", to: "ツール開発")
        #expect(renamed)

        #expect(groups.groups.map(\.name) == ["ツール開発", "講義"])
        #expect(groups.groupNames(for: "finder_AI") == ["ツール開発"])
    }

    /// 黙って統合すると二つの束が一つに溶けて元に戻せない。断るほうが安全。
    @Test("すでにある名前へは変えない — 黙って一つにまとめない")
    func renamingToAnExistingNameIsRefused() {
        var groups = WorkspaceItemGroups()
        groups.add("a", to: "甲")
        groups.add("b", to: "乙")

        let refused = groups.rename("甲", to: "乙")
        #expect(refused == false)
        #expect(groups.groups.map(\.name) == ["甲", "乙"])
        #expect(groups.groupNames(for: "a") == ["甲"])
    }

    @Test("空の名前や同じ名前への変更は何もしない")
    func renamingToNothingIsRefused() {
        var groups = WorkspaceItemGroups()
        groups.add("a", to: "甲")

        let blank = groups.rename("甲", to: "   ")
        let same = groups.rename("甲", to: "甲")
        #expect(blank == false)
        #expect(same == false)
        #expect(groups.groups.map(\.name) == ["甲"])
    }

    /// 束は「どれとどれが同じか」の記述にすぎない。解いてもフォルダは減らない。
    @Test("束を解くと、中のものは束から外れるだけ")
    func removingAGroupOnlyUnbinds() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール")
        groups.add("finder_AI", to: "Swift")

        groups.removeGroup("ツール")

        #expect(groups.groups.map(\.name) == ["Swift"])
        // もう片方の束には残る
        #expect(groups.groupNames(for: "finder_AI") == ["Swift"])
    }

    @Test("束の並びを動かせる — 地図の枡と見出しの順が変わる")
    func movingAGroupChangesOrder() {
        var groups = WorkspaceItemGroups()
        for name in ["一", "二", "三"] { groups.add("x\(name)", to: name) }

        groups.move("三", by: -1)
        #expect(groups.groups.map(\.name) == ["一", "三", "二"])

        // 端を越える動きは何もしない
        groups.move("一", by: -1)
        #expect(groups.groups.map(\.name) == ["一", "三", "二"])
    }

    // MARK: - 見つからないメンバー

    /// フォルダを消したり別の場所へ動かすと、定義に名前だけが残る。見出しを組む
    /// ときは黙って落としているので、数えて見せられないと気づけない。
    @Test("定義にあって実物が無いものを数えられる")
    func missingMembersAreCounted() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("消したフォルダ", to: "ツール開発")
        groups.add("これも無い", to: "講義")

        let missing = groups.missingMembers(among: [item("finder_AI")])

        #expect(missing["ツール開発"] == ["消したフォルダ"])
        #expect(missing["講義"] == ["これも無い"])
    }

    @Test("全部そろっていれば、見つからないものは無い")
    func nothingMissingWhenAllPresent() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")

        #expect(groups.missingMembers(among: [item("finder_AI")]).isEmpty)
    }

    /// 実在するかどうかは表示設定とは無関係。一覧に見えているものだけで判定すると、
    /// 束に入れた `.claude` のような隠しフォルダが、隠し表示をオフにしただけで
    /// 「見つからない」に化ける。
    @Test("隠しファイルは、隠れているだけで見つからないとは言わない")
    func hiddenMembersAreNotMissing() {
        var groups = WorkspaceItemGroups()
        groups.add(".claude", to: "設定")
        groups.add("消したフォルダ", to: "設定")

        // 一覧には出ていないが、フォルダには実在する
        let missing = groups.missingMembers(amongNames: [".claude", "finder_AI"])

        #expect(missing["設定"] == ["消したフォルダ"])
    }

    @Test("見つからないものだけを外せる — 残っているものは触らない")
    func pruningKeepsWhatExists() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("消したフォルダ", to: "ツール開発")
        groups.add(".claude", to: "ツール開発")

        groups.pruneMissingMembers(amongNames: ["finder_AI", ".claude"])

        #expect(groups.groups[0].members == ["finder_AI", ".claude"])
        #expect(groups.missingMembers(amongNames: ["finder_AI", ".claude"]).isEmpty)
    }

    /// 空になった束は残す。落とし先として見出しが要るし、消してしまうと
    /// 「整理したら束ごと消えた」という取り返しのつかない操作になる。
    @Test("整理して空になっても、束そのものは残る")
    func pruningKeepsEmptyGroups() {
        var groups = WorkspaceItemGroups()
        groups.add("消したフォルダ", to: "ツール開発")

        groups.pruneMissingMembers(amongNames: ["finder_AI"])

        #expect(groups.groups.count == 1)
        #expect(groups.groups[0].members.isEmpty)
    }

    // MARK: - ファイル

    @Test("書いて読んで、同じものが戻る")
    func roundTrip() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "Swift")

        try groups.save(to: root)

        #expect(try WorkspaceItemGroups.load(from: root) == groups)
    }

    @Test("定義が無いフォルダはnil — 束のないフォルダは異常ではない")
    func absentDefinitionIsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try WorkspaceItemGroups.load(from: root) == nil)
    }

    /// 壊れたJSONを「空の定義」として読むと、次の保存が正常な空ファイルで上書きして、
    /// 手で書いた束を本当に消す。読めなかったことは読めなかったこととして返す。
    @Test("壊れた定義は空ではなくエラー — 黙って上書きさせない")
    func brokenDefinitionThrows() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{ これはJSONではない".utf8)
            .write(to: WorkspaceItemGroups.definitionURL(in: root))

        #expect(throws: (any Error).self) { try WorkspaceItemGroups.load(from: root) }
    }

    /// 相対名で持つから、フォルダごと移動しても同期先の別マシンで開いても生きる。
    @Test("フォルダごと移動しても定義は生きる")
    func definitionSurvivesMovingTheFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        try groups.save(to: root)

        let moved = root.deletingLastPathComponent()
            .appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }

        let loaded = try #require(try WorkspaceItemGroups.load(from: moved))
        #expect(loaded.sections(for: [item("finder_AI")])[0].name == "ツール開発")
    }

    /// このファイルをgitに入れる人がいる前提。キー順が毎回変われば、
    /// 中身が同じでも差分が出る。
    @Test("保存した定義は、手で読めて差分の安定した形")
    func savedFileIsStableAndReadable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        try groups.save(to: root)

        let first = try Data(contentsOf: WorkspaceItemGroups.definitionURL(in: root))
        try groups.save(to: root)
        let second = try Data(contentsOf: WorkspaceItemGroups.definitionURL(in: root))

        #expect(first == second)
        let text = try #require(String(data: first, encoding: .utf8))
        #expect(text.contains("\n"))
        #expect(text.contains("ツール開発"))
    }
}
