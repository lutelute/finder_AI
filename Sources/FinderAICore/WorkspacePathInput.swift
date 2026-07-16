import Foundation

/// Turns what a person types or pastes into the path bar into a URL.
///
/// Pure and separate from the field so the parsing rules can be tested: the
/// forms below are all things that actually arrive from a copied path, a
/// terminal, or the Finder.
public enum WorkspacePathInput {
    /// Returns nil when there is nothing to act on.
    ///
    /// Handles `~`, `file://` URLs, surrounding quotes, stray whitespace and a
    /// trailing slash. Does not check the filesystem — whether the path exists,
    /// and whether it is a folder, is the caller's business and needs I/O.
    public static func parse(_ raw: String, home: String = NSHomeDirectory()) -> URL? {
        // A Japanese IME left on while typing a path turns "~" into "〜" and "/"
        // into "／" — observed live, the field read "〜/Documents／GitHub".
        //
        // Folding is deliberately narrow, because these characters also occur in
        // real folder names ("2025～2026年度"): "／" folds everywhere since a
        // separator typed through the IME affects the whole path, but the tilde
        // folds only at the start, where it can only mean home. A full-width
        // space is left untouched — names contain them, separators never do.
        var text = raw.replacingOccurrences(of: "／", with: "/")
        if let first = text.first, first == "〜" || first == "～" {
            text = "~" + text.dropFirst()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A path dragged in or copied from a shell often arrives wrapped.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }

        let expanded: String
        if text == "~" {
            expanded = home
        } else if text.hasPrefix("~/") {
            expanded = home + String(text.dropFirst(1))
        } else {
            expanded = text
        }

        // A bare name is not a path; treating it as relative would resolve
        // against the process's working directory, which means nothing here.
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}
