import AppKit
import FinderAICore

/// 袖に並ぶ、フォルダではないタブ。
///
/// いまはウインドウの一覧を呼ぶためだけに使う。`⌃⌘W`を覚えなくても、袖に手を
/// 伸ばせば出せる——袖はもともと常に縁にあって、触れるだけで反応する場所なので、
/// そこへ置くのがいちばん近い。
@MainActor
final class EdgeActionTabButton: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onPress: (() -> Void)?

    /// 添える数。ウインドウが何枚開いているか。
    var badge: Int = 0 {
        didSet {
            guard badge != oldValue else { return }
            badgeLabel.stringValue = badge > 0 ? "\(badge)" : ""
            badgeLabel.isHidden = badge <= 0
        }
    }

    private let edge: WorkspaceScreenEdge
    private let iconView = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    init(symbol: String, tooltip: String, edge: WorkspaceScreenEdge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        iconView.contentTintColor = IntegratedPanelTheme.text
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = IntegratedPanelTheme.secondaryText
        badgeLabel.alignment = .center
        badgeLabel.isHidden = true

        [iconView, badgeLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            badgeLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2)
        ])
        toolTip = tooltip
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
}
