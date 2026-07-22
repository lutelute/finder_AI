import Foundation

/// Builds the byte sequence that moves an idle shell to a new folder.
///
/// The command is prefixed with ^C (ETX): if the user has typed half a command
/// without pressing return, a bare `cd …\n` would concatenate with it and
/// execute the mixture. ^C discards the pending input line in every zsh keymap
/// and never executes anything, so the worst case is a fresh prompt line — not
/// a corrupted command.
public enum ShellFollow {
    public static func command(forPath path: String) -> String {
        "\u{03}cd " + ShellQuoting.quoted(path) + "\n"
    }
}
