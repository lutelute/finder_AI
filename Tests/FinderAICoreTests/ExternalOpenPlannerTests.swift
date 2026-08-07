import FinderAICore
import Foundation
import Testing

@Suite("外から渡されたものをどの窓へ出すか")
struct ExternalOpenPlannerTests {
    private let folderA = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
    private let folderB = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
    private let file = URL(fileURLWithPath: "/tmp/a/paper.tex")

    private func directory(_ url: URL) -> ExternalOpenTarget {
        ExternalOpenTarget(url: url, isDirectory: true)
    }

    private func item(_ url: URL) -> ExternalOpenTarget {
        ExternalOpenTarget(url: url, isDirectory: false)
    }

    private func steps(
        _ targets: [ExternalOpenTarget],
        availableNewWindows: Int = 10,
        shown: [URL] = []
    ) -> [ExternalOpenPlanner.Step] {
        let shownPaths = Set(shown.map(\.standardizedFileURL.path))
        return ExternalOpenPlanner.steps(
            for: targets,
            availableNewWindows: availableNewWindows,
            isAlreadyShown: { shownPaths.contains($0.path) }
        )
    }

    @Test("見ていた窓は奪わない。どこにも出ていない場所は新しい窓で開く")
    func neverStealsTheWindowYouWereUsing() {
        // 別の場所を映している窓が1枚あっても、そこへ上書きしない。
        let result = steps([directory(folderA)], shown: [folderB])
        #expect(result == [
            .init(folder: folderA.standardizedFileURL, selection: nil, usesNewWindow: true)
        ])
    }

    @Test("既にその場所を映している窓があれば、それを前に出すだけ")
    func reusesTheWindowAlreadyShowingIt() {
        let result = steps([directory(folderA)], shown: [folderA])
        #expect(result == [
            .init(folder: folderA.standardizedFileURL, selection: nil, usesNewWindow: false)
        ])
    }

    @Test("ファイルは入れ物を開いて、その1つを選ぶ")
    func fileOpensItsFolderAndSelectsIt() {
        let result = steps([item(file)])
        #expect(result == [
            .init(
                folder: folderA.standardizedFileURL,
                selection: file.standardizedFileURL,
                usesNewWindow: true
            )
        ])
    }

    @Test("入れ物が既に開いていれば、その窓の中で選ぶ")
    func fileInAnOpenFolderSelectsThere() {
        let result = steps([item(file)], shown: [folderA])
        #expect(result.map(\.usesNewWindow) == [false])
        #expect(result.first?.selection == file.standardizedFileURL)
    }

    @Test("まとめて渡されたら、それぞれ別の窓へ")
    func eachTargetGetsItsOwnWindow() {
        let result = steps([directory(folderA), directory(folderB)])
        #expect(result.map(\.usesNewWindow) == [true, true])
        #expect(result.map(\.folder) == [
            folderA.standardizedFileURL,
            folderB.standardizedFileURL
        ])
    }

    @Test("窓の上限に当たったら、そこで打ち切る")
    func stopsAtTheWindowLimit() {
        let result = steps(
            [directory(folderA), directory(folderB), directory(folderA)],
            availableNewWindows: 1
        )
        // 1枚しか開けないなら1つだけ。残りを同じ窓へ上書きし合っても、
        // 渡した意味が消えるだけ。
        #expect(result.count == 1)
    }

    @Test("既に開いている場所は上限を使わない")
    func alreadyShownDoesNotConsumeTheLimit() {
        let result = steps(
            [directory(folderA), directory(folderB)],
            availableNewWindows: 1,
            shown: [folderA]
        )
        #expect(result.map(\.usesNewWindow) == [false, true])
    }

    @Test("渡されたものが無ければ何もしない")
    func emptyInputProducesNothing() {
        #expect(steps([]).isEmpty)
    }

    @Test("新しい窓を開けず、その場所も出ていないなら何もしない")
    func noRoomAndNotShownProducesNothing() {
        #expect(steps([directory(folderA)], availableNewWindows: 0).isEmpty)
    }
}
