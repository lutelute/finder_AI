import FinderAICore
import Foundation
import SQLite3
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

    // MARK: - agyのtranscript・索引

    @Test("agyのworkspace_urisからfile URIをデコードして実パスへ戻す")
    func agyWorkspaceURIsDecodePaths() {
        #expect(
            ConversationHistory.agyWorkspacePaths(
                fromJSON: #"["file:///Users/me/dev/finder_AI","file:///Users/me/%E8%AB%96%E6%96%87%20test"]"#
            ) == ["/Users/me/dev/finder_AI", "/Users/me/論文 test"]
        )
        #expect(ConversationHistory.agyWorkspacePaths(fromJSON: "") == [])
        #expect(ConversationHistory.agyWorkspacePaths(fromJSON: "not-json") == [])
    }

    @Test("agyのtranscriptはUSER_REQUESTの中身だけを抜き出す")
    func agyTranscriptExtractsUserRequest() {
        let lines = [
            #"{"step_index":0,"source":"SYSTEM","type":"USER_INPUT","content":"<USER_REQUEST>\n内部指示\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\nfinderAIにagyも追加しておいて。\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nnow\n</ADDITIONAL_METADATA>"}"#,
            #"{"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\n二つ目は要らない\n</USER_REQUEST>"}"#
        ]
        #expect(
            ConversationHistory.headline(fromAgyTranscript: lines) == "finderAIにagyも追加しておいて。"
        )
    }

    @Test("agyのマイクロ秒付きUTC日時をパースできる")
    func agyTimestampsParseAcrossFractionalWidths() {
        #expect(ConversationHistory.parseAgyTimestamp("2026-11-26 00:46:20.119858+00:00") != nil)
        #expect(ConversationHistory.parseAgyTimestamp("2026-11-25 16:12:36.8188+00:00") != nil)
        #expect(ConversationHistory.parseAgyTimestamp("2026-11-26 00:46:20+00:00") != nil)
        #expect(ConversationHistory.parseAgyTimestamp("2026-11-26T00:44:00Z") != nil)
        #expect(ConversationHistory.parseAgyTimestamp("") == nil)
    }

    @Test("agyのSQLite索引から対象フォルダのトップレベル会話だけを新しい順に拾う")
    func agyDigestsReadsSummariesAndTranscripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-agy-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetDir = URL(fileURLWithPath: "/Users/me/dev/finder_AI", isDirectory: true)
        let dbURL = root.appendingPathComponent(ConversationHistory.agySummaryDatabaseName)
        try createAgySummaryDatabase(at: dbURL, rows: [
            // transcriptがある最新回。本人の発話を優先する。
            (
                id: "conv-latest",
                title: "Task Completion Check",
                preview: "Task Completion Check",
                modified: "2026-11-26 00:46:20.119858+00:00",
                uris: #"["file:///Users/me/dev/finder_AI"]"#,
                parentID: "",
                depth: 0
            ),
            // transcriptが無い回はpreviewに落ちる。
            (
                id: "conv-preview",
                title: "Summary Title",
                preview: "sidebarの色を調整する",
                modified: "2026-11-25 10:00:00.12+00:00",
                uris: #"["file:///Users/me/dev/finder_AI"]"#,
                parentID: "",
                depth: 0
            ),
            // previewも空ならtitleに落ちる。
            (
                id: "conv-title-only",
                title: "リリース前の確認",
                preview: "",
                modified: "2026-11-24 10:00:00+00:00",
                uris: #"["file:///Users/me/dev/finder_AI"]"#,
                parentID: "",
                depth: 0
            ),
            // サブエージェントは除外する。
            (
                id: "conv-subagent",
                title: "Subagent",
                preview: "サブエージェントの作業",
                modified: "2026-11-26 01:00:00+00:00",
                uris: #"["file:///Users/me/dev/finder_AI"]"#,
                parentID: "conv-latest",
                depth: 1
            ),
            // 別フォルダは除外する。
            (
                id: "conv-other",
                title: "Other Project",
                preview: "別フォルダの作業",
                modified: "2026-11-26 02:00:00+00:00",
                uris: #"["file:///Users/me/dev/other"]"#,
                parentID: "",
                depth: 0
            )
        ])

        let transcriptDir = root
            .appendingPathComponent("brain/conv-latest/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcript = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\\nfinderAIにagyも追加しておいて。\\n</USER_REQUEST>"}
        """
        try transcript.write(
            to: transcriptDir.appendingPathComponent("transcript.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let digests = ConversationHistory.agyDigests(forDirectory: targetDir, dataRoot: root, limit: 5)
        #expect(digests.map(\.sessionID) == ["conv-latest", "conv-preview", "conv-title-only"])
        #expect(digests.allSatisfy { $0.kind == .agy })
        #expect(digests.map(\.headline) == [
            "finderAIにagyも追加しておいて。",
            "sidebarの色を調整する",
            "リリース前の確認"
        ])

        // limitが効く。
        let limited = ConversationHistory.agyDigests(forDirectory: targetDir, dataRoot: root, limit: 2)
        #expect(limited.map(\.sessionID) == ["conv-latest", "conv-preview"])
    }

    @Test("recentDigestsはclaude・codex・agyを混ぜて新しい順に並べる")
    func recentDigestsMergesClaudeCodexAndAgy() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let targetDir = URL(fileURLWithPath: "/Users/me/dev/merged", isDirectory: true)

        // claude（中間の時刻）
        let claudeDir = ConversationHistory.defaultClaudeProjectsRoot(homeDirectory: home)
            .appendingPathComponent(
                ConversationHistory.claudeProjectDirectoryName(forPath: targetDir.path),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeIndex = """
        {"version":1,"originalPath":"/Users/me/dev/merged","entries":[
          {"sessionId":"claude-1","firstPrompt":"Claudeの作業","modified":"2026-11-25T12:00:00Z","projectPath":"/Users/me/dev/merged"}
        ]}
        """
        try claudeIndex.write(
            to: claudeDir.appendingPathComponent(ConversationHistory.claudeIndexFileName),
            atomically: true,
            encoding: .utf8
        )

        // agy（最新）
        let agyRoot = ConversationHistory.defaultAgyDataRoot(homeDirectory: home)
        try FileManager.default.createDirectory(at: agyRoot, withIntermediateDirectories: true)
        try createAgySummaryDatabase(
            at: agyRoot.appendingPathComponent(ConversationHistory.agySummaryDatabaseName),
            rows: [(
                id: "agy-1",
                title: "",
                preview: "AGYの作業",
                modified: "2026-11-26 09:00:00+00:00",
                uris: #"["file:///Users/me/dev/merged"]"#,
                parentID: "",
                depth: 0
            )]
        )

        let merged = ConversationHistory.recentDigests(forDirectory: targetDir, homeDirectory: home, limit: 5)
        #expect(merged.map(\.kind) == [.agy, .claude])
        #expect(merged.map(\.headline) == ["AGYの作業", "Claudeの作業"])
    }

    private func createAgySummaryDatabase(
        at url: URL,
        rows: [(id: String, title: String, preview: String, modified: String, uris: String, parentID: String, depth: Int)]
    ) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let createSQL = """
        CREATE TABLE conversation_summaries (
            conversation_id text PRIMARY KEY,
            title text NOT NULL DEFAULT "",
            preview text NOT NULL DEFAULT "",
            last_modified_time datetime NOT NULL,
            workspace_uris text NOT NULL,
            parent_conversation_id text NOT NULL DEFAULT "",
            nesting_depth integer NOT NULL DEFAULT 0
        );
        """
        #expect(sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK)

        let insertSQL = """
        INSERT INTO conversation_summaries
            (conversation_id, title, preview, last_modified_time, workspace_uris, parent_conversation_id, nesting_depth)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, row.id, -1, transient)
            sqlite3_bind_text(stmt, 2, row.title, -1, transient)
            sqlite3_bind_text(stmt, 3, row.preview, -1, transient)
            sqlite3_bind_text(stmt, 4, row.modified, -1, transient)
            sqlite3_bind_text(stmt, 5, row.uris, -1, transient)
            sqlite3_bind_text(stmt, 6, row.parentID, -1, transient)
            sqlite3_bind_int(stmt, 7, Int32(row.depth))
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }
}
