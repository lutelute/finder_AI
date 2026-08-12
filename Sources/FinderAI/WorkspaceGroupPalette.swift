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
    /// 色覚に配慮した順に並べた8色。左が明るい地、右が暗い地。
    ///
    /// systemBlue/Green/Orange/Purple… の並びをやめたのは、6グループのときに
    /// green↔orange と blue↔purple という、2型色覚で潰れる代表的な対がそのまま
    /// 先頭6つに入っていたから。明度もほぼ揃っていて、白黒にすると6つとも同じ濃さの
    /// 灰になった。ここでは色相を離すだけでなく**明度も散らして**あるので、
    /// 色が読めなくても濃淡で分かれる。
    ///
    /// 8色目を灰にしてあるのは、8つ目まで来たら色での区別はもう成立していないという
    /// 判断。微妙な色を足すより「色はここまで」と見せたほうが、印の中の文字を読む手に
    /// 切り替わる。
    private static let ramp: [(light: UInt32, dark: UInt32)] = [
        (0x0072B2, 0x3D9BE0),   // 青
        (0xD55E00, 0xF07A2E),   // 朱
        (0x00875F, 0x21C39A),   // 緑
        (0xB85A8A, 0xE39BC2),   // 桃
        (0x3A93C9, 0x7CC6F0),   // 空
        (0xB07800, 0xF2B53A),   // 黄土
        (0x4B3B9E, 0x8A7BE0),   // 藍
        (0x7A7A7A, 0xA6A6A6)    // 石（色をあきらめた8つ目）
    ]

    private static let colors: [NSColor] = ramp.map { pair in
        NSColor(name: nil) { appearance in
            color(hex: appearance.isDark ? pair.dark : pair.light)
        }
    }

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

    /// 印に出す頭文字。色が読めない人にとっては、これが識別子になる。
    ///
    /// 日本語は一文字、ASCIIは二文字。「Sw」と「Sc」は一文字だと同じ「S」になる。
    static func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return first.isASCII ? String(trimmed.prefix(2)).uppercased() : String(first)
    }

    /// その塗りの上に置く文字色。黄土色に白を載せると読めなくなるので、明るさで決める。
    static func foreground(on fill: NSColor) -> NSColor {
        let rgb = fill.usingColorSpace(.sRGB) ?? fill
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance < 0.5 ? .white : NSColor(white: 0.10, alpha: 1)
    }

    private static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

/// グループの印。色の丸。
///
/// 頭文字を載せた16ptの角丸にしていた時期がある（色が読めなくても文字で見分けが
/// つくように）。ただ、一覧の見出しに四角い札が並ぶのは重く、好みで丸へ戻した。
/// 色以外の手掛かりは、見出しの名前と、行の左端のレールが受け持つ。
///
/// `layer.backgroundColor`ではなく`draw(_:)`で塗る。`cgColor`はその瞬間の外観で
/// 固まるので、明るさを切り替えても塗り直されない（セルは再利用されるので、
/// 塗り直しの登録先に溜め込むのも避けたい）。
@MainActor
final class WorkspaceGroupChipView: NSView {
    private var fill: NSColor?

    func show(initial: String, fill: NSColor?) {
        self.fill = fill
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let box = NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: box)
        // 色を持たない印＝未分類。丸を消すと文字の左端がずれるので、
        // 空の破線の丸を置いて位置は揃える。
        guard let fill else {
            path.lineWidth = 1
            path.setLineDash([2, 2], count: 2, phase: 0)
            IntegratedPanelTheme.secondaryText.withAlphaComponent(0.55).setStroke()
            path.stroke()
            return
        }
        fill.setFill()
        path.fill()
    }
}
