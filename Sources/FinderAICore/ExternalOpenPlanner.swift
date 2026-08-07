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

    /// - Parameters:
    ///   - hasOpenWindow: 今ある窓を1つ使えるか。
    ///   - availableNewWindows: あと何枚まで開いてよいか。
    public static func steps(
        for targets: [ExternalOpenTarget],
        hasOpenWindow: Bool,
        availableNewWindows: Int
    ) -> [Step] {
        var steps: [Step] = []
        var remainingNewWindows = max(0, availableNewWindows)
        var canUseExistingWindow = hasOpenWindow

        for target in targets {
            let usesNewWindow: Bool
            if canUseExistingWindow {
                usesNewWindow = false
                canUseExistingWindow = false
            } else if remainingNewWindows > 0 {
                usesNewWindow = true
                remainingNewWindows -= 1
            } else {
                // 上限に当たったら、そこで止める。残りを1枚へ上書きし合っても
                // 最後の1つしか見えず、渡した意味が消える。
                break
            }

            let standardized = target.url.standardizedFileURL
            steps.append(Step(
                folder: target.isDirectory
                    ? standardized
                    : standardized.deletingLastPathComponent(),
                selection: target.isDirectory ? nil : standardized,
                usesNewWindow: usesNewWindow
            ))
        }
        return steps
    }
}
