import FinderAICore
import Foundation

@MainActor
protocol SessionRegistryStoring: AnyObject {
    var records: [TerminalSessionRecord] { get }
    func record(matching key: TerminalSessionKey) -> TerminalSessionRecord?
    func upsert(_ record: TerminalSessionRecord)
    func remove(id: UUID)
}

@MainActor
final class InMemorySessionRegistryStore: SessionRegistryStoring {
    private(set) var records: [TerminalSessionRecord]

    init(records: [TerminalSessionRecord] = []) {
        self.records = records
    }

    func record(matching key: TerminalSessionKey) -> TerminalSessionRecord? {
        records.first { $0.key == key }
    }

    func upsert(_ record: TerminalSessionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
    }
}

/// Application Supportへ原子的に保存する台帳。破損データは削除せず、隣へ隔離する。
@MainActor
final class SessionRegistryStore: SessionRegistryStoring {
    private(set) var records: [TerminalSessionRecord] = []
    private(set) var quarantinedFileURL: URL?
    let fileURL: URL

    init(fileURL: URL = SessionRegistryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("FinderAI", isDirectory: true)
            .appendingPathComponent("session-registry.json")
    }

    func record(matching key: TerminalSessionKey) -> TerminalSessionRecord? {
        records.first { $0.key == key }
    }

    func upsert(_ record: TerminalSessionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            records = try JSONDecoder().decode(
                [TerminalSessionRecord].self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            let quarantine = fileURL.deletingLastPathComponent().appendingPathComponent(
                "session-registry.corrupt-\(UUID().uuidString).json"
            )
            do {
                try FileManager.default.moveItem(at: fileURL, to: quarantine)
                quarantinedFileURL = quarantine
            } catch {
                // 読み取れない台帳があっても、FinderAI本体の起動は止めない。
            }
            records = []
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            // 操作を止めない。次の更新でもう一度保存を試す。
        }
    }
}
