import FinderAICore
import Foundation

/// セッションごとの追記専用ログ。狙いはクラッシュ後の検死で、FinderAIが死ねば
/// PTYも道連れになるが、ホストが送ってきたバイト列だけはディスクに残る。
///
/// 出力はANSIエスケープ込みの生バイトを保存する。`less -R`でそのまま読める上、
/// エスケープを剥がすとTUIの出力は復元不能に壊れるため、加工しない。
final class SessionOutputLog: @unchecked Sendable {
    let fileURL: URL
    private let queue = DispatchQueue(
        label: "com.shigenoburyuto.finderai.session-log",
        qos: .utility
    )
    private var handle: FileHandle?

    init?(directory: URL, fileName: String, header: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: Data(header.utf8)
        ), let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? handle.seekToEnd()
        self.handle = handle
    }

    /// PTYの読み取りはメインキューに届くので、書き込みはそこで行わない。
    /// ディスクが詰まったときに遅れてよいのはログであってUIではない。
    func append(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            try? handle.write(contentsOf: Data(bytes))
        }
    }

    func appendLine(_ text: String) {
        append(Array("\n\(text)\n".utf8))
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.handle?.close()
            self.handle = nil
        }
    }
}

enum SessionLogStore {
    static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("FinderAI", isDirectory: true)
            .appendingPathComponent("session-logs", isDirectory: true)
    }

    static func fileName(
        kind: TerminalSessionKind,
        directoryURL: URL,
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = sanitized(directoryURL.lastPathComponent)
        let suffix = UUID().uuidString.prefix(4)
        return "\(formatter.string(from: date))-\(kind.rawValue)-\(folder)-\(suffix).log"
    }

    static func header(
        kind: TerminalSessionKind,
        directoryURL: URL,
        date: Date = Date()
    ) -> String {
        """
        # FinderAI session log
        # kind: \(kind.displayName)
        # folder: \(directoryURL.path(percentEncoded: false))
        # started: \(ISO8601DateFormatter().string(from: date))

        """
    }

    /// ログは検死用であって履歴ではない。2週間あればどのクラッシュも調べられ、
    /// フォルダが際限なく育つこともない。
    nonisolated static func pruneLogs(
        olderThan interval: TimeInterval = 14 * 24 * 3600,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-interval)
        for entry in entries where entry.pathExtension == "log" {
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// ファイル名に入るのはフォルダ名だけ。パス区切りや制御文字を落とし、
    /// 長すぎる名前は切る。
    private static func sanitized(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        let cleaned = component.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let text = String(cleaned)
        return text.isEmpty ? "folder" : String(text.prefix(40))
    }
}
