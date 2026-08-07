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

    @Test("フォルダ1つは今ある窓で開き、新しい窓は増やさない")
    func singleFolderReusesTheOpenWindow() {
        let steps = ExternalOpenPlanner.steps(
            for: [directory(folderA)],
            hasOpenWindow: true,
            availableNewWindows: 10
        )
        #expect(steps == [
            .init(folder: folderA.standardizedFileURL, selection: nil, usesNewWindow: false)
        ])
    }

    @Test("窓が1枚も無ければ、最初の1つから新しい窓を開く")
    func withoutAnyWindowTheFirstOpensOne() {
        let steps = ExternalOpenPlanner.steps(
            for: [directory(folderA)],
            hasOpenWindow: false,
            availableNewWindows: 10
        )
        #expect(steps.map(\.usesNewWindow) == [true])
    }

    @Test("ファイルは入れ物を開いて、その1つを選ぶ")
    func fileOpensItsFolderAndSelectsIt() {
        let steps = ExternalOpenPlanner.steps(
            for: [item(file)],
            hasOpenWindow: true,
            availableNewWindows: 10
        )
        #expect(steps == [
            .init(
                folder: folderA.standardizedFileURL,
                selection: file.standardizedFileURL,
                usesNewWindow: false
            )
        ])
    }

    @Test("まとめて渡されたら、2つ目以降は別の窓へ")
    func laterTargetsGetTheirOwnWindows() {
        let steps = ExternalOpenPlanner.steps(
            for: [directory(folderA), directory(folderB), item(file)],
            hasOpenWindow: true,
            availableNewWindows: 10
        )
        #expect(steps.map(\.usesNewWindow) == [false, true, true])
        #expect(steps.map(\.folder) == [
            folderA.standardizedFileURL,
            folderB.standardizedFileURL,
            folderA.standardizedFileURL
        ])
    }

    @Test("窓の上限に当たったら、そこで打ち切る")
    func stopsAtTheWindowLimit() {
        let steps = ExternalOpenPlanner.steps(
            for: [directory(folderA), directory(folderB), directory(folderA)],
            hasOpenWindow: true,
            availableNewWindows: 1
        )
        // 今ある窓で1つ、新しい窓で1つ。3つ目は開かない——最後の1枚に
        // 上書きし合っても、渡した意味が消えるだけ。
        #expect(steps.count == 2)
    }

    @Test("渡されたものが無ければ何もしない")
    func emptyInputProducesNothing() {
        #expect(ExternalOpenPlanner.steps(
            for: [],
            hasOpenWindow: true,
            availableNewWindows: 10
        ).isEmpty)
    }

    @Test("窓が無く、新しい窓も開けないなら何もしない")
    func noWindowAndNoRoomProducesNothing() {
        #expect(ExternalOpenPlanner.steps(
            for: [directory(folderA)],
            hasOpenWindow: false,
            availableNewWindows: 0
        ).isEmpty)
    }
}
