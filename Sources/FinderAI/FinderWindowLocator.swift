import AppKit
import Foundation

/// macOS標準のFinderが、いまどのフォルダを開いているかを知る。
///
/// このアプリを使う人はFinderのウインドウも何枚も開いている。「そのフォルダを
/// 開く」と言われたとき、すでにFinderがそこを映しているなら、新しく開くより
/// そのウインドウを前に出すほうが早いし、窓が増えない。
///
/// 問い合わせはAppleScript経由（`NSAppleEventsUsageDescription`は「Finderの現在地を
/// 開く」で既に宣言済み）。許可がない・Finderが応じないときは黙って空を返す:
/// これは近道であって、無ければ自分のウインドウで開けばいいだけの話なので、
/// 失敗をユーザーに見せる意味がない。
enum FinderWindowLocator {
    /// Finderが開いているウインドウのフォルダ一覧。手前にあるものから順。
    static func openFolders() -> [URL] {
        let script = """
        tell application "Finder"
            set output to ""
            repeat with w in windows
                try
                    set output to output & (POSIX path of (target of w as alias)) & linefeed
                end try
            end repeat
            return output
        end tell
        """
        guard let raw = run(script) else { return [] }
        return raw
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL }
    }

    /// そのフォルダを映しているFinderのウインドウを前に出す。出せたらtrue。
    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        // パスの比較はFinder側にやらせる。こちらで名前を組み立てて渡すより、
        // シンボリックリンクや別名の揺れに強い。
        let script = """
        tell application "Finder"
            repeat with w in windows
                try
                    if (POSIX path of (target of w as alias)) is equal to "\(escaped(path))" then
                        set index of w to 1
                        activate
                        return "yes"
                    end if
                end try
            end repeat
            return "no"
        end tell
        """
        return run(script)?.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    /// Finderで新しくそのフォルダを開く。
    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    private static func escaped(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
