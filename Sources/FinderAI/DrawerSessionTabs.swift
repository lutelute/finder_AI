import FinderAICore
import Foundation

/// One row per drawer tab. The strip always carries every presented session —
/// not just the current folder's — because a claude running in another folder
/// silently vanishing from view on navigation was the drawer's biggest usability
/// hole. Sessions from other folders stay visible and say where they live via a
/// folder suffix, so the folder↔terminal binding is readable in the strip itself
/// instead of only inside the binding menu.
///
/// 帯は詰まる前提で作る。窓を10枚も20枚も開く使い方では、全セッションを
/// 横一列に並べれば必ず溢れる。名前・フォルダ・印を別々に持たせてあるのは、
/// 幅に応じて「フォルダを落とす」「名前も落として印だけにする」と削れる
/// ようにするため——文字列を1本に固めてしまうと、削り方を選べない。
struct DrawerSessionTab: Equatable {
    let id: UUID
    /// 種類。帯では色付きの記号になる。読まずに見分けられるのが要点。
    let kind: TerminalSessionKind
    /// 名乗る名前。付けてあれば付けた名前、無ければ種類名。
    let name: String
    /// 別の場所にいるときだけ、その場所の名前。同じ場所ならnil。
    let folderName: String?
    let isRunning: Bool
    let isActive: Bool
    let belongsToCurrentFolder: Bool
    let isAnchored: Bool
    let hasRole: Bool
    let tooltip: String

    /// 幅があるときの表記。
    var fullTitle: String {
        var text = name
        if let folderName { text += " · \(folderName)" }
        return decorated(text)
    }

    /// フォルダを落とした表記。
    var compactTitle: String { decorated(name) }

    private func decorated(_ text: String) -> String {
        var result = text
        if isAnchored { result = "📌 " + result }
        if hasRole { result += " ✳︎" }
        return result
    }
}

enum DrawerSessionTabs {
    struct Source: Equatable {
        let id: UUID
        let kind: TerminalSessionKind
        /// ⌘⌥Tで付けた名前。同じフォルダにClaudeが何本も並ぶと種類名だけでは
        /// 区別が付かないので、付けてあればタブはこちらを名乗る。
        let customName: String?
        /// 起動時に渡した役割。タブでは全文を出さずツールチップに回す——
        /// 帯は狭く、役割は文章になるので。
        let role: String?
        let directoryURL: URL
        let isRunning: Bool
        let isAnchored: Bool

        init(
            id: UUID,
            kind: TerminalSessionKind,
            customName: String? = nil,
            role: String? = nil,
            directoryURL: URL,
            isRunning: Bool,
            isAnchored: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.customName = customName
            self.role = role
            self.directoryURL = directoryURL
            self.isRunning = isRunning
            self.isAnchored = isAnchored
        }
    }

    /// 並べる順。
    ///
    /// 今いる場所のものを先頭へ寄せる。帯が溢れて後ろが削られるとき、
    /// 真っ先に消えてよいのは「よその場所で動いているもの」で、
    /// 「今ここで動いているもの」が消えては話にならない。
    /// それ以外は渡された順のまま——使うたびに並び替わると、
    /// 狙って押せなくなる。
    static func rows(
        sources: [Source],
        currentDirectory: URL?,
        activeID: UUID?
    ) -> [DrawerSessionTab] {
        let current = currentDirectory?.standardizedFileURL
        let tabs = sources.map { source -> DrawerSessionTab in
            let directory = source.directoryURL.standardizedFileURL
            let belongsToCurrentFolder = directory == current
            let folder = directory.lastPathComponent.isEmpty
                ? directory.path(percentEncoded: false)
                : directory.lastPathComponent
            // 名前を付けてあればそれを名乗る。種類はツールチップに残すので、
            // 「これは何のAIか」は失われない。
            let name = source.customName ?? source.kind.displayName
            let heading = source.customName.map { "\($0)（\(source.kind.displayName)）" }
                ?? source.kind.displayName
            // 役割を持たせてあることは印で分かるようにする。決めたのに
            // どこにも出ないと、決めたこと自体を忘れる。
            let roleLine = source.role.map { "役割: \($0)\n" } ?? ""
            return DrawerSessionTab(
                id: source.id,
                kind: source.kind,
                name: name,
                folderName: belongsToCurrentFolder ? nil : folder,
                isRunning: source.isRunning,
                isActive: source.id == activeID,
                belongsToCurrentFolder: belongsToCurrentFolder,
                isAnchored: source.isAnchored,
                hasRole: source.role != nil,
                tooltip: "\(heading) — \(directory.path(percentEncoded: false))\n"
                    + roleLine
                    + "ダブルクリックでこの場所をブラウザに表示"
            )
        }
        // 安定な並び替え。同じ組なら元の順のまま。
        return tabs.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.belongsToCurrentFolder != rhs.element.belongsToCurrentFolder {
                    return lhs.element.belongsToCurrentFolder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
