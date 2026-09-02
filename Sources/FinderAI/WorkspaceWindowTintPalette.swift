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
