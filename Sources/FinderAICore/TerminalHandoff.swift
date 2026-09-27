import Foundation

/// FinderAIの中で動いているセッションを、Terminal.appの窓にも出す。
///
/// 永続化がオンのセッションはtmuxの上で動いている。tmuxは1つのセッションに何本でも
/// クライアントを付けられるので、Terminal.appから`tmux attach`すれば同じ画面が外にも
/// 出て、どちらからでも打てる。FinderAI側は手を離さない——窓を閉じても続く。
///
/// Terminal.appへ命令を渡す口はAppleScriptではなく`.command`ファイル。Apple events
/// だと「FinderAIがTerminalを操作しようとしています」の許可が要り、断られると何も
/// 起きない。実行可能な`.command`をTerminal.appで開くだけなら、許可は要らない。
public enum TerminalHandoff {
    public struct Script: Equatable, Sendable {
        public let fileName: String
        public let contents: String

        public init(fileName: String, contents: String) {
            self.fileName = fileName
            self.contents = contents
        }
    }

    /// Terminal.appに実行させる中身。
    ///
    /// - `exec`で置き換えるので、tmuxから抜けた瞬間にシェルも終わり、窓に余計な
    ///   プロンプトが残らない。
    /// - `-t`は前方一致なので`=`を付けて完全一致にする。名前は種類＋ハッシュで
    ///   衝突しないはずだが、別のものに繋がる失敗は静かに起きるので防いでおく。
    /// - 見出しと場所はコメントに書く。Terminal.appの「最近使った項目」や履歴に
    ///   残ったとき、ファイル名（ハッシュ）だけでは何だったか読めない。
    public static func script(
        tmuxExecutablePath: String,
        sessionName: String,
        directoryPath: String,
        title: String
    ) -> Script {
        let heading = singleLine(title)
        let place = singleLine(directoryPath)
        let contents = """
        #!/bin/sh
        # FinderAI — \(heading)
        # \(place)
        #
        # FinderAIの中で動いているtmuxセッションに、この窓からも繋ぐ。
        # 両方から打てる。窓を閉じても、detach（⌃B d）しても、FinderAI側は続く。
        exec \(shellQuoted(tmuxExecutablePath)) attach-session -t \(shellQuoted("=" + sessionName))

        """
        return Script(fileName: "\(sessionName).command", contents: contents)
    }

    /// シェルに1語として渡す形。単引用符で包み、中の単引用符だけ抜けて戻る。
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
