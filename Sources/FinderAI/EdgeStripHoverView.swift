import AppKit

/// 袖の板そのもの。タブ1枚ずつではなく、袖に触れたかどうかを見る。
///
/// タブは幅30ptしかない。狙って当てるものとしては細く、「端に寄せたのに何も
/// 起きない」が起きる——実際にそうなっていた。袖に手が届いた時点でリストが
/// 広がれば、端へ寄せるという一続きの動きで済み、狙う工程が消える。
///
/// タブが上に載っていても外れたことにはならない。`NSTrackingArea`は当たり判定
/// ではなく矩形で見るので、子のビューへ入っても矩形の中にいる限り続く。
@MainActor
final class EdgeStripHoverView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
