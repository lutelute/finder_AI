import Foundation

/// 外から渡された1つ。フォルダかどうかは呼ぶ側が調べる——ここは
/// ファイルシステムを触らず、渡されたものをどう見せるかだけを決める。
public struct ExternalOpenTarget: Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// Finderの「このアプリケーションで開く」・ドックへのドロップ・`open -a`で
/// 渡されたものを、どの窓にどう見せるかの決定。
///
/// 純粋関数にしてあるのは、まとめて渡されたときの割り振り（1つ目は今の窓、
/// 残りは別の窓、窓の上限で打ち切り）が、UIを立てずに確かめたい種類の
/// 判断だから。
public enum ExternalOpenPlanner {
    public struct Step: Equatable, Sendable {
        /// 開くフォルダ。ファイルを渡されたときはその入れ物。
        public let folder: URL
        /// 一覧で選んだ状態にするもの。フォルダを渡されたときはnil。
        public let selection: URL?
        /// 新しい窓を開くか。falseなら今ある窓を使う。
        public let usesNewWindow: Bool

        public init(folder: URL, selection: URL?, usesNewWindow: Bool) {
            self.folder = folder
            self.selection = selection
            self.usesNewWindow = usesNewWindow
        }
    }

    /// 既に開いている窓は、その場所を見ているときだけ使い回す。
    ///
    /// 見ていた窓を勝手に別の場所へ動かさない——外から1つ渡しただけで、
    /// 手前で開いていた作業場所が消えるのは事故（実際に消して気付いた）。
    /// Finderも、フォルダを開けと言われたら新しい窓を出す。
    ///
    /// - Parameters:
    ///   - availableNewWindows: あと何枚まで開いてよいか。
    ///   - isAlreadyShown: その場所を映している窓が既にあるか。
    public static func steps(
        for targets: [ExternalOpenTarget],
        availableNewWindows: Int,
        isAlreadyShown: (URL) -> Bool
    ) -> [Step] {
        var steps: [Step] = []
        var remainingNewWindows = max(0, availableNewWindows)

        for target in targets {
            let standardized = target.url.standardizedFileURL
            let folder = target.isDirectory
                ? standardized
                : standardized.deletingLastPathComponent()

            let usesNewWindow: Bool
            if isAlreadyShown(folder) {
                usesNewWindow = false
            } else if remainingNewWindows > 0 {
                usesNewWindow = true
                remainingNewWindows -= 1
            } else {
                // 上限に当たったら、そこで止める。残りを1枚へ上書きし合っても
                // 最後の1つしか見えず、渡した意味が消える。
                break
            }

            steps.append(Step(
                folder: folder,
                selection: target.isDirectory ? nil : standardized,
                usesNewWindow: usesNewWindow
            ))
        }
        return steps
    }
}
