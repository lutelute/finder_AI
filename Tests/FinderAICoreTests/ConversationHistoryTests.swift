import FinderAICore
import Foundation
import Testing

@Suite("このフォルダで何をしたか、AIのログから読む")
struct ConversationHistoryTests {
    // MARK: - フォルダ名の潰れ方

    @Test("英数字以外は、区切りも記号も非ASCIIも、まとめてハイフン1個になる")
    func directoryNameFlattensEverythingButAlphanumerics() {
        #expect(
            ConversationHistory.claudeProjectDirectoryName(
                forPath: "/Users/me/Documents/GitHub/tool_dev_SGNB/finder_AI"
            ) == "-Users-me-Documents-GitHub-tool-dev-SGNB-finder-AI"
        )
        // 実物から採った例。「論文執筆自動化」の7文字が7個のハイフンとして残る。
        #expect(
            ConversationHistory.claudeProjectDirectoryName(
                forPath: "/Users/me/Documents/論文執筆自動化test"
            ) == "-Users-me-Documents--------test"
        )
        // 隠しフォルダの点も、ただのハイフン。
        #expect(
            ConversationHistory.claudeProjectDirectoryName(forPath: "/a/.auto-claude/b")
                == "-a--auto-claude-b"
        )
    }

    @Test("潰れた名前は元に戻せない——別のフォルダが同じ名前になる")
    func flattenedNamesCollide() {
        // だから名前で当たりをつけたあと、必ず実パスで確かめる必要がある。
        let dotted = ConversationHistory.claudeProjectDirectoryName(forPath: "/a/b.c")
        let dashed = ConversationHistory.claudeProjectDirectoryName(forPath: "/a/b-c")
        let underscored = ConversationHistory.claudeProjectDirectoryName(forPath: "/a/b_c")
        #expect(dotted == dashed)
        #expect(dashed == underscored)
    }

    // MARK: - 見出しの整え方

    @Test("改行と連続空白は畳んで、長ければ後ろを落とす")
    func headlineCollapsesAndTruncates() {
        #expect(
            ConversationHistory.condensedHeadline("グループの\n見た目が   好みじゃない")
                == "グループの 見た目が 好みじゃない"
        )
        let long = String(repeating: "あ", count: 80)
        let headline = ConversationHistory.condensedHeadline(long)
        #expect(headline?.count == ConversationHistory.headlineLimit + 1)
        #expect(headline?.hasSuffix("…") == true)
    }

    @Test("ちょうど上限のときは切らない")
    func headlineAtTheLimitKeepsItsTail() {
        let exact = String(repeating: "あ", count: ConversationHistory.headlineLimit)
        #expect(ConversationHistory.condensedHeadline(exact) == exact)
    }

    @Test("本人が書いていない行は見出しにしない")
    func headlineRejectsInjectedText() {
        // これらが出ると、何をした回なのかが読み取れなくなる。
        #expect(ConversationHistory.condensedHeadline("") == nil)
        #expect(ConversationHistory.condensedHeadline("   \n  ") == nil)
        #expect(ConversationHistory.condensedHeadline("<command-name>/clear</command-name>") == nil)
        #expect(ConversationHistory.condensedHeadline("<environment_context><cwd>/a</cwd>") == nil)
        #expect(ConversationHistory.condensedHeadline("Caveat: The messages below…") == nil)
        #expect(ConversationHistory.condensedHeadline("[Request interrupted by user]") == nil)
        #expect(ConversationHistory.condensedHeadline("[FinderAI] 前回の続きに戻れませんでした。") == nil)
        // 索引が「発話なし」を表すために書く印。そのまま出すと、何の回だか
        // 分からない行が並ぶ。
        #expect(ConversationHistory.condensedHeadline("No prompt") == nil)
    }

    @Test("発話の無かった回は、索引の要約で言い当てる")
    func promptlessSessionsFallBackToTheSummary() {
        // 実物から採った形。firstPromptは"No prompt"で、中身はsummaryにある。
        let entry = ConversationHistory.ClaudeSessionsIndex.Entry(
            sessionId: "x",
            firstPrompt: "No prompt",
            summary: "Claude Codeプラグイン複数インストール",
            messageCount: 22,
            modified: nil,
            projectPath: "/a",
            isSidechain: false
        )
        let digest = ConversationHistory.digest(from: entry, fallbackModifiedAt: .distantPast)
        #expect(digest?.headline == "Claude Codeプラグイン複数インストール")
    }

    // MARK: - claudeのtranscript

    @Test("最初のユーザー発話を1本だけ拾う")
    func claudeHeadlineTakesTheFirstRealPrompt() {
        let lines = [
            #"{"type":"summary","summary":"Something"}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/init</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"読み込みが遅い理由ある？"}}"#,
            #"{"type":"user","message":{"role":"user","content":"二つ目は要らない"}}"#
        ]
        #expect(ConversationHistory.headline(fromClaudeTranscript: lines) == "読み込みが遅い理由ある？")
    }

    @Test("contentが部品の配列でも読める。tool_resultだけの行は飛ばす")
    func claudeHeadlineReadsBlockContent() {
        let lines = [
            // ツールの戻りだけの行。textが無いので見出しにならない。
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"はい"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"PRをマージして"}]}}"#
        ]
        #expect(ConversationHistory.headline(fromClaudeTranscript: lines) == "PRをマージして")
    }

    @Test("壊れた行があっても止まらない")
    func brokenLinesAreSkipped() {
        let lines = [
            "{ これはJSONではない",
            "",
            #"{"type":"user","message":{"role":"user","content":"続けて"}}"#
        ]
        #expect(ConversationHistory.headline(fromClaudeTranscript: lines) == "続けて")
    }

    @Test("transcriptが名乗る作業フォルダを取る")
    func claudeTranscriptReportsItsDirectory() {
        let lines = [
            #"{"type":"last-prompt","leafUuid":"x"}"#,
            #"{"type":"user","cwd":"/Users/me/finder_AI","message":{"role":"user","content":"やあ"}}"#
        ]
        #expect(
            ConversationHistory.workingDirectory(fromClaudeTranscript: lines) == "/Users/me/finder_AI"
        )
        #expect(ConversationHistory.workingDirectory(fromClaudeTranscript: []) == nil)
    }

    // MARK: - codexのrollout

    @Test("codexは先頭のsession_metaにフォルダを書いている")
    func codexRolloutReportsItsDirectory() {
        let lines = [
            #"{"type":"session_meta","payload":{"cwd":"/Users/me/finder_AI","id":"019f"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        ]
        #expect(
            ConversationHistory.workingDirectory(fromCodexRollout: lines) == "/Users/me/finder_AI"
        )
    }

    @Test("codexのuser発話は、最初に環境の説明が挟まる")
    func codexHeadlineSkipsEnvironmentContext() {
        let lines = [
            #"{"type":"session_meta","payload":{"cwd":"/a"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"あなたはCodexです"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context><cwd>/a</cwd></environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"第3章の演習を作って"}]}}"#
        ]
        #expect(ConversationHistory.headline(fromCodexRollout: lines) == "第3章の演習を作って")
    }

    @Test("rolloutのファイル名の末尾がセッションID")
    func codexSessionIDComesFromTheFileName() {
        #expect(
            ConversationHistory.codexSessionID(
                fromFileName: "rollout-2026-08-03T15-30-20-019fc650-edb4-7de3-83ba-b1d81f8203da.jsonl"
            ) == "019fc650-edb4-7de3-83ba-b1d81f8203da"
        )
        #expect(ConversationHistory.codexSessionID(fromFileName: "notes.jsonl") == nil)
    }

    // MARK: - claudeの索引

    @Test("索引があれば、開くのはそれ1枚で済む")
    func indexEntryBecomesADigest() throws {
        let json = #"""
        {
          "version": 1,
          "entries": [
            {
              "sessionId": "9a572b73",
              "firstPrompt": "これも論文作って。フルペーパー",
              "summary": "Grokking Paper: Clone, Write, Convert",
              "messageCount": 25,
              "modified": "2026-01-19T19:43:54.545Z",
              "projectPath": "/Users/me/Documents/論文執筆自動化test",
              "isSidechain": false
            }
          ],
          "originalPath": "/Users/me/Documents/論文執筆自動化test"
        }
        """#
        let index = try JSONDecoder().decode(
            ConversationHistory.ClaudeSessionsIndex.self,
            from: Data(json.utf8)
        )
        #expect(index.originalPath == "/Users/me/Documents/論文執筆自動化test")
        let entry = try #require(index.entries.first)
        let digest = try #require(ConversationHistory.digest(from: entry, fallbackModifiedAt: .distantPast))
        // 要約より本人の言葉を先に見る。読んで思い出せるのはこちら。
        #expect(digest.headline == "これも論文作って。フルペーパー")
        #expect(digest.messageCount == 25)
        #expect(digest.modifiedAt != .distantPast)
        #expect(digest.kind == .claude)
    }

    @Test("枝分かれした会話は一覧に出さない")
    func sidechainsAreNotListed() {
        let entry = ConversationHistory.ClaudeSessionsIndex.Entry(
            sessionId: "x",
            firstPrompt: "サブエージェントの指示",
            summary: nil,
            messageCount: 3,
            modified: nil,
            projectPath: "/a",
            isSidechain: true
        )
        #expect(ConversationHistory.digest(from: entry, fallbackModifiedAt: .distantPast) == nil)
    }

    @Test("本人の言葉が無いときだけ、AIの付けた要約に落ちる")
    func summaryIsTheFallback() {
        let entry = ConversationHistory.ClaudeSessionsIndex.Entry(
            sessionId: "x",
            firstPrompt: "<command-name>/resume</command-name>",
            summary: "Fix the sidebar",
            messageCount: nil,
            modified: nil,
            projectPath: "/a",
            isSidechain: false
        )
        let digest = ConversationHistory.digest(from: entry, fallbackModifiedAt: .distantPast)
        #expect(digest?.headline == "Fix the sidebar")
    }
}
