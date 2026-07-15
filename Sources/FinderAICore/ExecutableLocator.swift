import Foundation

public enum ExecutableLocator {
    public static func locate(
        command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !command.isEmpty,
              !command.contains("/"),
              !command.contains("\0") else { return nil }

        for directory in searchDirectories(environment: environment, homeDirectory: homeDirectory) {
            let candidate = directory.appendingPathComponent(command, isDirectory: false).standardizedFileURL
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            return candidate
        }
        return nil
    }

    public static func augmentedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        searchDirectories(environment: environment, homeDirectory: homeDirectory)
            .map(\.path)
            .joined(separator: ":")
    }

    private static func searchDirectories(
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        var directories: [URL] = []
        if let path = environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":", omittingEmptySubsequences: true).map {
                URL(fileURLWithPath: String($0), isDirectory: true)
            })
        }

        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) })
        directories.append(contentsOf: [
            ".local/bin",
            ".npm-global/bin",
            ".volta/bin",
            ".cargo/bin",
            ".bun/bin"
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) })

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
