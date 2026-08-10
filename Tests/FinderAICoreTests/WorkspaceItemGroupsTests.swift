import FinderAICore
import Foundation
import Testing

/// フォルダを作らずにまとめるための定義。実体を動かさないことが目的なので、
/// 「定義をいじってもフォルダは無事」「フォルダが動いても定義は無事」の両方が要る。
@Suite("実体を動かさずにまとめる")
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
    @Test("一つの項目が複数のグループに属せる")
    func memberBelongsToSeveralGroups() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "Swift")

        #expect(groups.groupNames(for: "finder_AI") == ["ツール開発", "Swift"])
    }

    @Test("複数所属の項目は、属するグループの全部に並ぶ")
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
    @Test("一つのグループから外しても、他のグループには残る")
    func removingFromOneGroupKeepsTheOther() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "Swift")

        groups.remove("finder_AI", from: "ツール開発")

        #expect(groups.groupNames(for: "finder_AI") == ["Swift"])
    }

    @Test("同じグループに二度入れても、一行しか並ばない")
    func addingTwiceIsIdempotent() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")
        groups.add("finder_AI", to: "ツール開発")

        #expect(groups.sections(for: [item("finder_AI")])[0].items.count == 1)
    }

    @Test("削除された項目は、全部のグループから外せる")
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

    @Test("全部がグループに入っていれば、未分類の見出しは出ない")
    func noUngroupedSectionWhenEverythingIsGrouped() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")

        let sections = groups.sections(for: [item("finder_AI")])

        #expect(sections.count == 1)
        #expect(sections.contains { $0.isUngrouped } == false)
    }

    /// 空のグループにも見出しが要る。落とし先が無ければ最初の一個を入れられない。
    @Test("空のグループにも見出しが出る")
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

    @Test("グループ同士の順序は定義した順")
    func groupOrderFollowsDefinition() {
        var groups = WorkspaceItemGroups()
        groups.add("zebra", to: "あとのグループ")
        groups.add("mango", to: "さきのグループ")
        groups.groups.reverse()

        let sections = groups.sections(for: [item("zebra"), item("mango")])

        #expect(sections.map(\.name) == ["さきのグループ", "あとのグループ"])
    }

    /// 並び順を決めるのは一覧の列見出しであって、まとめる側ではない。ここで並べ替えると
    /// 「更新日で並べたのにグループの中だけ名前順のまま」になる。
    @Test("グループの中の順序は、渡された並びのまま")
    func itemOrderIsPreserved() {
        var groups = WorkspaceItemGroups()
        for name in ["zebra", "apple", "mango"] { groups.add(name, to: "グループ") }

        // 更新日順のつもりで、名前順ではない並びを渡す
        let sections = groups.sections(for: [item("zebra"), item("mango"), item("apple")])

        #expect(sections[0].items.map(\.name) == ["zebra", "mango", "apple"])
    }

    @Test("未分類の中も、渡された並びのまま")
    func ungroupedOrderIsPreserved() {
        let groups = WorkspaceItemGroups(groups: [.init(name: "グループ", members: ["mango"])])

        let sections = groups.sections(for: [item("zebra"), item("mango"), item("apple")])

        #expect(sections[1].items.map(\.name) == ["zebra", "apple"])
    }

    // MARK: - 入れ子（A ∈ B）

    @Test("グループを別のグループの中に入れられる")
    func nestingPutsAGroupInsideAnother() {
        var groups = WorkspaceItemGroups()
        groups.add("x", to: "研究")
        groups.add("y", to: "電力系統")

        let nested = groups.nest("電力系統", inside: "研究")

        #expect(nested)
        #expect(groups.depth(of: "電力系統") == 1)
        #expect(groups.depth(of: "研究") == 0)
        #expect(groups.ancestors(of: "電力系統") == ["研究"])
        #expect(groups.children(of: "研究") == ["電力系統"])
    }

    /// ユーザーの言葉:「複数で C ∈ B とかもあるし」。一つの親に複数の子が入る。
    @Test("一つの親に複数のグループが入る")
    func severalGroupsShareAParent() {
        var groups = WorkspaceItemGroups()
        for name in ["研究", "電力系統", "可視化"] { groups.add("x-\(name)", to: name) }

        groups.nest("電力系統", inside: "研究")
        groups.nest("可視化", inside: "研究")

        #expect(groups.children(of: "研究") == ["電力系統", "可視化"])
        #expect(groups.children(of: nil) == ["研究"])
    }

    @Test("三段まで入れ子にできる")
    func nestingGoesDeeper() {
        var groups = WorkspaceItemGroups()
        for name in ["A", "B", "C"] { groups.add("x-\(name)", to: name) }

        groups.nest("B", inside: "A")
        groups.nest("C", inside: "B")

        #expect(groups.depth(of: "C") == 2)
        #expect(groups.ancestors(of: "C") == ["B", "A"])
    }

    /// 輪を許すと、親をたどる処理が無限に回る。
    @Test("輪になる入れ子は断る")
    func cyclicNestingIsRefused() {
        var groups = WorkspaceItemGroups()
        for name in ["A", "B"] { groups.add("x-\(name)", to: name) }
        groups.nest("B", inside: "A")

        let cycle = groups.nest("A", inside: "B")
        let selfNest = groups.nest("A", inside: "A")

        #expect(cycle == false)
        #expect(selfNest == false)
        #expect(groups.depth(of: "A") == 0)
    }

    @Test("居ない親は指せない")
    func nestingUnderAnUnknownParentIsRefused() {
        var groups = WorkspaceItemGroups()
        groups.add("x", to: "A")

        let refused = groups.nest("A", inside: "居ないグループ")

        #expect(refused == false)
        #expect(groups.depth(of: "A") == 0)
    }

    @Test("nilを渡すと最上位へ戻る")
    func nestingToNilLiftsToTheTop() {
        var groups = WorkspaceItemGroups()
        for name in ["A", "B"] { groups.add("x-\(name)", to: name) }
        groups.nest("B", inside: "A")

        groups.nest("B", inside: nil)

        #expect(groups.depth(of: "B") == 0)
        #expect(groups.children(of: "A").isEmpty)
    }

    /// 一覧の見出しの順であり、地図で枡を割る順でもある。親のすぐ下に子が来る。
    @Test("入れ子を保った並びは、親のすぐ下に子が来る")
    func nestedOrderIsDepthFirst() {
        var groups = WorkspaceItemGroups()
        for name in ["研究", "電力系統", "可視化", "講義"] { groups.add("x-\(name)", to: name) }
        groups.nest("電力系統", inside: "研究")
        groups.nest("可視化", inside: "研究")

        #expect(groups.nestedOrderedNames() == ["研究", "電力系統", "可視化", "講義"])
    }

    /// 親を消したせいで子が一覧から消えるのは、消したつもりのないものが消えること。
    @Test("親が消えても、子は最上位として残る")
    func orphansSurviveAsTopLevel() {
        var groups = WorkspaceItemGroups()
        for name in ["研究", "電力系統"] { groups.add("x-\(name)", to: name) }
        groups.nest("電力系統", inside: "研究")

        groups.removeGroup("研究")

        #expect(groups.nestedOrderedNames() == ["電力系統"])
        #expect(groups.depth(of: "電力系統") == 0)
    }

    @Test("並びには必ず全部のグループが出る — 数が合わないほうが困る")
    func nestedOrderNeverLosesAGroup() {
        var groups = WorkspaceItemGroups()
        for name in ["A", "B", "C", "D"] { groups.add("x-\(name)", to: name) }
        groups.nest("B", inside: "A")
        groups.nest("D", inside: "C")

        #expect(Set(groups.nestedOrderedNames()) == ["A", "B", "C", "D"])
        #expect(groups.nestedOrderedNames().count == 4)
    }

    /// 入れ子は保存されて戻る。ここが往復しないと、次に開いたとき平らになる。
    @Test("入れ子は書いて読んでも保たれる")
    func nestingSurvivesRoundTrip() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var groups = WorkspaceItemGroups()
        for name in ["研究", "電力系統"] { groups.add("x-\(name)", to: name) }
        groups.nest("電力系統", inside: "研究")

        try groups.save(to: root)
        let loaded = try #require(try WorkspaceItemGroups.load(from: root))

        #expect(loaded.depth(of: "電力系統") == 1)
        #expect(loaded.ancestors(of: "電力系統") == ["研究"])
    }

    // MARK: - グループそのものを直す

    /// 作れるのに名前を変えられないと、間違えた名前を直すにはJSONを手で開くしかない。
    @Test("グループの名前を変えても、中身と並び順は変わらない")
    func renamingKeepsMembersAndOrder() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール")
        groups.add("lec_mpc", to: "講義")

        let renamed = groups.rename("ツール", to: "ツール開発")
        #expect(renamed)

        #expect(groups.groups.map(\.name) == ["ツール開発", "講義"])
        #expect(groups.groupNames(for: "finder_AI") == ["ツール開発"])
    }

    /// 黙って統合すると二つのグループが一つに溶けて元に戻せない。断るほうが安全。
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

    /// グループは「どれとどれが同じか」の記述にすぎない。解除してもフォルダは減らない。
    @Test("グループを解除すると、中のものはグループから外れるだけ")
    func removingAGroupOnlyUnbinds() {
        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール")
        groups.add("finder_AI", to: "Swift")

        groups.removeGroup("ツール")

        #expect(groups.groups.map(\.name) == ["Swift"])
        // もう片方のグループには残る
        #expect(groups.groupNames(for: "finder_AI") == ["Swift"])
    }

    @Test("グループの並びを動かせる — 地図の枡と見出しの順が変わる")
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
    /// グループに入れた `.claude` のような隠しフォルダが、隠し表示をオフにしただけで
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

    /// 空になったグループは残す。落とし先として見出しが要るし、消してしまうと
    /// 「整理したらグループごと消えた」という取り返しのつかない操作になる。
    @Test("整理して空になっても、グループそのものは残る")
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

    @Test("定義が無いフォルダはnil — グループのないフォルダは異常ではない")
    func absentDefinitionIsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try WorkspaceItemGroups.load(from: root) == nil)
    }

    /// 壊れたJSONを「空の定義」として読むと、次の保存が正常な空ファイルで上書きして、
    /// 手で書いたグループを本当に消す。読めなかったことは読めなかったこととして返す。
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
