import AppKit
import FinderAICore

/// 袖の先頭に置く、開いているウインドウの俯瞰。
///
/// ウインドウの一覧は`⌃⌘W`で開けるが、それは「探しに行く」動作で、開くまで
/// 何枚どこにあるか分からない。袖はもともと常に縁にある場所なので、そこに配置の
/// 図を出しておけば、見るために何もしなくてよくなる。触れれば一覧が開く。
///
/// 30ptの幅に描けるのは概略だけ——どの画面のどのあたりに固まっているか、いま
/// 前にいるのはどれか。それ以上を知りたくなったら一覧を開く、という段になる。
@MainActor
final class EdgeWindowsTabButton: NSView {
    /// 描くもの。画面の枠と、その中のウインドウ。
    struct Layout: Equatable {
        var screens: [CGRect]
        var windows: [CGRect]
        var frontmost: CGRect?
    }

    var onHoverChanged: ((Bool) -> Void)?
    var onPress: (() -> Void)?

    var layout = Layout(screens: [], windows: [], frontmost: nil) {
        didSet {
            guard layout != oldValue else { return }
            countLabel.stringValue = layout.windows.isEmpty ? "" : "\(layout.windows.count)"
            countLabel.isHidden = layout.windows.isEmpty
            needsDisplay = true
        }
    }

    private let edge: WorkspaceScreenEdge
    private let countLabel = NSTextField(labelWithString: "")
    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    init(edge: WorkspaceScreenEdge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        countLabel.textColor = IntegratedPanelTheme.secondaryText
        countLabel.alignment = .center
        countLabel.isHidden = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        toolTip = "開いているウインドウ（押すと一覧）"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        isHighlighted = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()
        drawMiniMap()
    }

    private func drawBackground() {
        (isHighlighted ? IntegratedPanelTheme.activeTab : IntegratedPanelTheme.header)
            .withAlphaComponent(0.96)
            .setFill()
        // フォルダのタブと同じ角の落とし方。並べたときに揃う。
        let radius: CGFloat = 8
        let rect = bounds
        let path = NSBezierPath()
        switch edge {
        case .right:
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                radius: radius, startAngle: 270, endAngle: 180, clockwise: true
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                radius: radius, startAngle: 180, endAngle: 90, clockwise: true
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        case .left:
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                radius: radius, startAngle: 270, endAngle: 0, clockwise: false
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius, startAngle: 0, endAngle: 90, clockwise: false
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.close()
        path.fill()
    }

    /// 全モニタをひとつの図にまとめて描く。
    ///
    /// 画面ごとに分けて描くには幅が足りないので、並びをそのまま縮める。どの画面に
    /// 固まっているかは、図の中の位置で読める。
    private func drawMiniMap() {
        guard !layout.screens.isEmpty else {
            // ウインドウが1枚も無いときは、枠だけ出して「空である」ことを見せる。
            let box = NSRect(x: bounds.midX - 9, y: bounds.maxY - 26, width: 18, height: 13)
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            path.lineWidth = 1
            path.stroke()
            return
        }
        let world = layout.screens.dropFirst().reduce(layout.screens[0]) { $0.union($1) }
        guard world.width > 0, world.height > 0 else { return }

        let area = NSRect(x: 4, y: bounds.maxY - 34, width: bounds.width - 8, height: 24)
        let scale = min(area.width / world.width, area.height / world.height)
        let drawn = NSSize(width: world.width * scale, height: world.height * scale)
        let origin = NSPoint(
            x: area.midX - drawn.width / 2,
            y: area.midY - drawn.height / 2
        )
        func map(_ rect: CGRect) -> NSRect {
            NSRect(
                x: origin.x + (rect.minX - world.minX) * scale,
                y: origin.y + (rect.minY - world.minY) * scale,
                width: max(rect.width * scale, 1.5),
                height: max(rect.height * scale, 1.5)
            )
        }

        for screen in layout.screens {
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
            let path = NSBezierPath(rect: map(screen))
            path.lineWidth = 1
            path.stroke()
        }
        for window in layout.windows {
            IntegratedPanelTheme.secondaryText.withAlphaComponent(0.7).setFill()
            NSBezierPath(rect: map(window)).fill()
        }
        if let frontmost = layout.frontmost {
            IntegratedPanelTheme.accent.setFill()
            NSBezierPath(rect: map(frontmost)).fill()
        }
    }
}
