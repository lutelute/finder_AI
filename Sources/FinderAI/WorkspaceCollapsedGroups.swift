import Foundation

/// 畳んでいる束。一覧と地図の右の一覧が**同じものを見る**ための置き場。
///
/// それぞれが自前で覚えていたので、一覧で畳んだ束が地図に移ると開いていた。
/// 同じフォルダの同じ束を見ているのに、表示を替えると畳み方が変わるのは、
/// 覚えたことが使えないということ。
///
/// フォルダをまたいでも残す。同じ名前の束は同じ意味で使っていることが多く、
/// 「研究」を畳んだまま隣のフォルダへ行ったら開いている、のほうが驚く。
/// 窓を閉じれば消える — ここまで設定に残すと、畳んだ覚えのないものが
/// 次の起動で畳まれていて、中身が消えたように見える。
@MainActor
final class WorkspaceCollapsedGroups {
    private var names: Set<String> = []

    /// いま畳んでいる束ぜんぶ。地図の割り付けに渡す。
    var all: Set<String> { names }

    func contains(_ name: String) -> Bool { names.contains(name) }

    func insert(_ name: String) { names.insert(name) }

    func remove(_ name: String) { names.remove(name) }

    /// 入り切りする。戻り値は畳んだかどうか。
    @discardableResult
    func toggle(_ name: String) -> Bool {
        if names.contains(name) {
            names.remove(name)
            return false
        }
        names.insert(name)
        return true
    }
}
