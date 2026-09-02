import AppKit
import FinderAICore

/// ウインドウの目印の色を、AppKitの色と見本に変える。
///
/// 色そのものは`WorkspaceWindowTint`（Core）が持つ。ここはそれをNSColorへ写す
/// だけの層で、`WorkspaceGroupPalette`と同じ切り分け——値はCore、見せ方はApp。
@MainActor
enum WorkspaceWindowTintPalette {
    /// 明るさに追い付く色。額縁へ混ぜるときと、印を出すときの両方で使う。
    static func color(for tint: WorkspaceWindowTint) -> NSColor {
        NSColor(name: nil) { appearance in
            color(hex: appearance.isDark ? tint.darkHex : tint.lightHex)
        }
    }

    /// メニューや一覧に出す丸い見本。
    ///
    /// 名前（藍鼠・苔・小豆…）だけでは何色か分からない。選ぶ前に見えていないと、
    /// 一度当ててみるまで決められない。
    static func swatch(for tint: WorkspaceWindowTint, diameter: CGFloat = 12) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color(for: tint).setFill()
            circle.fill()
            // 淡い色が明るい地に溶けないよう、細い縁を残す。
            NSColor.separatorColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
        // 色そのものを見せるための絵なので、テンプレート扱いにさせない
        // （テンプレートにすると単色へ塗り潰される）。
        image.isTemplate = false
        image.accessibilityDescription = "このウインドウの色：\(tint.title)"
        return image
    }

    /// ツールバーのボタンに出す絵。
    ///
    /// 色が付いていれば塗った丸、付いていなければ**輪郭だけの丸**。記号を
    /// 変えるのではなく同じ丸の中身を変えるのは、押す前と後で的の形が
    /// 変わらないようにするため。形が変わると、同じボタンだと分からなくなる。
    static func buttonImage(for tint: WorkspaceWindowTint?, diameter: CGFloat = 13) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            circle.lineWidth = 1.5
            if let tint {
                color(for: tint).setFill()
                circle.fill()
                NSColor.separatorColor.setStroke()
                circle.stroke()
            } else {
                IntegratedPanelTheme.secondaryText.setStroke()
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        // 記号ではなく自分で描いた絵なので、名前を付けないと読み上げから消える。
        image.accessibilityDescription = tint
            .map { "このウインドウの色：\($0.title)" }
            ?? "このウインドウの色：なし"
        return image
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
