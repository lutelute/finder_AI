import FinderAICore
@testable import FinderAIApp
import Foundation
import Testing

/// 外での改名を追えるかどうかは、「名前が変わっても同じ」と言える印が
/// 実際のファイルシステムで取れるかにかかっている。作り話ではなく本物で確かめる。
@Suite("ファイルの同一性は、名前が変わっても変わらない")
@MainActor
struct WorkspaceFileIdentityTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("名前を変えても同じ印。別のものとは違う印")
    func identitySurvivesRename() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let before = folder.appendingPathComponent("finder_AI", isDirectory: true)
        let other = folder.appendingPathComponent("他人のもの", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let original = try #require(WorkspaceBrowserViewController.fileIdentity(of: before))
        let othersIdentity = try #require(WorkspaceBrowserViewController.fileIdentity(of: other))
        #expect(original != othersIdentity, "別のものは別の印")

        let after = folder.appendingPathComponent("finderAI", isDirectory: true)
        try FileManager.default.moveItem(at: before, to: after)

        #expect(WorkspaceBrowserViewController.fileIdentity(of: after) == original)
        #expect(WorkspaceBrowserViewController.fileIdentity(of: before) == nil, "無いものには印が無い")
    }

    /// 見張りと本物のファイルを繋いで、定義が実際に書き換わるところまで。
    @Test("外で名前を変えると、束の定義が付いていく")
    func definitionFollowsAnExternalRename() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let before = folder.appendingPathComponent("finder_AI", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)

        var groups = WorkspaceItemGroups()
        groups.add("finder_AI", to: "ツール開発")

        var tracker = WorkspaceRenameTracker()
        func names() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        }
        func follow() throws -> [WorkspaceRenameTracker.Rename] {
            tracker.follow(
                directory: folder,
                present: try names(),
                members: Set(groups.groups.flatMap(\.members)),
                identity: { WorkspaceBrowserViewController.fileIdentity(
                    of: folder.appendingPathComponent($0)
                ) }
            )
        }

        // 一度見ておく（これが無いと確かめようがない）。
        #expect(try follow().isEmpty)

        // アプリの外で名前を変える。
        let after = folder.appendingPathComponent("finderAI", isDirectory: true)
        try FileManager.default.moveItem(at: before, to: after)

        let renames = try follow()
        #expect(renames == [.init(from: "finder_AI", to: "finderAI")])
        for rename in renames { groups.renameMember(rename.from, to: rename.to) }
        #expect(groups.groupNames(for: "finderAI") == ["ツール開発"])
        #expect(groups.missingMembers(amongNames: try names()).isEmpty, "「見つからない」に落ちない")
    }
}
