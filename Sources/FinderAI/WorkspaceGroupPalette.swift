import AppKit
import FinderAICore

/// グループの色。定義された順に配る。
///
/// 一覧の見出しと地図の島で**同じ色**を使うための置き場。別々に配っていたら、
/// 一覧で青かったグループが地図では緑になり、色を覚える意味がなくなる。
///
/// 色は手掛かりの一つであって唯一の手掛かりにはしない。色覚によっては隣り合う
/// 色が同じに見えるので、見出しには必ず名前を添え、地図では重なりを輪でも示す。
@MainActor
enum WorkspaceGroupPalette {
    private static let colors: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemPink, .systemTeal, .systemYellow, .systemIndigo
    ]

    /// グループごとの色。定義順で決まるので、グループを並べ替えない限り同じ色が続く。
    static func colors(for groups: WorkspaceItemGroups?) -> [String: NSColor] {
        var assigned: [String: NSColor] = [:]
        for (index, group) in (groups?.groups ?? []).enumerated() {
            assigned[group.name] = colors[index % colors.count]
        }
        return assigned
    }

    static func color(for name: String, in groups: WorkspaceItemGroups?) -> NSColor? {
        colors(for: groups)[name]
    }
}
