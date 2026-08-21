import AppKit
import FinderAICore

/// 縁のタブがどこに出るかを、設定画面の中で1枚の図にする。
///
/// 帯の位置は「どちらの縁か」「カーソルに追うか」「隠すか」の掛け算で決まる。
/// 文章で並べても、結局どこに出るのかは読んだ人が頭の中で組み立てることに
/// なる——図なら組み立てずに見える。
///
/// 押しても決められる。モニタの左右の縁で、置く縁が変わる。同じことをする
/// チェックボックスは下に残してあるので、押せると気づかなくても操作は失われず、
/// キーボードでも辿れる。
@MainActor
final class EdgeTabsMapView: NSView {
    var edge: WorkspaceScreenEdge = .right { didSet { needsDisplay = true } }
    var followsPointer = true { didSet { refreshInteractiveAreas() } }
    var autoHides = false { didSet { needsDisplay = true } }
    /// 縁のタブそのものを切っているあいだ。図は淡くなり、押しても動かない。
    var isActive = true {
        didSet {
            alphaValue = isActive ? 1 : 0.4
            refreshInteractiveAreas()
        }
    }

    var onSelectEdge: ((WorkspaceScreenEdge) -> Void)?

    private enum Target { case left, right }
    private var hovered: Target?
    private var trackingArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize { NSSize(width: 296, height: 124) }
    override var isFlipped: Bool { false }

    // MARK: - 図形

    /// モニタの面。左右の余白は、縁を押すときの当たりを広く取るぶん。
    private var monitorFrame: CGRect {
        bounds.insetBy(dx: 8, dy: 4)
    }

    private var stripSize: CGSize {
        CGSize(width: 9, height: max(monitorFrame.height * 0.30, 26))
    }

    /// 帯の枠。`hidden`のときは縁の外へ送り、実物と同じ幅の取っ手だけ残す。
    /// 外へ出たぶんは画面の外なので、描くときにモニタの面で切り落とす。
    private func stripFrame(on side: WorkspaceScreenEdge, in host: CGRect, hidden: Bool) -> CGRect {
        let size = stripSize
        let peek: CGFloat = hidden ? size.width - EdgeTabPlacement.handleWidth : 0
        let x = side == .right
            ? host.maxX - size.width + peek
            : host.minX - peek
        return CGRect(
            x: x,
            y: host.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }

    /// 押せる帯。モニタの左右の縁。
    private func hitArea(_ target: Target) -> CGRect {
        let monitor = monitorFrame
        let band: CGFloat = 16
        switch target {
        case .left:
            return CGRect(x: monitor.minX - 8, y: monitor.minY, width: band, height: monitor.height)
        case .right:
            return CGRect(x: monitor.maxX - band + 8, y: monitor.minY, width: band, height: monitor.height)
        }
    }

    private var activeTargets: [Target] {
        isActive ? [.left, .right] : []
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        let monitor = monitorFrame

        NSColor.textBackgroundColor.setFill()
        let screen = NSBezierPath(roundedRect: monitor, xRadius: 5, yRadius: 5)
        screen.fill()
        NSColor.separatorColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()

        // ホバーしている縁を光らせる。押せることは、触れて初めて分かればいい。
        if let hovered, activeTargets.contains(hovered) {
            IntegratedPanelTheme.accent.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: hitArea(hovered), xRadius: 3, yRadius: 3).fill()
        }

        draw(label: "モニタ", at: CGPoint(x: monitor.minX + 7, y: monitor.maxY - 16))

        // 帯はモニタの面で切る。隠した帯は画面の外へ滑り出ていて、外に出たぶんは
        // 本来どこにも見えない——切らずに描くと、隠れているのに全部見えてしまう。
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: monitor, xRadius: 5, yRadius: 5).addClip()
        drawStrips(monitor: monitor)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawStrips(monitor: CGRect) {
        let accent = IntegratedPanelTheme.accent
        // 追従しているあいだは反対の縁にも移りうるので、そちらは控えめに描く。
        fill(stripFrame(on: edge, in: monitor, hidden: autoHides), with: accent, hidden: autoHides)
        if followsPointer {
            fill(
                stripFrame(on: edge.opposite, in: monitor, hidden: autoHides),
                with: accent.withAlphaComponent(0.3),
                hidden: autoHides
            )
            draw(
                label: "カーソルのいる側へ",
                centeredAt: monitor.midX,
                y: monitor.minY + 7,
                secondary: true
            )
        }
    }

    private func fill(_ rect: CGRect, with color: NSColor, hidden: Bool) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
        // 帯はタブの積み重ね。継ぎ目を薄く入れて実物の見え方に寄せる。縁の外へ
        // 送ったときは取っ手しか見えないので、そこには入れない。
        guard !hidden, rect.height > 24 else { return }
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let seams = NSBezierPath()
        for index in 1..<3 {
            let y = (rect.minY + rect.height * CGFloat(index) / 3).rounded()
            seams.move(to: CGPoint(x: rect.minX + 1.5, y: y))
            seams.line(to: CGPoint(x: rect.maxX - 1.5, y: y))
        }
        seams.lineWidth = 1
        seams.stroke()
    }

    private func draw(label: String, at origin: CGPoint, secondary: Bool = false) {
        (label as NSString).draw(at: origin, withAttributes: attributes(secondary: secondary))
    }

    private func draw(label: String, centeredAt x: CGFloat, y: CGFloat, secondary: Bool) {
        let text = label as NSString
        let style = attributes(secondary: secondary)
        let width = text.size(withAttributes: style).width
        text.draw(at: CGPoint(x: (x - width / 2).rounded(), y: y), withAttributes: style)
    }

    private func attributes(secondary: Bool) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: secondary
                ? NSColor.tertiaryLabelColor
                : NSColor.secondaryLabelColor
        ]
    }

    // MARK: - 操作

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        refreshInteractiveAreas()
    }

    /// ツールチップとカーソルの形を、押せる場所にだけ付け直す。
    private func refreshInteractiveAreas() {
        removeAllToolTips()
        discardCursorRects()
        for target in activeTargets {
            let area = hitArea(target)
            addToolTip(area, owner: tip(for: target) as NSString, userData: nil)
            addCursorRect(area, cursor: .pointingHand)
        }
        needsDisplay = true
    }

    private func tip(for target: Target) -> String {
        switch target {
        case .left: "左の縁にタブを置く"
        case .right: "右の縁にタブを置く"
        }
    }

    override func resetCursorRects() {
        for target in activeTargets {
            addCursorRect(hitArea(target), cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = activeTargets.first { hitArea($0).contains(point) }
        guard next != hovered else { return }
        hovered = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = activeTargets.first(where: { hitArea($0).contains(point) }) else { return }
        switch target {
        case .left: onSelectEdge?(.left)
        case .right: onSelectEdge?(.right)
        }
    }
}
