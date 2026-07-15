import Foundation

public enum FinderDocumentURLParser {
    /// Parses Finder's public AXDocument value without executing a shell or
    /// resolving the path through another process.
    public static func parse(_ value: String) -> URL? {
        guard !value.isEmpty else { return nil }

        let candidate: URL?
        if value.hasPrefix("file:") {
            candidate = URL(string: value)
        } else if value.hasPrefix("/") {
            candidate = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            candidate = nil
        }

        guard let candidate, candidate.isFileURL else { return nil }
        return candidate.standardizedFileURL
    }

    public static func canonicalKey(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
    }
}
