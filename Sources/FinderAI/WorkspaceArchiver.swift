import Foundation

/// Zips the selection, the way Finder's "圧縮" does.
///
/// Runs `/usr/bin/ditto` through `Process` with paths as separate `arguments`,
/// never interpolated into a shell string. That keeps the project's rule that a
/// user's path never becomes shell syntax — a folder called `$(rm -rf ~)` or one
/// with a leading hyphen has to be inert.
///
/// `ditto -c -k --sequesterRsrc --keepParent` is what Finder itself uses, so the
/// archive preserves resource forks and unzips to the same shape.
enum WorkspaceArchiver {
    enum ArchiveError: LocalizedError {
        case nothingSelected
        case dittoFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .nothingSelected:
                "圧縮する項目が選ばれていません。"
            case .dittoFailed(let code):
                "圧縮に失敗しました。（ditto: \(code)）"
            }
        }
    }

    /// Returns the archive it wrote. One item is named after it, several become
    /// "アーカイブ.zip" — again matching Finder.
    static func archive(_ urls: [URL], in directory: URL) throws -> URL {
        guard !urls.isEmpty else { throw ArchiveError.nothingSelected }

        let base = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "アーカイブ"
        var destination = directory.appendingPathComponent("\(base).zip")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) \(index).zip")
            index += 1
        }

        if urls.count == 1 {
            // --keepParent puts the item itself inside the archive rather than
            // its contents.
            try runDitto(["--keepParent", urls[0].path, destination.path], destination: destination)
            return destination.standardizedFileURL
        }

        // `ditto -c -k` takes exactly one source, so several items are staged in a
        // folder first and that folder's *contents* are zipped — no --keepParent,
        // or everything would end up nested under the staging folder's name.
        let staging = directory.appendingPathComponent(
            ".finderai-archive-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for url in urls {
            try FileManager.default.copyItem(
                at: url,
                to: staging.appendingPathComponent(url.lastPathComponent)
            )
        }
        try runDitto([staging.path, destination.path], destination: destination)
        return destination.standardizedFileURL
    }

    private static func runDitto(_ tail: [String], destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc"] + tail
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // Leaving a half-written zip behind would look like it worked.
            try? FileManager.default.removeItem(at: destination)
            throw ArchiveError.dittoFailed(process.terminationStatus)
        }
    }
}
