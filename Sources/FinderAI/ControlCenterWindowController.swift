import AppKit
import FinderAICore

@MainActor
final class ControlCenterWindowController: NSWindowController {
    var onOpenAccessibility: (() -> Void)?
    var onRecheck: (() -> Void)?
    var onOpenFinder: (() -> Void)?

    private let statusCard = NSView()
    private let statusImage = NSImageView()
    private let statusTitle = NSTextField(labelWithString: "FinderAIを確認しています…")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let accessibilityButton = NSButton()
    private let recheckButton = NSButton()
    private let finderButton = NSButton()
    private var positioned = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FinderAI"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        window.minSize = NSSize(width: 560, height: 400)
        window.contentViewController = Self.makeContentViewController(
            statusCard: statusCard,
            statusImage: statusImage,
            statusTitle: statusTitle,
            statusDetail: statusDetail,
            accessibilityButton: accessibilityButton,
            recheckButton: recheckButton,
            finderButton: finderButton
        )
        window.setContentSize(NSSize(width: 600, height: 430))
        super.init(window: window)

        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility)
        recheckButton.target = self
        recheckButton.action = #selector(recheck)
        finderButton.target = self
        finderButton.action = #selector(openFinder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !positioned {
            window?.center()
            positioned = true
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(state: FinderTrackingState) {
        let presentation = ControlCenterPresentation.make(for: state)
        statusTitle.stringValue = presentation.title
        statusDetail.stringValue = presentation.detail
        statusImage.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.title
        )
        finderButton.isEnabled = presentation.finderButtonIsEnabled
        accessibilityButton.keyEquivalent = presentation.permissionButtonIsProminent ? "\r" : ""
        finderButton.keyEquivalent = presentation.finderButtonIsEnabled
            && !presentation.permissionButtonIsProminent ? "\r" : ""

        let color: NSColor
        switch presentation.tone {
        case .attention:
            color = .systemOrange
        case .waiting:
            color = .systemBlue
        case .ready:
            color = .systemGreen
        }
        statusImage.contentTintColor = color
        statusCard.layer?.borderColor = color.withAlphaComponent(0.45).cgColor
        statusCard.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
    }

    private static func makeContentViewController(
        statusCard: NSView,
        statusImage: NSImageView,
        statusTitle: NSTextField,
        statusDetail: NSTextField,
        accessibilityButton: NSButton,
        recheckButton: NSButton,
        finderButton: NSButton
    ) -> NSViewController {
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 430))

        let appImage = NSImageView(image: NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: "FinderAI"
        ) ?? NSImage())
        appImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
        appImage.contentTintColor = .controlAccentColor

        let appTitle = NSTextField(labelWithString: "FinderAI")
        appTitle.font = .systemFont(ofSize: 28, weight: .bold)
        let appSubtitle = NSTextField(labelWithString: "Finderに追従する、折りたたみ式Terminal")
        appSubtitle.font = .systemFont(ofSize: 13, weight: .regular)
        appSubtitle.textColor = .secondaryLabelColor
        let titleText = NSStackView(views: [appTitle, appSubtitle])
        titleText.orientation = .vertical
        titleText.alignment = .leading
        titleText.spacing = 3
        let header = NSStackView(views: [appImage, titleText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        statusCard.wantsLayer = true
        statusCard.layer?.cornerRadius = 12
        statusCard.layer?.borderWidth = 1
        statusImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .semibold)
        statusTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        statusDetail.font = .systemFont(ofSize: 13)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.maximumNumberOfLines = 3
        let statusText = NSStackView(views: [statusTitle, statusDetail])
        statusText.orientation = .vertical
        statusText.alignment = .leading
        statusText.spacing = 7
        [statusImage, statusText].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            statusCard.addSubview($0)
        }
        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 18),
            statusImage.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 18),
            statusImage.widthAnchor.constraint(equalToConstant: 30),
            statusImage.heightAnchor.constraint(equalToConstant: 30),
            statusText.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 14),
            statusText.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -18),
            statusText.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 16),
            statusText.bottomAnchor.constraint(lessThanOrEqualTo: statusCard.bottomAnchor, constant: -16)
        ])

        accessibilityButton.title = "Accessibility設定を開く"
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.controlSize = .large
        recheckButton.title = "許可を再確認"
        recheckButton.bezelStyle = .rounded
        recheckButton.controlSize = .large
        finderButton.title = "Finderで使い始める"
        finderButton.bezelStyle = .rounded
        finderButton.controlSize = .large
        finderButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        finderButton.imagePosition = .imageLeading

        let permissionButtons = NSStackView(views: [accessibilityButton, recheckButton])
        permissionButtons.orientation = .horizontal
        permissionButtons.alignment = .centerY
        permissionButtons.spacing = 10
        let actionRow = NSStackView(views: [permissionButtons, NSView(), finderButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY

        let safety = NSTextField(wrappingLabelWithString:
            "Finder本体は変更しません。FinderAIは公開Accessibility APIで位置と表示フォルダを読み取るだけです。TerminalはShell / Codex / Claudeボタンを押したときだけ起動します。"
        )
        safety.font = .systemFont(ofSize: 12)
        safety.textColor = .tertiaryLabelColor
        safety.maximumNumberOfLines = 3

        let shortcut = NSTextField(labelWithString: "開閉:  Finder下部の TERMINAL バー  または  Control + Option + Space")
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcut.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header, statusCard, actionRow, safety, shortcut])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 104),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            safety.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcut.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        controller.view = root
        return controller
    }

    @objc private func openAccessibility() {
        onOpenAccessibility?()
    }

    @objc private func recheck() {
        onRecheck?()
    }

    @objc private func openFinder() {
        onOpenFinder?()
    }
}
