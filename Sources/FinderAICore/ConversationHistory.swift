import Foundation
import SQLite3

/// 過去の会話1本ぶんの見出し。
///
/// 中身はAI側のログから読み出したものであって、FinderAIが書いたものではない。
/// claude・codex・agyはいずれも自分の会話をディスクに持っているので、同じものを
/// もう一度集める理由が無い——覗いて、日付と最初の一言だけを借りてくる。
public struct ConversationDigest: Equatable, Sendable, Identifiable {
    public var id: String { sessionID }
    public var sessionID: String
    public var kind: TerminalSessionKind
    /// 本人が最初に打った一言。AIの要約ではないので、読めば思い出せる。
    public var headline: String
    public var modifiedAt: Date
    /// 索引があるときだけ分かる。無ければ`nil`のまま表示しない。
    public var messageCount: Int?

    public init(
        sessionID: String,
        kind: TerminalSessionKind,
        headline: String,
        modifiedAt: Date,
        messageCount: Int? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.headline = headline
        self.modifiedAt = modifiedAt
        self.messageCount = messageCount
    }
}

/// AIのログを読んで「このフォルダで何をしたか」を並べる、読み取り専用の窓口。
///
/// 書き込みは一切しない。読む量も抑えてある——1本につき先頭の数十KBだけで、
/// 54MBのtranscriptでも18KBしか触らない。ファイルの大きさは効かない。
public enum ConversationHistory {
    /// 見出しの長さ。これを超えたら後ろを落として「…」を付ける。
    public static let headlineLimit = 60
    /// 1本のログで先頭から何行まで見るか。最初のユーザー発話は普通そこにある。
    public static let scanLineLimit = 120
    /// 同じく、先頭から何バイトまで読むか。行数と両方で頭打ちにする。
    public static let scanByteLimit = 256 * 1024
    /// 一覧に並べる本数の既定。
    public static let defaultLimit = 5
    /// codexは folder 単位の索引を持たないので全部見るしかない。青天井にせず、
    /// 新しい順にこの本数まで。
    public static let codexScanLimit = 400

    // MARK: - フォルダ名の潰れ方

    /// claudeがプロジェクトの置き場に使うフォルダ名。
    ///
    /// 英数字以外は`/`も`_`も`.`も、非ASCIIの1文字も、区別なくハイフン1個になる。
    ///
    /// ```
    /// /Users/me/Documents/論文執筆自動化test
    ///   → -Users-me-Documents--------test
    /// ```
    ///
    /// **戻せない。** 別々のフォルダが同じ名前に化けうるので、この名前は当たりを
    /// つけるためだけに使い、そのフォルダの履歴かどうかは必ず実パスで確かめる。
    public static func claudeProjectDirectoryName(forPath path: String) -> String {
        var name = ""
        name.reserveCapacity(path.utf16.count)
        for unit in path.utf16 {
            let isASCIIAlphanumeric =
                (unit >= 48 && unit <= 57)
                || (unit >= 65 && unit <= 90)
                || (unit >= 97 && unit <= 122)
            if isASCIIAlphanumeric, let scalar = Unicode.Scalar(unit) {
                name.append(Character(scalar))
            } else {
                name.append("-")
            }
        }
        return name
    }

    // MARK: - 見出しの整え方

    /// 生の発話を1行の見出しに直す。表に出せないものは`nil`。
    ///
    /// 弾いているのは、本人が書いていないもの——`<command-name>`のような差し込み、
    /// 再開時の断り書き、中断の記録。これらが見出しに出ると、何をした回なのかが
    /// 分からなくなる。
    public static func condensedHeadline(_ raw: String, limit: Int = headlineLimit) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        guard !collapsed.hasPrefix("<") else { return nil }
        guard !collapsed.hasPrefix("Caveat:") else { return nil }
        guard !collapsed.hasPrefix("[Request interrupted") else { return nil }
        guard !collapsed.hasPrefix("[FinderAI]") else { return nil }
        // claudeの索引は、発話の無かった回に"No prompt"と書き入れる。これは
        // 本人の言葉ではなく「言葉が無い」という印なので、要約のほうへ譲る。
        guard collapsed != "No prompt" else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: - 1行ずつのJSONから拾う

    /// claudeのtranscriptから最初のユーザー発話を1本。
    public static func headline(fromClaudeTranscript lines: [String]) -> String? {
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            guard object["type"] as? String == "user" else { continue }
            guard let text = messageText(object["message"]) else { continue }
            if let headline = condensedHeadline(text) { return headline }
        }
        return nil
    }

    /// claudeのtranscriptが名乗る作業フォルダ。照合はこれでやる。
    public static func workingDirectory(fromClaudeTranscript lines: [String]) -> String? {
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            if let cwd = object["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    /// codexのrolloutから最初のユーザー発話を1本。
    ///
    /// `role == "user"`でも先頭は`<environment_context>`が来る。`<`始まりを
    /// 落とす整形がそのまま効くので、ここでは特別扱いしない。
    public static func headline(fromCodexRollout lines: [String]) -> String? {
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            guard let payload = object["payload"] as? [String: Any] else { continue }
            guard payload["type"] as? String == "message" else { continue }
            guard payload["role"] as? String == "user" else { continue }
            guard let text = messageText(payload) else { continue }
            if let headline = condensedHeadline(text) { return headline }
        }
        return nil
    }

    /// codexのrolloutが名乗る作業フォルダ。先頭行の`session_meta`にある。
    public static func workingDirectory(fromCodexRollout lines: [String]) -> String? {
        for line in lines.prefix(4) {
            guard let object = jsonObject(line) else { continue }
            guard object["type"] as? String == "session_meta" else { continue }
            guard let payload = object["payload"] as? [String: Any] else { continue }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    /// codexのセッションID。rolloutのファイル名の末尾がそれ。
    public static func codexSessionID(fromFileName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropFirst("rollout-".count).dropLast(".jsonl".count)
        // 「日時-UUID」で、UUIDは末尾5つのハイフン区切り。日時側にもハイフンが
        // あるので、後ろから数える。
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    // MARK: - agyのtranscript・索引

    public static let agySummaryDatabaseName = "conversation_summaries.db"

    /// agyのtranscriptから最初のユーザー発話を1本。
    ///
    /// agyの`USER_INPUT`行は`<USER_REQUEST>…</USER_REQUEST>`の後ろに
    /// `<ADDITIONAL_METADATA>`などを続ける。そのまま整形へ渡すと`<`始まりとして
    /// 弾かれるので、要求本文だけを抜き出してから見出しに整える。
    public static func headline(fromAgyTranscript lines: [String]) -> String? {
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            guard object["type"] as? String == "USER_INPUT" else { continue }
            if let source = object["source"] as? String, source != "USER_EXPLICIT" {
                continue
            }
            guard let content = object["content"] as? String else { continue }
            let raw = extractAgyUserRequest(from: content)
            if let headline = condensedHeadline(raw) { return headline }
        }
        return nil
    }

    /// `conversation_summaries.workspace_uris`（JSON配列の`file://` URI）から
    /// 実パスを取り出す。パーセントエンコードされた日本語や空白も元へ戻す。
    public static func agyWorkspacePaths(fromJSON raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [String]
        else { return [] }
        return items.compactMap { item in
            if let url = URL(string: item), url.isFileURL {
                return url.path(percentEncoded: false)
            }
            return item.hasPrefix("/") ? item : nil
        }
    }

    static func extractAgyUserRequest(from content: String) -> String {
        let openTag = "<USER_REQUEST>"
        let closeTag = "</USER_REQUEST>"
        guard let start = content.range(of: openTag) else { return content }
        let rest = content[start.upperBound...]
        if let end = rest.range(of: closeTag) {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }

    /// `2026-11-26 00:46:20.119858+00:00` のようなSQLiteの日時文字列を`Date`へ。
    ///
    /// `ISO8601DateFormatter`は小数秒が3桁以外だと失敗することがあるため、
    /// スペース区切りと可変桁の小数秒を均してから渡す。
    public static func parseAgyTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso: String
        if let space = trimmed.firstIndex(of: " "),
           trimmed.distance(from: trimmed.startIndex, to: space) == 10 {
            var replaced = trimmed
            replaced.replaceSubrange(space...space, with: "T")
            iso = replaced
        } else {
            iso = trimmed
        }
        if let direct = parseTimestamp(iso) { return direct }
        guard let dot = iso.firstIndex(of: ".") else { return nil }
        let afterDot = iso.index(after: dot)
        let tzStart = iso[afterDot...].firstIndex { $0 == "+" || $0 == "-" || $0 == "Z" || $0 == "z" }
            ?? iso.endIndex
        let fraction = iso[afterDot..<tzStart]
        let millis = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        let normalized = String(iso[..<dot]) + "." + millis + String(iso[tzStart...])
        return parseTimestamp(normalized)
    }

    // MARK: - claudeの索引

    /// claudeがプロジェクトごとに置くことがある索引。あれば一番安い。
    ///
    /// 全部のプロジェクトが持っているわけではない（実測で205中44）ので、
    /// 無いことを前提に組み、あったら得をする、という扱いにする。
    public struct ClaudeSessionsIndex: Decodable, Sendable {
        public struct Entry: Decodable, Sendable {
            public var sessionId: String
            public var firstPrompt: String?
            public var summary: String?
            public var messageCount: Int?
            public var modified: String?
            /// 潰れたフォルダ名と違い、これは元のパスがそのまま入っている。
            public var projectPath: String?
            public var isSidechain: Bool?

            public init(
                sessionId: String,
                firstPrompt: String? = nil,
                summary: String? = nil,
                messageCount: Int? = nil,
                modified: String? = nil,
                projectPath: String? = nil,
                isSidechain: Bool? = nil
            ) {
                self.sessionId = sessionId
                self.firstPrompt = firstPrompt
                self.summary = summary
                self.messageCount = messageCount
                self.modified = modified
                self.projectPath = projectPath
                self.isSidechain = isSidechain
            }
        }

        public var entries: [Entry]
        public var originalPath: String?

        public init(entries: [Entry], originalPath: String? = nil) {
            self.entries = entries
            self.originalPath = originalPath
        }
    }

    public static let claudeIndexFileName = "sessions-index.json"

    /// 索引の項目を見出しに直す。`firstPrompt`を先に見るのは、本人の言葉のほうが
    /// AIの付けた要約より思い出しやすいから。
    public static func digest(
        from entry: ClaudeSessionsIndex.Entry,
        fallbackModifiedAt: Date
    ) -> ConversationDigest? {
        if entry.isSidechain == true { return nil }
        let headline = entry.firstPrompt.flatMap { condensedHeadline($0) }
            ?? entry.summary.flatMap { condensedHeadline($0) }
        guard let headline else { return nil }
        return ConversationDigest(
            sessionID: entry.sessionId,
            kind: .claude,
            headline: headline,
            modifiedAt: entry.modified.flatMap(parseTimestamp) ?? fallbackModifiedAt,
            messageCount: entry.messageCount
        )
    }

    // MARK: - 下ごしらえ

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `content`が素の文字列のときと、部品の配列のときがある。どちらも通す。
    static func messageText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let parts = message["content"] as? [Any] else { return nil }
        let texts = parts.compactMap { part -> String? in
            guard let part = part as? [String: Any] else { return nil }
            return part["text"] as? String
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: " ")
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// 同じパスを指しているか。綴りの揺れだけ均して比べる。
    static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs, isDirectory: true).standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs, isDirectory: true).standardizedFileURL.path
        return left == right
    }
}

// MARK: - ディスクから集める

extension ConversationHistory {
    public static func defaultClaudeProjectsRoot(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func defaultCodexSessionsRoot(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func defaultAgyDataRoot(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    /// ファイルの頭だけ読む。
    ///
    /// transcriptは平気で50MBを超えるが、欲しいものは必ず先頭にある。行数と
    /// バイト数の両方で頭を打つので、ファイルの大きさは読む量に効かない。
    static func headLines(
        of url: URL,
        byteLimit: Int = scanByteLimit,
        lineLimit: Int = scanLineLimit
    ) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: byteLimit), !data.isEmpty else { return [] }
        // 上限で切ったときは、行の途中で終わっている。中途半端な末尾は
        // UTF-8として壊れるので、最後の改行から先を捨てる。
        if data.count >= byteLimit, let lastNewline = data.lastIndex(of: 0x0A) {
            data = data[data.startIndex..<lastNewline]
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines.append(String(line))
            if lines.count >= lineLimit { break }
        }
        return lines
    }

    /// 新しい順に並べた、そのフォルダのclaude会話。
    public static func claudeDigests(
        forDirectory directory: URL,
        projectsRoot: URL,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) -> [ConversationDigest] {
        let path = directory.standardizedFileURL.path
        let base = projectsRoot.appendingPathComponent(
            claudeProjectDirectoryName(forPath: path),
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return [] }

        if let indexed = digestsFromClaudeIndex(
            at: base,
            expecting: path,
            limit: limit,
            fileManager: fileManager
        ) {
            return indexed
        }
        return digestsFromClaudeTranscripts(
            at: base,
            expecting: path,
            limit: limit,
            fileManager: fileManager
        )
    }

    /// 索引が置かれていれば、開くのはその1枚で済む。無ければ`nil`を返して
    /// transcriptを読む道へ譲る。
    static func digestsFromClaudeIndex(
        at base: URL,
        expecting path: String,
        limit: Int,
        fileManager: FileManager
    ) -> [ConversationDigest]? {
        let url = base.appendingPathComponent(claudeIndexFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let index = try? JSONDecoder().decode(ClaudeSessionsIndex.self, from: data) else {
            return nil
        }
        // 潰れた名前で別のフォルダを掴んでいないか。索引は元のパスを覚えている。
        if let original = index.originalPath, !sameDirectory(original, path) { return [] }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date.distantPast
        let digests = index.entries
            .filter { $0.projectPath.map { sameDirectory($0, path) } ?? true }
            .compactMap { digest(from: $0, fallbackModifiedAt: modified) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        return Array(digests.prefix(limit))
    }

    static func digestsFromClaudeTranscripts(
        at base: URL,
        expecting path: String,
        limit: Int,
        fileManager: FileManager
    ) -> [ConversationDigest] {
        var digests: [ConversationDigest] = []
        var verified = false
        // 見出しの取れない回もあるので、欲しい数より多めに当たる。
        for candidate in newestFirst(in: base, extension: "jsonl", fileManager: fileManager)
            .prefix(limit * 4)
        {
            if digests.count >= limit { break }
            let lines = headLines(of: candidate.url)
            if !verified {
                // 名前の潰れで隣のフォルダを掴んでいないか、最初の1本で確かめる。
                // 名乗らないtranscriptは判断材料にしないで次へ回す。
                if let cwd = workingDirectory(fromClaudeTranscript: lines) {
                    guard sameDirectory(cwd, path) else { return [] }
                    verified = true
                }
            }
            guard let headline = headline(fromClaudeTranscript: lines) else { continue }
            digests.append(
                ConversationDigest(
                    sessionID: candidate.url.deletingPathExtension().lastPathComponent,
                    kind: .claude,
                    headline: headline,
                    modifiedAt: candidate.modifiedAt
                )
            )
        }
        return digests
    }

    /// 新しい順に並べた、そのフォルダのcodex会話。
    ///
    /// codexはフォルダ単位の索引を持たないので、新しい順に舐めて名乗りを確かめる
    /// しかない。1本につき頭の数KBだけなので、400本見ても1秒に届かない。
    public static func codexDigests(
        forDirectory directory: URL,
        sessionsRoot: URL,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) -> [ConversationDigest] {
        let path = directory.standardizedFileURL.path
        var digests: [ConversationDigest] = []
        for candidate in newestFirst(in: sessionsRoot, extension: "jsonl", fileManager: fileManager)
            .prefix(codexScanLimit)
        {
            if digests.count >= limit { break }
            guard candidate.url.lastPathComponent.hasPrefix("rollout-") else { continue }
            // まず名乗りだけ。1行目に来るので、ここは数KBで足りる。
            let probe = headLines(of: candidate.url, byteLimit: 4 * 1024, lineLimit: 4)
            guard let cwd = workingDirectory(fromCodexRollout: probe),
                  sameDirectory(cwd, path)
            else { continue }
            guard let headline = headline(fromCodexRollout: headLines(of: candidate.url)) else {
                continue
            }
            guard let sessionID = codexSessionID(fromFileName: candidate.url.lastPathComponent) else {
                continue
            }
            digests.append(
                ConversationDigest(
                    sessionID: sessionID,
                    kind: .codex,
                    headline: headline,
                    modifiedAt: candidate.modifiedAt
                )
            )
        }
        return digests
    }

    /// 新しい順に並べた、そのフォルダのagy会話。
    ///
    /// agyは`~/.gemini/antigravity-cli/conversation_summaries.db`に全会話の索引を
    /// 持っている。読み取り専用で開いてそのフォルダのトップレベル会話だけを拾い、
    /// 本人の最初の一言は`brain/<id>/.system_generated/logs/transcript.jsonl`の先頭から、
    /// 無ければDBの`preview`・`title`へ落とす。
    public static func agyDigests(
        forDirectory directory: URL,
        dataRoot: URL,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) -> [ConversationDigest] {
        guard limit > 0 else { return [] }
        let dbURL = dataRoot.appendingPathComponent(agySummaryDatabaseName, isDirectory: false)
        guard fileManager.fileExists(atPath: dbURL.path) else { return [] }

        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else { return [] }
        sqlite3_busy_timeout(db, 200)

        let sql = """
        SELECT conversation_id, title, preview, last_modified_time, workspace_uris
        FROM conversation_summaries
        WHERE parent_conversation_id = '' AND nesting_depth = 0
        ORDER BY last_modified_time DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        let path = directory.standardizedFileURL.path
        let brainRoot = dataRoot.appendingPathComponent("brain", isDirectory: true)
        var digests: [ConversationDigest] = []

        while digests.count < limit && sqlite3_step(statement) == SQLITE_ROW {
            let conversationID = sqliteText(statement, column: 0)
            guard !conversationID.isEmpty else { continue }
            let workspaceURIs = sqliteText(statement, column: 4)
            guard agyWorkspacePaths(fromJSON: workspaceURIs).contains(where: {
                sameDirectory($0, path)
            }) else { continue }

            let title = sqliteText(statement, column: 1)
            let preview = sqliteText(statement, column: 2)
            let modifiedRaw = sqliteText(statement, column: 3)

            let transcriptURL = brainRoot
                .appendingPathComponent(conversationID, isDirectory: true)
                .appendingPathComponent(".system_generated/logs/transcript.jsonl", isDirectory: false)
            let transcriptHeadline = fileManager.fileExists(atPath: transcriptURL.path)
                ? headline(fromAgyTranscript: headLines(of: transcriptURL))
                : nil
            let chosenHeadline = transcriptHeadline
                ?? condensedHeadline(preview)
                ?? condensedHeadline(title)
            guard let chosenHeadline else { continue }

            digests.append(
                ConversationDigest(
                    sessionID: conversationID,
                    kind: .agy,
                    headline: chosenHeadline,
                    modifiedAt: parseAgyTimestamp(modifiedRaw) ?? .distantPast
                )
            )
        }
        return digests
    }

    private static func sqliteText(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    /// そのフォルダ・その種類の会話を新しい順に。shellは会話を持たないので空。
    public static func digests(
        forDirectory directory: URL,
        kind: TerminalSessionKind,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) -> [ConversationDigest] {
        switch kind {
        case .shell, .ssh:
            return []
        case .claude:
            return claudeDigests(
                forDirectory: directory,
                projectsRoot: defaultClaudeProjectsRoot(homeDirectory: homeDirectory),
                limit: limit,
                fileManager: fileManager
            )
        case .codex:
            return codexDigests(
                forDirectory: directory,
                sessionsRoot: defaultCodexSessionsRoot(homeDirectory: homeDirectory),
                limit: limit,
                fileManager: fileManager
            )
        case .agy:
            return agyDigests(
                forDirectory: directory,
                dataRoot: defaultAgyDataRoot(homeDirectory: homeDirectory),
                limit: limit,
                fileManager: fileManager
            )
        }
    }

    struct DatedFile {
        var url: URL
        var modifiedAt: Date
    }

    /// 更新の新しい順。claudeは平らな1階層、codexは年/月/日で潜るので、
    /// どちらも同じ数え方で扱えるよう再帰で拾う。
    static func newestFirst(
        in root: URL,
        extension pathExtension: String,
        fileManager: FileManager
    ) -> [DatedFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [DatedFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == pathExtension else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append(
                DatedFile(url: url, modifiedAt: values?.contentModificationDate ?? .distantPast)
            )
        }
        return files.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

extension ConversationHistory {
    /// claude・codex・agyを、新しい順にひと並びで。
    ///
    /// 混ぜはするが、どれで話した回かは行の印に残す。そこが消えると、
    /// 戻る相手を間違える。
    public static func recentDigests(
        forDirectory directory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) -> [ConversationDigest] {
        let all = digests(
            forDirectory: directory,
            kind: .claude,
            homeDirectory: homeDirectory,
            limit: limit,
            fileManager: fileManager
        ) + digests(
            forDirectory: directory,
            kind: .codex,
            homeDirectory: homeDirectory,
            limit: limit,
            fileManager: fileManager
        ) + digests(
            forDirectory: directory,
            kind: .agy,
            homeDirectory: homeDirectory,
            limit: limit,
            fileManager: fileManager
        )
        return Array(all.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit))
    }
}
