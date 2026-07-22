import Foundation

/// Quotes paths for pasting into a shell. Single quotes survive every shell
/// metacharacter except the single quote itself, which is closed, escaped and
/// reopened (`'\''`) — the same form Terminal.app produces when a file is
/// dropped onto it.
public enum ShellQuoting {
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A ready-to-paste `cd` command for the folder.
    public static func changeDirectoryCommand(forPath path: String) -> String {
        "cd " + quoted(path)
    }
}
