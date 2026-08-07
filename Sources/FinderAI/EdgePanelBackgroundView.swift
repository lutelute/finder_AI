import AppKit
import FinderAICore

/// 袖から内側へ広がるパネルの下地。
///
/// 袖に接する側の角は落とさない。そこは袖と地続きで、丸めると帯とのあいだに
/// 隙間があるように見える。
///
/// ボーダーレスのパネルではレイヤーの背景色が効かないので、自分で塗る。
@MainActor
final class EdgePanelBackgroundView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    /// 板の上でのカーソル位置（板の座標）。
    ///
    /// 出したばかりのパネルでは、最初の`mouseEntered`が行まで届かないことが
    /// ある——実測で、開いて最初に触れた1行だけ反応しない回が続いた。位置を
    /// 直接見れば、入った瞬間を取りこぼしても拾い直せる。
    var onMouseMoved: ((NSPoint) -> Void)?
    var edge: WorkspaceScreenEdge = .right {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = 10
        let path = NSBezierPath()
        switch edge {
        case .right:
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                radius: radius, startAngle: 270, endAngle: 180, clockwise: true
            )
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                radius: radius, startAngle: 180, endAngle: 90, clockwise: true
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        case .left:
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                radius: radius, startAngle: 270, endAngle: 0, clockwise: false
            )
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius, startAngle: 0, endAngle: 90, clockwise: false
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.close()
        IntegratedPanelTheme.background.setFill()
        path.fill()
        IntegratedPanelTheme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }
}
