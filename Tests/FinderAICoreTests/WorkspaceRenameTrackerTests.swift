import FinderAICore
import Foundation
import Testing

/// 外での改名を追うのは、**確かめられるときだけ**。
/// 「同じ時刻に消えて増えた」で結ぶと、別物を束に入れる。
@Suite("外での改名は、確かめられるときだけ追う")
struct WorkspaceRenameTrackerTests {
    private let folder = URL(fileURLWithPath: "/tmp/GitHub", isDirectory: true)

    private func lookup(_ table: [String: String]) -> (String) -> String? {
        { table[$0] }
    }

    @Test("一度見たものが別名で現れたら、同じものだと確かめて結ぶ")
    func followsAProvenRename() {
        var tracker = WorkspaceRenameTracker()
        // 一度目。ここで「finder_AI」の同一性を覚える。
        #expect(tracker.follow(
            directory: folder,
            present: ["finder_AI", "他人のもの"],
            members: ["finder_AI"],
            identity: lookup(["finder_AI": "1:100:0", "他人のもの": "1:200:0"])
        ).isEmpty)

        // 外で finder_AI → finderAI に改名された。同一性は変わらない。
        let renames = tracker.follow(
            directory: folder,
            present: ["finderAI", "他人のもの"],
            members: ["finder_AI"],
            identity: lookup(["finderAI": "1:100:0", "他人のもの": "1:200:0"])
        )
        #expect(renames == [.init(from: "finder_AI", to: "finderAI")])
    }

    @Test("消えたのと増えたのが別物なら、結ばない")
    func doesNotGuess() {
        var tracker = WorkspaceRenameTracker()
        _ = tracker.follow(
            directory: folder,
            present: ["finder_AI"],
            members: ["finder_AI"],
            identity: lookup(["finder_AI": "1:100:0"])
        )
        // finder_AI を消し、無関係な新しいフォルダを作った（同じ読み直しの中で）。
        let renames = tracker.follow(
            directory: folder,
            present: ["まったく新しいもの"],
            members: ["finder_AI"],
            identity: lookup(["まったく新しいもの": "1:999:0"])
        )
        #expect(renames.isEmpty, "同じ時刻に消えて増えただけでは結ばない")
    }

    /// inode は使い回される。作成時刻まで同一性に入れているのはこのため。
    @Test("同じ名前で作り直されたものは、元のものとして扱わない")
    func recreatedFilesAreNotTheSame() {
        var tracker = WorkspaceRenameTracker()
        _ = tracker.follow(
            directory: folder,
            present: ["資料"],
            members: ["資料"],
            identity: lookup(["資料": "1:100:1000"])
        )
        // 消して、同じ inode を再利用した別のものが「新しい名前」で現れた。
        let renames = tracker.follow(
            directory: folder,
            present: ["別の資料"],
            members: ["資料"],
            identity: lookup(["別の資料": "1:100:2000"])
        )
        #expect(renames.isEmpty, "作成時刻が違えば別物")
    }

    @Test("アプリを閉じているあいだの改名は追えない。黙って結ばない")
    func cannotFollowWhatItNeverSaw() {
        var tracker = WorkspaceRenameTracker()
        // 初回の読み直しで、既にメンバーが居ない（閉じているあいだに改名された）。
        let renames = tracker.follow(
            directory: folder,
            present: ["finderAI"],
            members: ["finder_AI"],
            identity: lookup(["finderAI": "1:100:0"])
        )
        #expect(renames.isEmpty)
    }

    @Test("フォルダが変わったら、覚えていることは捨てる")
    func forgetsWhenTheFolderChanges() {
        var tracker = WorkspaceRenameTracker()
        _ = tracker.follow(
            directory: folder,
            present: ["資料"],
            members: ["資料"],
            identity: lookup(["資料": "1:100:0"])
        )
        // 隣のフォルダにも同じ名前がある。持ち越すと別のフォルダのものと結ぶ。
        let other = URL(fileURLWithPath: "/tmp/別のフォルダ", isDirectory: true)
        let renames = tracker.follow(
            directory: other,
            present: ["新しい資料"],
            members: ["資料"],
            identity: lookup(["新しい資料": "1:100:0"])
        )
        #expect(renames.isEmpty)
    }

    /// 迷子が居るフォルダは、読み直すたびに候補を探すことになる。
    /// 前に見たときから増えた名前だけを候補にして、全項目のstatを避ける。
    @Test("同じ一覧を読み直しても、候補を探し直さない")
    func onlyLooksAtWhatAppeared() {
        var tracker = WorkspaceRenameTracker()
        var asked: [String] = []
        func identity(_ name: String) -> String? {
            asked.append(name)
            return ["a": "1:1:0", "b": "1:2:0", "c": "1:3:0"][name]
        }
        _ = tracker.follow(
            directory: folder,
            present: ["a", "b", "c"],
            members: ["a", "居ないもの"],
            identity: identity
        )
        asked.removeAll()
        // 何も変わっていない読み直し。迷子は居るが、増えた名前は無い。
        _ = tracker.follow(
            directory: folder,
            present: ["a", "b", "c"],
            members: ["a", "居ないもの"],
            identity: identity
        )
        #expect(asked.isEmpty, "増えた名前が無ければ何も見に行かない: \(asked)")
    }
}
