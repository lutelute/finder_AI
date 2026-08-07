import AppKit
import FinderAICore

/// 帯の1本。
///
/// 種類の記号・実行中の点・名前を別々に描くので、幅が足りないときは
/// 名前だけ畳んで記号は残せる。文字列を1本に固めると、この削り方ができない。
/// 選んでいる1本は、地の色と細い縁の両方で示す——色だけだと、暗い配色では
/// 隣と見分けが付かない。
@MainActor
private final class SessionTabButton: NSButton {
    var isActiveTab = false {
        didSet { needsDisplay = true }
    }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if isActiveTab {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 5,
                yRadius: 5
            )
            IntegratedPanelTheme.activeTab.setFill()
            path.fill()
            IntegratedPanelTheme.accent.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        super.draw(dirtyRect)
    }
}

/// ヘッダーの空き地は、パネルを畳んだり広げたりするための的でもある。
///
/// シングルクリックは畳んでいるときだけ開く側に倒す。開いている状態でうっかり
/// 触っただけで作業中のターミナルが消えるのは事故で、閉じるのはchevronか⌘Jという
/// 明示的な操作に任せたほうがいい。ダブルクリックはいつでも段階を巡る。
@MainActor
private final class PanelHeaderView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        switch event.clickCount {
        case 1: onSingleClick?()
        case 2: onDoubleClick?()
        default: break
        }
    }
}

@MainActor
final class DrawerContentViewController: NSViewController {
    var onToggle: (() -> Void)?
    var onResizeDelta: ((CGFloat) -> Void)?
    var onManageSessions: (() -> Void)?
    var onOpenDirectory: ((URL) -> Void)?
    /// 下辺と右辺を入れ替える。
    var onTogglePlacement: (() -> Void)?
    /// ヘッダーのダブルクリック。畳む→半分→最大の巡回はウインドウ側が持つ。
    var onCycleSnap: (() -> Void)?

    private let sessionManager: any TerminalSessionManaging
    private let preferences: WorkspacePreferences
    private let themePainter = ThemedLayerPainter()
    /// この区画の明るさ。押すたびに システム → ライト → ダーク と巡る。
    private let appearanceButton = NSButton()
    /// The folder the browser is showing. There is no drawer-level "fixed"
    /// mode any more: whether a session moves with this is each session's own
    /// story — shells follow (and actually `cd`), AI sessions stay put, and a
    /// pinned (📌) shell stays put too. The tab strip shows all of it.
    private var directoryURL: URL?
    private var visibleSessions: [any ManagedTerminalSession] = []
    private var activeSession: (any ManagedTerminalSession)?
    private var expanded = false
    private var edge: TerminalPanelEdge = .bottom
    private var bodyLayoutConstraints: [NSLayoutConstraint] = []
    /// 辺と開閉で総取り替えになる骨格。張り替えの単位で持っておかないと、
    /// 古い制約が残ったまま新しいものを足して衝突する。
    private var edgeLayoutConstraints: [NSLayoutConstraint] = []
    /// 右辺でタブの2段目を出しているか。セッションの増減で必要／不要が変わる。
    private var showsTabRow = false
    private var mountedSessionID: UUID?

    /// The tab strip is rebuilt from scratch on every reload; this is what the
    /// strip currently shows, so an unchanged session set can skip the teardown.
    private var renderedTabs: [DrawerSessionTab] = []
    /// 「＋N」チップが示した、隠れて実行中のセッション数。タブと一緒に描き
    /// 直すので、変わったかどうかをここで見分ける。
    private var renderedHiddenCount = 0
    /// 前回どこまで詰めたか。幅が変われば詰め方も変わるので、組み直しの
    /// 要否はこれも見て決める。
    private var renderedPlan: DrawerTabStripPlanner.Plan?

    private let resizeHandle = ResizeHandleView()
    /// パネルとブラウザの境目。下辺なら上に、右辺なら左に出る。
    private let edgeBorder = NSView()
    private let header = PanelHeaderView()
    private let primaryRow = NSStackView()
    /// 右辺では横幅が足りないので、タブだけを2段目に降ろす。タブは常時可視が
    /// この画面の約束で、幅の都合で最初に潰れてよいものではない。
    private let tabRow = NSStackView()
    private let toggleButton = NSButton()
    private let divider = NSView()
    private let directoryImage = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "Finder")
    private let sessionTabs = NSStackView()
    private let placementButton = NSButton()
    private let manageSessionsButton = NSButton()
    private let newSessionButton = NSButton()
    private let closeButton = NSButton()

    /// 右辺で畳んだときの34pt幅の縦ストリップ。横並びのヘッダーは入らないので、
    /// アイコンだけの別の並びに差し替える。
    /// 辺で緩める2本。右辺ではラベルを畳んでボタンを詰め、パスに幅を譲る。
    private var toggleWidthConstraint: NSLayoutConstraint!
    private var pathWidthConstraint: NSLayoutConstraint!

    private let stripStack = NSStackView()
    private let stripToggleButton = NSButton()
    private let stripStatusIcon = NSImageView()
    private let stripBadge = NSTextField(labelWithString: "")
    private let stripPlacementButton = NSButton()

    private let bodyView = NSView()
    private let terminalContainer = NSView()
    private let emptyState = NSStackView()
    private let shellButton = NSButton()
    private let codexButton = NSButton()
    private let claudeButton = NSButton()

    // deinitでしか触らないため、managerのactivationObserverと同じ扱い。
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?

    init(sessionManager: any TerminalSessionManaging, preferences: WorkspacePreferences) {
        self.preferences = preferences
        self.sessionManager = sessionManager
        super.init(nibName: nil, bundle: nil)
        // `onChange`はconsumerが1つしか持てず、複数ウインドウでは最後のドロワーが
        // 奪って他が更新されなくなる。全ドロワーが等しく受けられる通知で観測する。
        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionsDidChange,
            object: sessionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSessions() }
        }
    }

    deinit {
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureAppearanceButton() {
        appearanceButton.title = ""
        appearanceButton.isBordered = false
        appearanceButton.imagePosition = .imageOnly
        appearanceButton.contentTintColor = IntegratedPanelTheme.text
        appearanceButton.target = self
        appearanceButton.action = #selector(cycleAppearance)
        refreshAppearanceButton()
    }

    private func refreshAppearanceButton() {
        let mode = preferences.terminalAppearance
        appearanceButton.image = NSImage(
            systemSymbolName: mode.symbolName,
            accessibilityDescription: "ターミナルの明るさ"
        )
        appearanceButton.contentTintColor = IntegratedPanelTheme.text
        appearanceButton.toolTip = "ターミナルの明るさ：\(mode.title)（押すと切り替え）"
    }

    @objc private func cycleAppearance() {
        preferences.terminalAppearance = preferences.terminalAppearance.next
        NotificationCenter.default.post(name: .workspaceAppearanceDidChange, object: nil)
    }

    /// 明るさを選び直したときに掛け替える。
    func applyAppearance() {
        refreshAppearanceButton()
        view.appearance = preferences.terminalAppearance.nsAppearance
        themePainter.appearance = view.appearance
        themePainter.repaint()
    }

    override func loadView() {
        let root = ThemedRootView()
        // ファイル一覧とは別に明るさを選べる。一覧は明るく、ターミナルは暗く、
        // という組み合わせが要る。
        root.appearance = preferences.terminalAppearance.nsAppearance
        themePainter.appearance = root.appearance
        root.onAppearanceChanged = { [weak self] in self?.themePainter.repaint() }
        themePainter.register(root) { IntegratedPanelTheme.background }
        view = root

        configureHeader()
        configureBody()

        [bodyView, header, edgeBorder, resizeHandle].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        setExpanded(false)
    }

    /// パネルがどちらの辺に付いているかを伝える。並べ替えと制約の張り替えだけで、
    /// 走っているセッションには一切触らない。
    func setEdge(_ edge: TerminalPanelEdge) {
        guard self.edge != edge else { return }
        self.edge = edge
        guard isViewLoaded else { return }
        applyEdgeLayout()
    }

    private func applyEdgeLayout() {
        guard isViewLoaded else { return }
        let root = view
        let isStrip = edge == .right && !expanded

        moveSessionTabs(toTabRow: edge == .right)
        resizeHandle.axis = edge == .bottom ? .vertical : .horizontal
        // セッションが1つも無いのに2段目だけ残ると、ヘッダーに空の帯ができる。
        showsTabRow = edge == .right && !isStrip && !visibleSessions.isEmpty

        NSLayoutConstraint.deactivate(edgeLayoutConstraints)
        // 使わない並びは隠すのではなく階層から外す。隠しただけでは位置が決まらず、
        // 中身の固有サイズと潰しの制約がぶつかる。
        mount(primaryRow, !isStrip)
        mount(tabRow, showsTabRow)
        mount(stripStack, isStrip)

        var constraints: [NSLayoutConstraint] = []
        let rowHeight = TerminalPanelLayout.collapsedThickness - 1
        let rowInset: (leading: CGFloat, trailing: CGFloat) = (8, -6)

        switch edge {
        case .bottom:
            constraints += [
                edgeBorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                edgeBorder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                edgeBorder.topAnchor.constraint(equalTo: root.topAnchor),
                edgeBorder.heightAnchor.constraint(equalToConstant: 1),

                resizeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
                resizeHandle.heightAnchor.constraint(equalToConstant: 5),

                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                header.topAnchor.constraint(equalTo: edgeBorder.bottomAnchor),
                header.heightAnchor.constraint(equalToConstant: rowHeight),

                bodyView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                bodyView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                bodyView.topAnchor.constraint(equalTo: header.bottomAnchor),
                bodyView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

                primaryRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: rowInset.leading),
                primaryRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: rowInset.trailing),
                primaryRow.topAnchor.constraint(equalTo: header.topAnchor),
                primaryRow.bottomAnchor.constraint(equalTo: header.bottomAnchor)
            ]
        case .right:
            constraints += [
                edgeBorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                edgeBorder.topAnchor.constraint(equalTo: root.topAnchor),
                edgeBorder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                edgeBorder.widthAnchor.constraint(equalToConstant: 1),

                resizeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
                resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                resizeHandle.widthAnchor.constraint(equalToConstant: 5),

                header.leadingAnchor.constraint(equalTo: edgeBorder.trailingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                header.topAnchor.constraint(equalTo: root.topAnchor),

                bodyView.leadingAnchor.constraint(equalTo: edgeBorder.trailingAnchor),
                bodyView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                bodyView.topAnchor.constraint(equalTo: header.bottomAnchor),
                bodyView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ]
            if isStrip {
                // 畳んだ縦ストリップは中身の高さでよい。バッジが出たり消えたりする
                // ので固定値にはしない。
                constraints += [
                    stripStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
                    stripStack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
                    stripStack.centerXAnchor.constraint(equalTo: header.centerXAnchor)
                ]
            } else {
                constraints += [
                    header.heightAnchor.constraint(
                        equalToConstant: showsTabRow ? rowHeight * 2 - 4 : rowHeight
                    ),
                    primaryRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: rowInset.leading),
                    primaryRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: rowInset.trailing),
                    primaryRow.topAnchor.constraint(equalTo: header.topAnchor),
                    primaryRow.heightAnchor.constraint(equalToConstant: rowHeight)
                ]
                if showsTabRow {
                    constraints += [
                        tabRow.topAnchor.constraint(equalTo: primaryRow.bottomAnchor),
                        tabRow.bottomAnchor.constraint(equalTo: header.bottomAnchor),
                        tabRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: rowInset.leading),
                        tabRow.trailingAnchor.constraint(
                            lessThanOrEqualTo: header.trailingAnchor,
                            constant: rowInset.trailing
                        )
                    ]
                }
            }
        }

        NSLayoutConstraint.activate(constraints)
        edgeLayoutConstraints = constraints
        updateToggleButton()
        updatePlacementButtons()
    }

    private func mount(_ row: NSView, _ shouldMount: Bool) {
        if shouldMount {
            guard row.superview !== header else { return }
            header.addSubview(row)
        } else {
            row.removeFromSuperview()
        }
    }

    /// タブの並びは1つしかないので、段を変えるときは親ごと引っ越す。
    private func moveSessionTabs(toTabRow: Bool) {
        let destination = toTabRow ? tabRow : primaryRow
        guard sessionTabs.superview !== destination else { return }
        sessionTabs.removeFromSuperview()
        if toTabRow {
            tabRow.addArrangedSubview(sessionTabs)
        } else {
            // 右端のアイコン群より内側、スペーサーの直後に戻す。
            primaryRow.insertArrangedSubview(sessionTabs, at: primaryRow.arrangedSubviews.count - 4)
        }
    }

    func setDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard directoryURL != standardized else { return }
        directoryURL = standardized
        updateDirectoryPresentation()
        // Following, in order of what the user meant by "follow": an active
        // un-pinned shell moves with the click — it actually `cd`s (only at an
        // idle prompt; the session refuses otherwise). When it cannot — busy,
        // pinned, an AI session, or the destination already has its own shell
        // — the destination's session comes forward instead, and failing that
        // whatever was on screen stays there. Nothing ever silently vanishes.
        if let active = activeSession,
           active.kind == .shell,
           !active.isAnchored,
           sessionManager.followSession(active, to: standardized) {
            reloadSessions(prefer: active)
        } else {
            reloadSessions(prefer: sessionManager.sessions(for: standardized).last)
        }
    }

    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        if expanded {
            bodyView.isHidden = false
            NSLayoutConstraint.activate(bodyLayoutConstraints)
        } else {
            NSLayoutConstraint.deactivate(bodyLayoutConstraints)
            bodyView.isHidden = true
        }
        resizeHandle.isHidden = !expanded
        applyEdgeLayout()
    }

    private func configureHeader() {
        themePainter.register(header) { IntegratedPanelTheme.header }
        // 畳んでいるときだけ開く。開いているときのシングルクリックは何もしない。
        header.onSingleClick = { [weak self] in
            guard let self, !self.expanded else { return }
            self.onToggle?()
        }
        header.onDoubleClick = { [weak self] in self?.onCycleSnap?() }
        themePainter.register(edgeBorder) { IntegratedPanelTheme.border }

        toggleButton.isBordered = false
        toggleButton.font = .systemFont(ofSize: 11, weight: .semibold)
        toggleButton.imagePosition = .imageLeading
        toggleButton.imageHugsTitle = true
        toggleButton.contentTintColor = IntegratedPanelTheme.text
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        toggleButton.toolTip = "Terminalパネルを開く／隠す（⌘J）— ダブルクリックで大きさを切り替え"

        themePainter.register(divider) { IntegratedPanelTheme.border }

        directoryImage.image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: "現在のフォルダ"
        )
        directoryImage.contentTintColor = IntegratedPanelTheme.secondaryText
        directoryImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = IntegratedPanelTheme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sessionTabs.orientation = .horizontal
        sessionTabs.alignment = .centerY
        sessionTabs.spacing = DrawerTabStripPlanner.spacing
        sessionTabs.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // 帯はウインドウを押し広げない。入らないぶんは`tabStripPlan`が削るので、
        // ここが踏ん張ると最小幅だけが育って、パネルを細くできなくなる。
        sessionTabs.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        sessionTabs.clipsToBounds = true

        configureIconButton(
            placementButton,
            symbol: "rectangle.rightthird.inset.filled",
            accessibilityLabel: "Terminalを右／下に切り替え"
        )
        placementButton.target = self
        placementButton.action = #selector(togglePlacement)

        configureIconButton(
            manageSessionsButton,
            symbol: "rectangle.stack",
            accessibilityLabel: "すべてのTerminalセッションを管理"
        )
        manageSessionsButton.target = self
        manageSessionsButton.action = #selector(manageSessions)

        configureIconButton(
            newSessionButton,
            symbol: "plus",
            accessibilityLabel: "新しいTerminalセッション"
        )
        newSessionButton.target = self
        newSessionButton.action = #selector(showNewSessionMenu)

        configureIconButton(
            closeButton,
            symbol: "xmark.circle",
            accessibilityLabel: "選択中のセッションを閉じる／終了"
        )
        closeButton.target = self
        closeButton.action = #selector(closeSession)

        configureStrip()
        configureAppearanceButton()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryRow.setViews(
            [
                toggleButton,
                divider,
                directoryImage,
                pathLabel,
                spacer,
                sessionTabs,
                appearanceButton,
                placementButton,
                manageSessionsButton,
                newSessionButton,
                closeButton
            ],
            in: .leading
        )
        primaryRow.orientation = .horizontal
        primaryRow.alignment = .centerY
        primaryRow.spacing = 8

        tabRow.orientation = .horizontal
        tabRow.alignment = .centerY
        tabRow.spacing = 8

        // 行そのものは`applyEdgeLayout`が辺ごとに載せ替える。ここで置くのは、
        // どの辺でも変わらない中身のサイズだけ。
        [primaryRow, tabRow, stripStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        toggleWidthConstraint = toggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
        pathWidthConstraint = pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        NSLayoutConstraint.activate([
            toggleWidthConstraint,
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
            directoryImage.widthAnchor.constraint(equalToConstant: 14),
            directoryImage.heightAnchor.constraint(equalToConstant: 14),
            pathWidthConstraint
        ])
        for button in [placementButton, manageSessionsButton, newSessionButton, closeButton] {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 26),
                button.heightAnchor.constraint(equalToConstant: 26)
            ])
        }

        resizeHandle.onDragDelta = { [weak self] delta in self?.onResizeDelta?(delta) }
        updateDirectoryPresentation()
    }

    private func configureStrip() {
        configureIconButton(
            stripToggleButton,
            symbol: "chevron.left",
            accessibilityLabel: "Terminalパネルを開く"
        )
        stripToggleButton.contentTintColor = IntegratedPanelTheme.text
        stripToggleButton.target = self
        stripToggleButton.action = #selector(toggle)
        stripToggleButton.toolTip = "Terminalパネルを開く（⌘J）"

        stripStatusIcon.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Terminal"
        )
        stripStatusIcon.contentTintColor = IntegratedPanelTheme.secondaryText
        stripStatusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

        // 畳んだ縦ストリップからは、走っているセッションの存在だけは見えていないと
        // 「隠れているあいだに何が動いているか」がまるごと消える。
        stripBadge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        stripBadge.textColor = IntegratedPanelTheme.accent
        stripBadge.alignment = .center

        configureIconButton(
            stripPlacementButton,
            symbol: "rectangle.bottomthird.inset.filled",
            accessibilityLabel: "Terminalを下に戻す"
        )
        stripPlacementButton.target = self
        stripPlacementButton.action = #selector(togglePlacement)

        stripStack.orientation = .vertical
        stripStack.alignment = .centerX
        stripStack.spacing = 6
        [stripToggleButton, stripStatusIcon, stripBadge, stripPlacementButton]
            .forEach(stripStack.addArrangedSubview)
        NSLayoutConstraint.activate([
            stripToggleButton.widthAnchor.constraint(equalToConstant: 22),
            stripToggleButton.heightAnchor.constraint(equalToConstant: 22),
            stripStatusIcon.widthAnchor.constraint(equalToConstant: 16),
            stripStatusIcon.heightAnchor.constraint(equalToConstant: 16),
            stripPlacementButton.widthAnchor.constraint(equalToConstant: 22),
            stripPlacementButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    private func updateDirectoryPresentation() {
        guard isViewLoaded else { return }
        let path = directoryURL?.path(percentEncoded: false) ?? "Finder"
        pathLabel.stringValue = directoryURL?.lastPathComponent.isEmpty == false
            ? directoryURL?.lastPathComponent ?? path
            : path
        pathLabel.toolTip = path
    }

    private func configureBody() {
        themePainter.register(bodyView) { IntegratedPanelTheme.terminalBackground }
        themePainter.register(terminalContainer) { IntegratedPanelTheme.terminalBackground }

        let emptyIcon = NSImageView(image: NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Terminal"
        ) ?? NSImage())
        emptyIcon.contentTintColor = IntegratedPanelTheme.secondaryText
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .regular)

        let emptyTitle = NSTextField(labelWithString: "このフォルダでTerminalを開始")
        emptyTitle.font = .systemFont(ofSize: 14, weight: .medium)
        emptyTitle.textColor = IntegratedPanelTheme.text
        let emptyDetail = NSTextField(labelWithString: "閲覧しただけではプロセスを起動しません")
        emptyDetail.font = .systemFont(ofSize: 11, weight: .regular)
        emptyDetail.textColor = IntegratedPanelTheme.secondaryText

        configureStartButton(shellButton, title: "Shell", kind: .shell)
        configureStartButton(codexButton, title: "Codex", kind: .codex)
        configureStartButton(claudeButton, title: "Claude", kind: .claude)
        let actions = NSStackView(views: [shellButton, codexButton, claudeButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        [emptyIcon, emptyTitle, emptyDetail, actions].forEach(emptyState.addArrangedSubview)

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(terminalContainer)
        terminalContainer.addSubview(emptyState)
        bodyLayoutConstraints = [
            terminalContainer.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: bodyView.topAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: terminalContainer.leadingAnchor, constant: 20),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: terminalContainer.trailingAnchor, constant: -20)
        ]
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        accessibilityLabel: String
    ) {
        button.title = ""
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = IntegratedPanelTheme.secondaryText
        button.toolTip = accessibilityLabel
    }

    private func configureStartButton(
        _ button: NSButton,
        title: String,
        kind: TerminalSessionKind
    ) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = TerminalSessionKind.allCases.firstIndex(of: kind) ?? 0
        button.target = self
        button.action = #selector(startSessionFromButton(_:))
    }

    private func updateToggleButton() {
        // 右辺は幅がそのままパネルの厚みなので、ラベルの92ptはパスとタブから
        // 奪うには大きすぎる。矢印は「閉じる向き」を指す。
        let compact = edge == .right
        toggleButton.title = compact ? "" : "TERMINAL"
        toggleWidthConstraint?.constant = compact ? 22 : 92
        pathWidthConstraint?.constant = compact ? 200 : 260
        let symbol: String
        switch (edge, expanded) {
        case (.bottom, true): symbol = "chevron.down"
        case (.bottom, false): symbol = "chevron.up"
        case (.right, true): symbol = "chevron.right"
        case (.right, false): symbol = "chevron.left"
        }
        toggleButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: expanded ? "隠す" : "開く"
        )
    }

    private func updatePlacementButtons() {
        let symbol = edge == .bottom
            ? "rectangle.rightthird.inset.filled"
            : "rectangle.bottomthird.inset.filled"
        let label = edge == .bottom ? "Terminalを右に移動（⌘⌥J）" : "Terminalを下に移動（⌘⌥J）"
        placementButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        placementButton.toolTip = label
        stripPlacementButton.toolTip = label
    }

    /// `takesOverMountedElsewhere`は、他のウインドウに出ている中身を取り寄せて
    /// よいときだけtrue（タブや開始ボタンを押した＝意思のあるときだけ）。
    /// フォルダ移動や新しいウインドウの初期表示のような自動の選択がここをtrueに
    /// すると、開いただけで元のウインドウからAIの画面が消える。
    private func reloadSessions(
        prefer preferred: (any ManagedTerminalSession)? = nil,
        takesOverMountedElsewhere: Bool = false
    ) {
        guard isViewLoaded else { return }
        // Every presented session, not just the current folder's — see
        // DrawerSessionTab for why the strip never hides running work.
        visibleSessions = sessionManager.allSessions.filter { sessionManager.isPresented($0) }

        if let preferred, visibleSessions.contains(where: { $0.id == preferred.id }),
           takesOverMountedElsewhere || !isMountedInAnotherDrawer(preferred) {
            activeSession = preferred
        } else if let activeSession, visibleSessions.contains(where: { $0.id == activeSession.id }),
                  !isMountedInAnotherDrawer(activeSession) {
            self.activeSession = activeSession
        } else {
            // セッションのcontentViewは1つしかない。他のウインドウに出ている
            // 中身を自動選択で取り上げると、向こうはタブだけ残して空になる。
            // 自動では他所の中身を取らない——取るのはタブを押した（意思のある）
            // ときだけ。全部が他所なら空のまま、タブは残る。
            activeSession = visibleSessions.last { !isMountedInAnotherDrawer($0) }
        }

        let rows = DrawerSessionTabs.rows(
            sources: visibleSessions.map {
                DrawerSessionTabs.Source(
                    id: $0.id,
                    kind: $0.kind,
                    customName: sessionManager.customName(for: $0),
                    role: sessionManager.role(for: $0),
                    directoryURL: $0.directoryURL,
                    isRunning: $0.isRunning,
                    isAnchored: $0.isAnchored
                )
            },
            currentDirectory: directoryURL,
            activeID: activeSession?.id
        )
        // 「タブを隠す」で隠したまま忘れると、動いているのにどこにも見えない。
        // 隠れて実行中の数をチップで示し、押せば管理パネルから戻せる。
        let hiddenRunningCount = sessionManager.allSessions
            .filter { $0.isRunning && !sessionManager.isPresented($0) }
            .count
        let plan = tabStripPlan(for: rows.count)
        if rows != renderedTabs
            || hiddenRunningCount != renderedHiddenCount
            || plan != renderedPlan {
            rebuildTabStrip(rows: rows, plan: plan, hiddenRunningCount: hiddenRunningCount)
            renderedTabs = rows
            renderedHiddenCount = hiddenRunningCount
            renderedPlan = plan
        }
        sessionTabs.isHidden = visibleSessions.isEmpty && renderedHiddenCount == 0
        // 右辺ではタブが2段目そのもの。増減で段の要否が変わったときだけ組み直す。
        if showsTabRow != (edge == .right && expanded && !visibleSessions.isEmpty) {
            applyEdgeLayout()
        }
        // The folder icon echoes the same cue for the place itself.
        let currentFolderHasLiveSession = directoryURL.map {
            sessionManager.sessions(for: $0).contains(where: \.isRunning)
        } ?? false
        directoryImage.contentTintColor = currentFolderHasLiveSession
            ? IntegratedPanelTheme.accent
            : IntegratedPanelTheme.secondaryText
        closeButton.isEnabled = activeSession != nil
        // tmuxで生きているぶんも数える。アプリを開き直した直後はこちらしか
        // 無く、繋いだ数だけを見せると「実行中0件」になる——動いているAIが
        // 1つも無いように読めてしまう。
        let summary = SessionCountSummary(
            attached: sessionManager.runningCount,
            detached: sessionManager.detachedRunningCount
        )
        manageSessionsButton.toolTip = summary.manageTooltip
        stripBadge.stringValue = summary.badgeText
        stripBadge.isHidden = summary.badgeText.isEmpty
        stripStatusIcon.contentTintColor = summary.isIdle
            ? IntegratedPanelTheme.secondaryText
            : IntegratedPanelTheme.accent
        stripStatusIcon.toolTip = summary.statusTooltip
        newSessionButton.isEnabled = directoryURL != nil
        newSessionButton.toolTip = "現在のFinderフォルダで新しいTerminalセッション"
        codexButton.isEnabled = sessionManager.canStart(.codex)
        codexButton.toolTip = codexButton.isEnabled ? nil : "codexコマンドが見つかりません"
        claudeButton.isEnabled = sessionManager.canStart(.claude)
        claudeButton.toolTip = claudeButton.isEnabled ? nil : "claudeコマンドが見つかりません"
        updateStartButtonTitles()
        showActiveTerminal()
    }

    /// tmux側に生き残りがあるフォルダでは、開始ボタンは新規起動ではなく再接続に
    /// なる（`new-session -A`が同じコマンドで両方を兼ねる）。tmuxも消えた後
    /// （Macの再起動など）でも、ここでclaudeを動かした記録があれば「前回の
    /// 続き」（`--continue`）として戻れる。表示だけ実態に合わせる。
    private func updateStartButtonTitles() {
        let buttons: [(NSButton, TerminalSessionKind)] = [
            (shellButton, .shell),
            (codexButton, .codex),
            (claudeButton, .claude)
        ]
        for (button, kind) in buttons {
            let reattaches = directoryURL.map {
                sessionManager.hasDetachedPersistentSession(kind: kind, directoryURL: $0)
            } ?? false
            let resumes = !reattaches && (directoryURL.map {
                sessionManager.hasResumableConversation(kind: kind, directoryURL: $0)
            } ?? false)
            button.title = reattaches
                ? "\(kind.displayName)に再接続"
                : resumes
                    ? "\(kind.displayName)で前回の続き"
                    : kind.displayName
        }
    }

    /// 幅が変われば詰め方も変わる。パネルの大きさを引きずって変えている
    /// 最中も追いつくよう、レイアウトのたびに見直す（変化が無ければ
    /// `rebuildTabStrip`まで行かずに済む）。
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !renderedTabs.isEmpty || renderedHiddenCount > 0 else { return }
        let plan = tabStripPlan(for: renderedTabs.count)
        guard plan != renderedPlan else { return }
        rebuildTabStrip(
            rows: renderedTabs,
            plan: plan,
            hiddenRunningCount: renderedHiddenCount
        )
        renderedPlan = plan
    }

    /// 帯に使える横幅から、何本をどこまで見せるかを決める。
    ///
    /// 右辺のパネルは細いので段を2つ使う——縦は余っていて、横だけが
    /// 足りない。下辺は横に長いので1段でよい。
    private func tabStripPlan(for tabCount: Int) -> DrawerTabStripPlanner.Plan {
        // 使える幅は、帯にもパネルの現寸にも聞かない。
        //
        // どちらも中身の幅で決まるので、それを基準にすると「入っているから
        // 削らなくてよい」と答え続け、代わりにパネルが横へ膨らんでファイル
        // 一覧を押し潰す。実測では、タブ10本ぶん（148pt×10≒1490pt）に
        // ちょうど一致する幅までパネルが広がっていた——「横がいっぱいに
        // なる」の正体はこれ。
        //
        // 中身に左右されない寸法だけを見る：右辺は使う人が決めた厚み、
        // 下辺はウインドウの幅。
        let panelWidth = edge == .right
            ? preferences.terminalThickness(for: .right)
            : (view.window?.frame.width ?? view.bounds.width)
        if edge == .right {
            // 2段目まるごとがタブ。左右の余白だけ引く。段は1つしか無いので、
            // 稼げるのは幅だけ——ここを2段と偽ると、入らない本数を並べて
            // タブが潰れる。
            return DrawerTabStripPlanner.plan(
                tabCount: tabCount,
                availableWidth: panelWidth - 24,
                rowCount: 1
            )
        }
        // 下辺は1段。パス表示と右端のボタン群のぶんを空けておく。
        return DrawerTabStripPlanner.plan(
            tabCount: tabCount,
            availableWidth: panelWidth - Self.bottomRowReserve,
            rowCount: 1
        )
    }

    /// 下辺のヘッダーで、タブ以外（パス・明るさ・配置・管理・＋・閉じる）が
    /// 使う幅の見積もり。
    private static let bottomRowReserve: CGFloat = 380

    private func rebuildTabStrip(
        rows: [DrawerSessionTab],
        plan: DrawerTabStripPlanner.Plan,
        hiddenRunningCount: Int
    ) {
        sessionTabs.arrangedSubviews.forEach {
            sessionTabs.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        // 並びは「今いる場所を先頭へ」で組み替えてあるので、押された1本は
        // 番号ではなくIDで引く。番号で引くと別のセッションが開く。
        for row in rows.prefix(plan.visibleCount) {
            guard let session = visibleSessions.first(where: { $0.id == row.id }) else { continue }
            sessionTabs.addArrangedSubview(
                makeTabButton(row: row, session: session, plan: plan)
            )
        }
        // 入り切らなかったぶんと、隠したまま動いているぶん。どちらも
        // 「見えていないが在る」なので、1つの数にまとめて一覧へ送る。
        let unseen = plan.overflow + hiddenRunningCount
        if unseen > 0 {
            sessionTabs.addArrangedSubview(makeOverflowChip(
                count: unseen,
                overflow: plan.overflow,
                hidden: hiddenRunningCount
            ))
        }
    }

    private func makeTabButton(
        row: DrawerSessionTab,
        session: any ManagedTerminalSession,
        plan: DrawerTabStripPlanner.Plan
    ) -> NSButton {
        let button = SessionTabButton()
        button.image = NSImage(
            systemSymbolName: row.kind.symbolName,
            accessibilityDescription: row.kind.displayName
        )
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        // 印は1つに絞る。記号の色だけで「動いているか」「今ここか」を言う——
        // 点と記号を別々に置くと、狭いタブでは点が隣との区切りに見えた。
        button.contentTintColor = row.isRunning
            ? (row.belongsToCurrentFolder ? IntegratedPanelTheme.accent : row.kind.tint)
            : IntegratedPanelTheme.secondaryText
        // 文字は「今ここか、よそか」。記号とは役割が違うので色を分ける。
        let titleColor = row.belongsToCurrentFolder || row.isActive
            ? IntegratedPanelTheme.text
            : IntegratedPanelTheme.secondaryText
        let text: String = switch plan.display {
        case .full: row.fullTitle
        case .nameOnly: row.compactTitle
        case .compact: row.shortLabel
        }
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: titleColor,
                .font: NSFont.systemFont(
                    ofSize: 11,
                    weight: row.isActive ? .semibold : .medium
                )
            ]
        )
        button.isBordered = false
        // 左寄せ。点・記号・名前をひと続きに見せ、名前の頭が縦に揃うので
        // 並んだタブを目で流して探せる。
        button.alignment = .left
        if let cell = button.cell as? NSButtonCell {
            cell.imageDimsWhenDisabled = false
        }
        button.identifier = NSUserInterfaceItemIdentifier(row.id.uuidString)
        button.target = self
        button.action = #selector(selectSession(_:))
        button.menu = sessionContextMenu(for: session)
        button.isActiveTab = row.isActive
        button.toolTip = row.tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        // 必須にしない。必須だと「この幅でなければならない」がパネルの
        // 最小幅になり、タブが増えるほどパネルが横へ育ってファイル一覧を
        // 押し潰す。譲れる優先度にしておけば、詰め方が追いつくまでの
        // 短い間はタブが縮むだけで済む。
        let width = button.widthAnchor.constraint(equalToConstant: plan.display.width)
        width.priority = .defaultHigh
        width.isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func makeOverflowChip(count: Int, overflow: Int, hidden: Int) -> NSButton {
        let chip = SessionTabButton()
        chip.title = "＋\(count)"
        chip.font = .systemFont(ofSize: 11, weight: .semibold)
        chip.contentTintColor = IntegratedPanelTheme.secondaryText
        chip.isBordered = false
        chip.target = self
        chip.action = #selector(showHiddenSessions)
        var reasons: [String] = []
        if overflow > 0 { reasons.append("帯に入り切らないぶん\(overflow)件") }
        if hidden > 0 { reasons.append("隠して実行中\(hidden)件") }
        chip.toolTip = reasons.joined(separator: "・") + " — 押すと一覧（⌘⌥T）で選べます"
        chip.translatesAutoresizingMaskIntoConstraints = false
        let width = chip.widthAnchor.constraint(
            equalToConstant: DrawerTabStripPlanner.overflowChipWidth
        )
        width.priority = .defaultHigh
        width.isActive = true
        chip.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return chip
    }

    /// このドロワー以外（別ウインドウのドロワー）にセッションの中身が
    /// 出ているか。contentViewは1つしかなく、こちらが取れば向こうから消える。
    private func isMountedInAnotherDrawer(_ session: any ManagedTerminalSession) -> Bool {
        guard let superview = session.contentView.superview else { return false }
        return superview !== terminalContainer
    }

    /// Re-adding a terminal view forces SwiftTerm to re-lay-out and reflow its
    /// buffer, so the mounted view is left alone when the active session has not
    /// actually changed — every folder change reaches this path.
    private func showActiveTerminal() {
        // IDの一致だけで早退してはいけない。別ウインドウが同じセッションを
        // マウントすると、ビューはこちらから黙って消える——「もう出ている」と
        // 信じたままだと、タブは見えるのに中身が空で、押しても何も起きない。
        // 実際にこの区画へ載っているときだけ何もしない。
        if mountedSessionID == activeSession?.id,
           let mounted = activeSession?.contentView,
           mounted.superview === terminalContainer {
            return
        }

        for subview in terminalContainer.subviews where subview !== emptyState {
            subview.removeFromSuperview()
        }
        guard let session = activeSession else {
            mountedSessionID = nil
            emptyState.isHidden = false
            return
        }
        emptyState.isHidden = true
        let terminal = session.contentView
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -8),
            terminal.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor, constant: -6)
        ])
        mountedSessionID = session.id
    }

    private func startSession(kind: TerminalSessionKind, resumingConversation: Bool = false) {
        guard let directoryURL else { return }
        do {
            let session = try sessionManager.create(
                kind: kind,
                directoryURL: directoryURL,
                resumingConversation: resumingConversation
            )
            reloadSessions(prefer: session, takesOverMountedElsewhere: true)
            if !expanded { onToggle?() }
            view.window?.makeFirstResponder(session.contentView)
        } catch {
            presentError(title: "セッションを開始できません", message: error.localizedDescription)
        }
    }

    @objc private func toggle() {
        onToggle?()
    }

    @objc private func showHiddenSessions() {
        onManageSessions?()
    }

    @objc private func togglePlacement() {
        onTogglePlacement?()
    }

    @objc private func showNewSessionMenu() {
        let menu = NSMenu(title: "新しいTerminalセッション")
        for (index, kind) in TerminalSessionKind.allCases.enumerated() {
            // ボタン側が「前回の続き」になっているときだけ、こちらが新規だと
            // 明示する。同じ名前で挙動が違う2つの入り口を作らない。
            let resumes = directoryURL.map {
                sessionManager.hasResumableConversation(kind: kind, directoryURL: $0)
            } ?? false
            let item = NSMenuItem(
                title: resumes ? "\(kind.displayName)（新規の会話）" : kind.displayName,
                action: #selector(startSessionFromMenu(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.target = self
            item.isEnabled = sessionManager.canStart(kind)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: newSessionButton.bounds.maxY + 2), in: newSessionButton)
    }

    /// ＋メニューは常に新規。ボタン側が「前回の続き」を担うので、まっさらに
    /// 始め直す道はこちらに残す。
    @objc private func startSessionFromMenu(_ sender: NSMenuItem) {
        guard TerminalSessionKind.allCases.indices.contains(sender.tag) else { return }
        startSession(kind: TerminalSessionKind.allCases[sender.tag])
    }

    @objc private func startSessionFromButton(_ sender: NSButton) {
        guard TerminalSessionKind.allCases.indices.contains(sender.tag) else { return }
        let kind = TerminalSessionKind.allCases[sender.tag]
        let resumes = directoryURL.map {
            sessionManager.hasResumableConversation(kind: kind, directoryURL: $0)
        } ?? false
        startSession(kind: kind, resumingConversation: resumes)
    }

    @objc private func selectSession(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = UUID(uuidString: raw),
              let session = visibleSessions.first(where: { $0.id == id }) else { return }
        activeSession = session
        reloadSessions(prefer: session, takesOverMountedElsewhere: true)
        // タブは畳んでいても見えている。押したのに中身が隠れたままでは
        // 「開けない」ので、startSessionと同じく本体も開く。
        if !expanded { onToggle?() }
        view.window?.makeFirstResponder(session.contentView)
        // ダブルクリックはブラウザもそのセッションの現在地へ連れて行く。
        // clickCountはマウスイベントにしか意味がない: Accessibility経由の
        // AXPressでは直前のキーイベントが残っていて偽の2を返し、押しただけで
        // ブラウザが飛ぶ（実測）。
        if let event = NSApp.currentEvent,
           event.type == .leftMouseUp || event.type == .leftMouseDown,
           event.clickCount == 2 {
            onOpenDirectory?(currentLocationURL(of: session))
        }
    }

    /// The place a session is *actually* at. A shell may have been `cd`-ed by
    /// hand, so the kernel's answer beats the registered folder; other kinds
    /// fall back to where they were started.
    private func currentLocationURL(of session: any ManagedTerminalSession) -> URL {
        if let live = session as? TerminalSession,
           let cwd = live.shellWorkingDirectoryPath {
            return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        }
        return session.directoryURL
    }

    @objc private func toggleAnchorFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        session.isAnchored.toggle()
        reloadSessions()
    }

    private func sessionContextMenu(
        for session: any ManagedTerminalSession
    ) -> NSMenu {
        let menu = NSMenu(title: session.kind.displayName)
        let id = session.id.uuidString
        func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            return item
        }
        // AIセッションはそもそも追従しない（cdを送れない）ので、固定トグルは
        // プレーンシェルにだけ出す。
        if session.kind == .shell {
            let follow = item(
                "フォルダ移動に追従（cd）",
                action: #selector(toggleAnchorFromMenu(_:))
            )
            follow.state = session.isAnchored ? .off : .on
            menu.addItem(follow)
        }
        menu.addItem(item(
            "このセッションの場所をブラウザで表示",
            action: #selector(openSessionDirectoryFromMenu(_:))
        ))
        // 名前は⌘⌥Tの管理パネルでも付けられるが、名乗らせたくなるのは
        // タブが並んで見分けが付かないこの場所。
        menu.addItem(item(
            session.kind == .claude ? "名前と役割…" : "名前を付ける…",
            action: #selector(renameSessionFromMenu(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "タブを隠す（実行は継続）",
            action: #selector(hideSessionFromMenu(_:))
        ))
        menu.addItem(item(
            "現在の表示を記録として保存…",
            action: #selector(saveTranscriptFromMenu(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "すべてのセッションを管理…",
            action: #selector(manageSessionsFromMenu(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "セッションを閉じる／終了…",
            action: #selector(terminateSessionFromMenu(_:))
        ))
        return menu
    }

    private func session(from menuItem: NSMenuItem) -> (any ManagedTerminalSession)? {
        guard let text = menuItem.representedObject as? String,
              let id = UUID(uuidString: text) else { return nil }
        return sessionManager.allSessions.first { $0.id == id }
    }

    /// 名前と役割は同じ紙で決める。「このタブは誰で、何をする人か」は
    /// ひと続きの話で、別々のダイアログに分けるほうが不自然。
    @objc private func renameSessionFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender), let window = view.window else { return }
        let supportsRole = session.kind == .claude

        let nameField = NSTextField(string: sessionManager.customName(for: session) ?? "")
        nameField.placeholderString = session.kind.displayName

        let roleField = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 68))
        roleField.string = sessionManager.role(for: session) ?? ""
        roleField.font = .systemFont(ofSize: 12)
        roleField.isRichText = false
        roleField.textContainerInset = NSSize(width: 4, height: 4)
        let roleScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 68))
        roleScroll.documentView = roleField
        roleScroll.hasVerticalScroller = true
        roleScroll.borderType = .bezelBorder

        let nameCaption = NSTextField(labelWithString: "名前（空欄で種類名に戻す）")
        let roleCaption = NSTextField(
            labelWithString: "役割（次に開始したときから効きます）"
        )
        for caption in [nameCaption, roleCaption] {
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
        }

        let stack = NSStackView(views: supportsRole
            ? [nameCaption, nameField, roleCaption, roleScroll]
            : [nameCaption, nameField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(12, after: nameField)
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: supportsRole ? 140 : 46)
        nameField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        roleScroll.widthAnchor.constraint(equalToConstant: 320).isActive = true
        roleScroll.heightAnchor.constraint(equalToConstant: 68).isActive = true

        let alert = NSAlert()
        alert.messageText = "セッションの名前と役割"
        alert.informativeText = supportsRole
            ? "役割はこのフォルダのClaudeに残り、次に開始したときのシステムプロンプトへ足されます。走っている最中に変えても、そのセッションの振る舞いは変わりません。"
            : "\(session.kind.displayName)には役割を渡す口が無いので、名前だけ決められます。"
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.sessionManager.renameSession(session, to: nameField.stringValue)
            if supportsRole {
                self.sessionManager.setRole(for: session, to: roleField.string)
            }
        }
    }

    @objc private func hideSessionFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        sessionManager.hideFromTabs(session)
    }

    @objc private func openSessionDirectoryFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        onOpenDirectory?(currentLocationURL(of: session))
    }

    @objc private func saveTranscriptFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        SessionTranscriptExporter.present(for: session, attachedTo: view.window)
    }

    @objc private func manageSessions() {
        onManageSessions?()
    }

    @objc private func manageSessionsFromMenu(_ sender: NSMenuItem) {
        onManageSessions?()
    }

    @objc private func terminateSessionFromMenu(_ sender: NSMenuItem) {
        guard let session = session(from: sender) else { return }
        confirmTermination(of: session)
    }

    @objc private func closeSession() {
        guard let session = activeSession else { return }
        confirmTermination(of: session)
    }

    private func confirmTermination(of session: any ManagedTerminalSession) {
        guard session.isRunning else {
            permanentlyRemoveSession(session, archiveTranscript: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "実行中の\(session.kind.displayName)をどうしますか？"
        alert.informativeText = session.persistence != nil
            ? "タブだけ隠せばtmuxを保持して後から戻せます。完全終了はtmux側も削除します。"
            : "タブだけ隠せばFinderAI内で実行を続け、セッションセンターから戻せます。"
        let archiveCheckbox = NSButton(
            checkboxWithTitle: "完全終了前に現在の表示を回復用ログへ保存",
            target: nil,
            action: nil
        )
        archiveCheckbox.state = .on
        alert.accessoryView = archiveCheckbox
        // Safe continuation is first/default. Pressing Return can never kill a
        // session; permanent termination requires clicking the second button.
        alert.addButton(withTitle: "実行を続けてタブを隠す")
        alert.addButton(withTitle: "完全に終了")
        alert.addButton(withTitle: "キャンセル")
        let handleResponse: @MainActor (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.hideSession(session)
            case .alertSecondButtonReturn:
                self.permanentlyRemoveSession(
                    session,
                    archiveTranscript: archiveCheckbox.state == .on
                )
            default:
                break
            }
        }
        guard let window = view.window else {
            handleResponse(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handleResponse)
    }

    private func hideSession(_ session: any ManagedTerminalSession) {
        sessionManager.hideFromTabs(session)
        if activeSession?.id == session.id { activeSession = nil }
        reloadSessions()
    }

    private func permanentlyRemoveSession(
        _ session: any ManagedTerminalSession,
        archiveTranscript: Bool
    ) {
        if archiveTranscript {
            do {
                _ = try SessionTranscriptExporter.archiveBeforeTermination(session)
            } catch {
                presentError(
                    title: "終了を中止しました",
                    message: "回復用のTerminal記録を保存できませんでした。\n\(error.localizedDescription)"
                )
                return
            }
        }
        removeSession(session)
    }

    private func removeSession(_ session: any ManagedTerminalSession) {
        sessionManager.remove(session)
        if activeSession?.id == session.id { activeSession = nil }
        reloadSessions()
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
