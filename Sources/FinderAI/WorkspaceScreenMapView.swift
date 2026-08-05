import AppKit

/// ウインドウが画面のどこにあるかを、小さな図で示す。
///
/// 同じフォルダを何枚も開くと、名前もパスも実行中の数まで同じになる。残る差は
/// 「画面のどこに、どの大きさで置いてあるか」で、それは見れば分かる——サムネイル
/// なら中身まで分かるが、画面収録の許可が要る。この機能のためだけに許可を求める
/// のは重いので、位置と大きさだけを図にする。
@MainActor
final class WorkspaceScreenMapView: NSView {
    /// 画面の枠と、その中でのウインドウの矩形。どちらも同じ座標系で渡す。
    var screenFrame: CGRect = .zero {
        didSet { needsDisplay = true }
    }
    var windowFrame: CGRect = .zero {
        didSet { needsDisplay = true }
    }
    var isFrontmost = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let outline = bounds.insetBy(dx: 1, dy: 1)
        let screen = NSBezierPath(roundedRect: outline, xRadius: 2.5, yRadius: 2.5)
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        screen.lineWidth = 1
        screen.stroke()

        guard screenFrame.width > 0, screenFrame.height > 0 else { return }
        // 画面の矩形を枠の中へ縮める。はみ出したウインドウも枠内に収める——
        // 図として読めることのほうが、忠実さより大事。
        let scaleX = outline.width / screenFrame.width
        let scaleY = outline.height / screenFrame.height
        var mapped = CGRect(
            x: outline.minX + (windowFrame.minX - screenFrame.minX) * scaleX,
            y: outline.minY + (windowFrame.minY - screenFrame.minY) * scaleY,
            width: max(windowFrame.width * scaleX, 4),
            height: max(windowFrame.height * scaleY, 3)
        )
        mapped = mapped.intersection(outline)
        guard !mapped.isNull else { return }

        let fill = isFrontmost
            ? NSColor.controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        fill.setFill()
        NSBezierPath(roundedRect: mapped, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// 画面の中でどのあたりに置かれているかを、言葉にする。
///
/// 図だけだと小さすぎて拾えないことがあるので、同じことを文字でも書く。
enum WorkspaceScreenRegion {
    static func describe(window: CGRect, on screen: CGRect) -> String {
        guard screen.width > 0, screen.height > 0 else { return "" }
        let coverage = window.intersection(screen)
        if !coverage.isNull {
            let ratio = (coverage.width * coverage.height) / (screen.width * screen.height)
            // ほぼ画面いっぱいなら、位置を言うより「最大化」と言うほうが早い。
            if ratio > 0.85 { return "最大化" }
            if coverage.height / screen.height > 0.85 {
                if coverage.width / screen.width > 0.45, coverage.width / screen.width < 0.55 {
                    return window.midX < screen.midX ? "左半分" : "右半分"
                }
            }
        }
        let column = third(window.midX - screen.minX, of: screen.width)
        let row = third(window.midY - screen.minY, of: screen.height)
        let vertical = ["下", "中央", "上"][row]
        let horizontal = ["左", "中央", "右"][column]
        if vertical == "中央", horizontal == "中央" { return "中央" }
        if vertical == "中央" { return horizontal }
        if horizontal == "中央" { return vertical }
        return vertical + horizontal
    }

    private static func third(_ value: CGFloat, of total: CGFloat) -> Int {
        guard total > 0 else { return 1 }
        let ratio = value / total
        if ratio < 1.0 / 3.0 { return 0 }
        if ratio > 2.0 / 3.0 { return 2 }
        return 1
    }
}
