import AppKit
import FinderAICore

/// ウインドウ1枚を表す1行。袖から広がる一覧と、独立した一覧の両方で使う。
///
/// 添えるのは置き場所ではなく、ひとつ上のフォルダ名。同じ画面に重ねて使って
/// いると「主画面・中央 1180×792」が全枚数ぶん並ぶだけで、区別に使えない。
/// どこにあるかは、触れれば実際に前へ出るので目で分かる。
@MainActor
final class WorkspaceWindowRowView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    var onClose: (() -> Void)?

    /// 1行の高さ。名前と親フォルダを2段に積んでいたのを1行へ詰めた。袖から
    /// 広がる一覧は縦に伸ばせる幅が限られていて、段数がそのまま入る枚数になる。
    static let height: CGFloat = 32

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let parentLabel = NSTextField(labelWithString: "")
    private let serialLabel = NSTextField(labelWithString: "")
    private let sessionDot = NSView()
    private let closeButton = NSButton()
    private let isFrontmost: Bool

    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            closeButton.isHidden = !isHighlighted
            needsDisplay = true
        }
    }

    init(
        icon: NSImage,
        name: String,
        parent: String,
        serial: Int,
        runningSessions: Int,
        isFrontmost: Bool,
        onDark: Bool
    ) {
        self.isFrontmost = isFrontmost
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let text = onDark ? IntegratedPanelTheme.text : NSColor.labelColor
        let subText = onDark ? IntegratedPanelTheme.secondaryText : NSColor.secondaryLabelColor

        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 12, weight: isFrontmost ? .semibold : .regular)
        nameLabel.textColor = text
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        // 名前は縮まない。削るのは親フォルダ名のほうから。
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        parentLabel.stringValue = parent
        parentLabel.font = .systemFont(ofSize: 10)
        parentLabel.textColor = subText
        parentLabel.lineBreakMode = .byTruncatingHead
        parentLabel.maximumNumberOfLines = 1
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 通し番号は、同じフォルダを何枚も開いたときの最後の頼り。閉じても
        // 詰め直さないので、セッション中ずっと同じ1枚を指す。
        serialLabel.stringValue = "#\(serial)"
        serialLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        serialLabel.textColor = subText

        sessionDot.wantsLayer = true
        sessionDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        sessionDot.layer?.cornerRadius = 3
        sessionDot.isHidden = runningSessions <= 0
        sessionDot.toolTip = runningSessions > 0 ? "実行中：\(runningSessions)" : nil

        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "このウインドウを閉じる"
        )
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = subText
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = true
        closeButton.toolTip = "このウインドウを閉じる"

        [iconView, nameLabel, parentLabel, serialLabel, sessionDot, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 19),
            iconView.heightAnchor.constraint(equalToConstant: 19),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // 親フォルダ名は名前のすぐ後ろへ。縮むのはこちらが先——どちらを
            // 削ってでも、フォルダ名そのものは読めていないと選べない。
            parentLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 7),
            parentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            parentLabel.trailingAnchor.constraint(lessThanOrEqualTo: sessionDot.leadingAnchor, constant: -6),

            sessionDot.trailingAnchor.constraint(equalTo: serialLabel.leadingAnchor, constant: -5),
            sessionDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            sessionDot.widthAnchor.constraint(equalToConstant: 6),
            sessionDot.heightAnchor.constraint(equalToConstant: 6),

            serialLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -5),
            serialLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func closePressed() {
        onClose?()
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
        guard isHighlighted || isFrontmost else { return }
        let box = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.30).setFill()
            path.fill()
        } else {
            // いま手元にある1枚は、探し始める前から分かっているほうがいい。
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
