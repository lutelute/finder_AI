import AppKit
import FinderAICore

/// ウインドウ1枚を表すカード。
///
/// 縦1列のリストから作り替えた。リストは1行につき「主画面・中央 1180×792」の
/// ような同じ文言が並ぶだけで、同じ場所に重ねて使っているときは3枚とも一字一句
/// 同じになり、選びようがなかった。カードにしてフォルダの絵を大きく出せば、
/// 読むより先に目で分かる。
///
/// 触れているあいだは、そのウインドウが実際に前へ出る。開くまで中身が分からない
/// のでは、結局どれか当てる作業が残る。
@MainActor
final class WorkspaceWindowCardView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    var onClose: (() -> Void)?

    static let width: CGFloat = 168
    static let height: CGFloat = 136

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
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
        place: String,
        serial: Int,
        runningSessions: Int,
        isFrontmost: Bool
    ) {
        self.isFrontmost = isFrontmost
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.stringValue = name
        nameLabel.font = .systemFont(ofSize: 12, weight: isFrontmost ? .semibold : .regular)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1

        placeLabel.stringValue = place
        placeLabel.font = .systemFont(ofSize: 10)
        placeLabel.textColor = .secondaryLabelColor
        placeLabel.alignment = .center
        placeLabel.lineBreakMode = .byTruncatingTail
        placeLabel.maximumNumberOfLines = 1

        // 通し番号は、同じフォルダを何枚も開いたときの最後の頼り。閉じても
        // 詰め直さないので、セッション中ずっと同じ1枚を指す。
        serialLabel.stringValue = "#\(serial)"
        serialLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        serialLabel.textColor = .tertiaryLabelColor

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
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isHidden = true
        closeButton.toolTip = "このウインドウを閉じる"

        [iconView, nameLabel, placeLabel, serialLabel, sessionDot, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: Self.height),

            serialLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            serialLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            sessionDot.leadingAnchor.constraint(equalTo: serialLabel.trailingAnchor, constant: 5),
            sessionDot.centerYAnchor.constraint(equalTo: serialLabel.centerYAnchor),
            sessionDot.widthAnchor.constraint(equalToConstant: 6),
            sessionDot.heightAnchor.constraint(equalToConstant: 6),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 15),
            closeButton.heightAnchor.constraint(equalToConstant: 15),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            iconView.widthAnchor.constraint(equalToConstant: 46),
            iconView.heightAnchor.constraint(equalToConstant: 46),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),

            placeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            placeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            placeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2)
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
        let box = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        path.fill()

        // いま前にいる1枚には枠を回す。どれが手元かは、探し始める前に要る。
        if isFrontmost || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.9 : 0.55).setStroke()
            path.lineWidth = isHighlighted ? 2 : 1.5
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }
}
