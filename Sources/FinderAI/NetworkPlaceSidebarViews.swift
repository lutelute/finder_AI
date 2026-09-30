import AppKit
import FinderAICore

/// サイドバーの行の右端に出す、ネットワークの場所の状態。
///
/// **色だけで分けない。** 塗りの丸（繋がっている）、輪（繋がっていない）、
/// 回る印（繋いでいる）、斜線の入った輪（届かなかった）と、形で読めるようにする。
/// 緑と赤の見分けに頼ると、それが難しい人には全部同じ丸に見える。
@MainActor
final class NetworkStateIndicatorView: NSView {
    enum Mark: Equatable {
        case connected
        case disconnected
        case connecting
        case unreachable
    }

    var mark: Mark? {
        didSet {
            guard mark != oldValue else { return }
            if mark == .connecting {
                spinner.isHidden = false
                spinner.startAnimation(nil)
            } else {
                spinner.stopAnimation(nil)
                spinner.isHidden = true
            }
            needsDisplay = true
        }
    }

    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 11),
            spinner.heightAnchor.constraint(equalToConstant: 11)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mark, mark != .connecting else { return }
        let side: CGFloat = 7
        let rect = NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        switch mark {
        case .connected:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .disconnected:
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            IntegratedPanelTheme.secondaryText.setStroke()
            ring.stroke()
        case .unreachable:
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.systemRed.setStroke()
            ring.stroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX - 0.5, y: rect.minY - 0.5))
            slash.line(to: NSPoint(x: rect.maxX + 0.5, y: rect.maxY + 0.5))
            slash.lineWidth = 1.5
            slash.stroke()
        case .connecting:
            break
        }
    }
}

extension NetworkPlaceState {
    var indicatorMark: NetworkStateIndicatorView.Mark {
        switch self {
        case .connected: .connected
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .unreachable: .unreachable
        }
    }
}

/// 「ネットワークの場所を登録」の入力。
///
/// `NSAlert`に欄を足す形にする。グループ名を聞くときと同じ作りで、別の窓を
/// 増やさない。アドレスを打つと名前が追って埋まり、名前を自分で直したら
/// それ以降は追わない。
@MainActor
final class NetworkPlaceRegistrationForm: NSObject, NSTextFieldDelegate {
    struct Candidate {
        let kind: NetworkPlace.Kind
        let address: String
        let source: String
    }

    private let kindControl = NSSegmentedControl(
        labels: ["共有（SMB など）", "サーバー（SSH）"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let addressField = NSTextField()
    private let nameField = NSTextField()
    private let candidatePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let candidates: [Candidate]
    private var nameWasEdited = false
    private weak var stack: NSStackView?

    init(kind: NetworkPlace.Kind, address: String?, candidates: [Candidate]) {
        self.candidates = candidates
        super.init()
        kindControl.selectedSegment = kind == .share ? 0 : 1
        kindControl.target = self
        kindControl.action = #selector(kindChanged)
        addressField.stringValue = address ?? ""
        addressField.delegate = self
        nameField.delegate = self
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        candidatePopup.target = self
        candidatePopup.action = #selector(pickCandidate(_:))
        updateForKind()
        suggestName()
    }

    var kind: NetworkPlace.Kind { kindControl.selectedSegment == 0 ? .share : .server }

    /// 断られた理由を出して、もう一度聞く。
    func show(error: String?) {
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        // 理由の行が出入りするぶん、欄の高さを合わせ直す。NSAlertは付け足した
        // 欄の大きさを自分では追わない。
        if let stack {
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
        }
    }

    /// 入力を登録の形にする。読めなければ理由を返す。
    func makePlace() -> Result<NetworkPlace, FormError> {
        let rawAddress = addressField.stringValue
        let rawName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .share:
            guard let url = NetworkPlaceAddress.normalizedShare(rawAddress) else {
                return .failure(FormError(message: "共有のアドレスとして読めません。smb://ホスト名/共有名 の形で入れてください。"))
            }
            let name = rawName.isEmpty ? NetworkPlaceAddress.suggestedName(forShare: url) : rawName
            return .success(NetworkPlace(kind: .share, name: name, address: url.absoluteString))
        case .server:
            guard let destination = NetworkPlaceAddress.normalizedServer(rawAddress) else {
                return .failure(FormError(message: "sshの宛先として読めません。ユーザー名@ホスト名 か、~/.ssh/config の別名を入れてください。"))
            }
            let name = rawName.isEmpty ? NetworkPlaceAddress.suggestedName(forServer: destination) : rawName
            return .success(NetworkPlace(kind: .server, name: name, address: destination))
        }
    }

    struct FormError: Error {
        let message: String
    }

    func makeAccessoryView() -> NSView {
        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        addressField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let stack = NSStackView(views: [
            kindControl,
            caption("アドレス"),
            addressField,
            hintLabel,
            caption("サイドバーでの名前"),
            nameField,
            candidatePopup,
            errorLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: kindControl)
        stack.setCustomSpacing(10, after: hintLabel)
        stack.setCustomSpacing(10, after: nameField)
        let width: CGFloat = 340
        for view in [addressField, nameField, candidatePopup, hintLabel, errorLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = stack.fittingSize
        self.stack = stack
        return stack
    }

    var initialFirstResponder: NSView { addressField }

    // MARK: - 振る舞い

    @objc private func kindChanged() {
        updateForKind()
        suggestName()
    }

    private func updateForKind() {
        switch kind {
        case .share:
            addressField.placeholderString = "smb://pws-nas03.local/share"
            hintLabel.stringValue = "押すとマウントしてその中へ入ります。パスワードは聞かれたときにmacOSの画面で入れ、キーチェーンに保存できます。"
        case .server:
            addressField.placeholderString = "ubuntu@100.117.16.18 または ~/.ssh/config の別名"
            hintLabel.stringValue = "押すと下のTerminalで ssh が始まります。鍵や踏み台は ~/.ssh/config の設定がそのまま効きます。"
        }
        rebuildCandidates()
        show(error: nil)
    }

    private func rebuildCandidates() {
        candidatePopup.removeAllItems()
        let matching = candidates.filter { $0.kind == kind }
        candidatePopup.addItem(withTitle: matching.isEmpty ? "候補はありません" : "候補から選ぶ…")
        for candidate in matching {
            let item = NSMenuItem(title: candidate.address, action: nil, keyEquivalent: "")
            item.representedObject = candidate.address
            item.toolTip = candidate.source
            // 出どころを右に小さく添える。どこから来た候補かで信じ方が変わる。
            let title = NSMutableAttributedString(
                string: candidate.address,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
            )
            title.append(NSAttributedString(
                string: "  \(candidate.source)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
            item.attributedTitle = title
            candidatePopup.menu?.addItem(item)
        }
        candidatePopup.isEnabled = !matching.isEmpty
    }

    @objc private func pickCandidate(_ sender: NSPopUpButton) {
        guard let address = sender.selectedItem?.representedObject as? String else { return }
        addressField.stringValue = address
        nameWasEdited = false
        suggestName()
        show(error: nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField {
            nameWasEdited = !nameField.stringValue.isEmpty
        } else if field === addressField {
            suggestName()
            show(error: nil)
        }
    }

    private func suggestName() {
        guard !nameWasEdited else { return }
        let address = addressField.stringValue
        switch kind {
        case .share:
            nameField.placeholderString = "nas03"
            nameField.stringValue = NetworkPlaceAddress.normalizedShare(address)
                .map(NetworkPlaceAddress.suggestedName(forShare:)) ?? ""
        case .server:
            nameField.placeholderString = "pws-gpu3060"
            nameField.stringValue = NetworkPlaceAddress.normalizedServer(address)
                .map(NetworkPlaceAddress.suggestedName(forServer:)) ?? ""
        }
    }
}
