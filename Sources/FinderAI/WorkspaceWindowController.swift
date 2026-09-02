import AppKit
import FinderAICore

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    /// The pane commands act on. Menu items reach the window controller through
    /// the responder chain and are forwarded here, so "the browser" has to mean
    /// the one the user last touched, not always the left one.
    var browser: WorkspaceBrowserViewController { activePane }

    private let leftPane: WorkspaceBrowserViewController
    private var rightPane: WorkspaceBrowserViewController?
    private var activePane: WorkspaceBrowserViewController
    private let paneSplit = NSSplitView()
    private var splitEnabled = false
    private let terminal: DrawerContentViewController
    /// 下辺なら高さ、右辺なら幅。辺が変わるたびに別のアンカーで作り直す。
    private var terminalSizeConstraint: NSLayoutConstraint!
    private var edgeConstraints: [NSLayoutConstraint] = []
    private var terminalEdge: TerminalPanelEdge = .bottom
    private var terminalExpanded = false
    private var requestedTerminalThickness: CGFloat = 300
    private var positioned = false
    private let preferences: WorkspacePreferences
    private let sessionManager: any TerminalSessionManaging
    private let themePainter = ThemedLayerPainter()
    private var rootController: NSViewController!

    /// このウインドウの通し番号。閉じても詰め直さないので、セッション中ずっと
    /// 同じ番号を指す——並び替えで動く番号は覚えられない。
    let serial: Int

    var onClose: (() -> Void)?
    var onManageTerminalSessions: (() -> Void)? {
        didSet { terminal.onManageSessions = onManageTerminalSessions }
    }
    /// どのペインであれフォルダが変わったら呼ばれる。コーディネータが復元用
    /// スナップショットを撮り直すためのフックで、UIの追従とは独立。
    var onDirectoryChanged: (() -> Void)?
    private let restoresFrame: Bool

    init(
        sessionManager: any TerminalSessionManaging,
        initialDirectory: URL,
        preferences: WorkspacePreferences = WorkspacePreferences(),
        restoresFrame: Bool = true,
        serial: Int = 0
    ) {
        self.serial = serial
        self.preferences = preferences
        self.restoresFrame = restoresFrame
        self.sessionManager = sessionManager
        leftPane = WorkspaceBrowserViewController(
            initialDirectory: initialDirectory,
            preferences: preferences
        )
        activePane = leftPane
        terminal = DrawerContentViewController(
            sessionManager: sessionManager,
            preferences: preferences
        )
        let rootController = NSViewController()
        let root = ThemedRootView()
        // ウインドウ全体はファイル一覧に合わせる。ここは一覧とターミナルの
        // すき間で、どちらつかずの明るさだと境目だけ浮く。
        root.appearance = preferences.browserAppearance.nsAppearance
        themePainter.appearance = root.appearance
        rootController.view = root

        let window = TerminalWheelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = initialDirectory.lastPathComponent.isEmpty
            ? "FinderAI"
            : initialDirectory.lastPathComponent
        window.subtitle = "FinderAI"
        window.titlebarSeparatorStyle = .shadow
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 520)
        window.collectionBehavior = [.fullScreenPrimary]
        // `.preferred` forces every new window to merge into the existing one as a
        // tab: ⌘N produced a second tab at the identical frame, not a window.
        // `.automatic` follows the user's "Prefer tabs" setting, whose default is
        // full screen only — so ⌘N gives a real window, and anyone who wants tabs
        // still gets them.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "FinderAIWorkspace"
        window.contentViewController = rootController
        super.init(window: window)
        // 塗りの控えはsuper.initの後で。それより前は自分を触れない。
        root.onAppearanceChanged = { [weak self] in self?.themePainter.repaint() }
        themePainter.register(root, role: .frame) { IntegratedPanelTheme.background }
        window.delegate = self

        rootController.addChild(leftPane)
        rootController.addChild(terminal)
        self.rootController = rootController

        // The panes live in a split view even when there is only one, so turning
        // the second on is adding a subview rather than rebuilding the window.
        paneSplit.isVertical = true
        paneSplit.dividerStyle = .thin
        paneSplit.addArrangedSubview(leftPane.view)
        paneSplit.delegate = self

        [paneSplit, terminal.view].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        terminalEdge = preferences.terminalEdge
        requestedTerminalThickness = preferences.terminalThickness(for: terminalEdge)
        terminalExpanded = preferences.terminalExpanded
        // 辺はドロワーの内部レイアウトも決めるので、開閉より先に伝える。
        terminal.setEdge(terminalEdge)
        terminal.setDirectory(initialDirectory)
        terminal.setExpanded(terminalExpanded)
        installEdgeLayout()

        wire(leftPane)
        terminal.onToggle = { [weak self] in self?.toggleTerminal() }
        terminal.onResizeDelta = { [weak self] delta in self?.resizeTerminal(by: delta) }
        terminal.onTogglePlacement = { [weak self] in self?.toggleTerminalEdge() }
        terminal.onCycleSnap = { [weak self] in self?.cycleTerminalSize() }
        terminal.onOpenDirectory = { [weak self] url in
            self?.activePane.navigate(to: url)
        }
        window.setContentSize(NSSize(width: 1180, height: 760))
        updateWindowMinimumSize()

        if preferences.splitEnabled { setSplitEnabled(true) }
    }

    /// A pane reports its folder and its focus; the terminal and the title follow
    /// whichever pane the user is actually in.
    private func wire(_ pane: WorkspaceBrowserViewController) {
        pane.onDirectoryChange = { [weak self, weak pane] url in
            guard let self, let pane else { return }
            self.onDirectoryChanged?()
            guard pane === self.activePane else { return }
            self.terminal.setDirectory(url)
            self.window?.representedURL = url
        }
        pane.onToggleTerminal = { [weak self] in self?.toggleTerminal() }
        // 色はペインではなく窓の持ちもの。どちらのペインのボタンから選んでも
        // 窓ぜんぶに掛かる。
        pane.onSelectTint = { [weak self] tint in self?.setTint(tint) }
        pane.onBecameActive = { [weak self, weak pane] in
            guard let self, let pane, pane !== self.activePane else { return }
            self.activePane = pane
            self.terminal.setDirectory(pane.currentDirectory)
            self.window?.representedURL = pane.currentDirectory
            self.updatePaneHighlight()
            // 名前はコーディネータが決める（同名フォルダが重なったときだけ
            // 親を添える）。ここで直に書くと、その気配りを飛ばした名前が
            // 一瞬出てから上書きされる。
            self.onDirectoryChanged?()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 明るさを選び直したときに、この1枚ぶんを掛け替える。
    func applyAppearance() {
        let wanted = preferences.browserAppearance.nsAppearance
        window?.contentViewController?.view.appearance = wanted
        themePainter.appearance = wanted
        themePainter.repaint()
        leftPane.applyAppearance()
        rightPane?.applyAppearance()
        terminal.applyAppearance()
        // 明るさが変われば混ぜる先の地も変わる。タイトルバーだけは
        // 塗る控えの外に居るので、ここで一緒に塗り直す。
        applyTitlebarTint()
    }

    /// このウインドウの目印の色。`nil`なら従来どおりの灰。
    private(set) var tint: WorkspaceWindowTint?

    /// 色が変わったら呼ばれる。コーディネータが構成を撮り直し、
    /// メニューの印と一覧を引き直すためのフック。ボタンから選んでも
    /// メニューから選んでも、後始末はここ一本に通す。
    var onTintChanged: (() -> Void)?

    /// 目印の色を掛け替える。額縁（タイトルバー・ツールバー・サイドバー・
    /// 下帯・ターミナルの見出し）にだけ効き、ファイル一覧の地は変わらない。
    func setTint(_ tint: WorkspaceWindowTint?) {
        self.tint = tint
        themePainter.tint = tint
        themePainter.repaint()
        leftPane.applyTint(tint)
        rightPane?.applyTint(tint)
        terminal.applyTint(tint)
        applyTitlebarTint()
        onTintChanged?()
    }

    /// タイトルバーを塗る。
    ///
    /// ここだけAppKitが描くので`ThemedLayerPainter`が届かない。
    /// `titlebarAppearsTransparent`を立てると、その帯にウインドウの背景色が
    /// 出る——`.fullSizeContentView`を持たないので、中身の配置は動かない。
    /// 色を外したら透明を降ろす。立てたままにすると、色なしの窓だけ
    /// 素材感の違うタイトルバーになる。
    private func applyTitlebarTint() {
        guard let window else { return }
        guard let tint else {
            window.titlebarAppearsTransparent = false
            window.backgroundColor = .windowBackgroundColor
            return
        }
        let appearance = window.contentViewController?.view.effectiveAppearance
            ?? window.effectiveAppearance
        var painted: NSColor = .windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            painted = ThemedLayerPainter.blend(
                tint,
                into: IntegratedPanelTheme.header,
                isDark: appearance.isDark
            )
        }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = painted
    }

    func show() {
        // Only the first window claims the autosaved frame. Giving every window
        // the same autosave name would have them overwrite each other's position
        // and reopen stacked.
        if !positioned, restoresFrame {
            if window?.setFrameUsingName(Self.frameAutosaveName) != true {
                window?.center()
            }
            window?.setFrameAutosaveName(Self.frameAutosaveName)
            positioned = true
        }
        pullOntoScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Places this window one step along the cascade and returns where the next
    /// one goes.
    ///
    /// The running point has to be owned by the caller, not derived from "the
    /// window in front": opening several in a row leaves the key window unchanged
    /// between calls, so every new window cascaded off window 1 and landed on the
    /// same spot. `cascadeTopLeft(from:)` is AppKit's own walk and wraps back to
    /// the top when it reaches the screen edge.
    @discardableResult
    func cascade(from point: NSPoint) -> NSPoint {
        positioned = true
        guard let window else { return point }
        let seed = point == .zero
            ? NSPoint(x: window.frame.minX, y: window.frame.maxY)
            : point
        return window.cascadeTopLeft(from: seed)
    }

    /// Where the *next* window should go if the cascade starts from this one.
    ///
    /// `cascadeTopLeft(from:)` places the window at the point it is given and
    /// returns the following slot, so handing it this window's own top-left leaves
    /// the window exactly where it is and yields the next position. Seeding a
    /// cascade with the raw origin instead drops the new window straight onto this
    /// one.
    var cascadeOrigin: NSPoint {
        guard let window else { return .zero }
        return window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
    }

    /// 保存された位置が、いまのモニタ構成のどこにも無いことがある。
    ///
    /// 外部モニタを外す・並びを変えると、前回の座標は誰の画面でもない場所を指す。
    /// ウインドウは開いているのに画面のどこにも見えず、Dockから開き直すまで
    /// 戻ってこない——「表示できていない」という形で現れる（実際に起きた）。
    private func pullOntoScreen() {
        guard let window else { return }
        let frame = window.frame
        // 端がわずかに掛かっているだけでは「見えている」とは言えない。掴める
        // だけの面積が画面に載っているかで判断する。
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            guard !overlap.isNull else { return false }
            return overlap.width >= 120 && overlap.height >= 80
        }
        guard !visible else { return }
        window.center()
    }

    private static let frameAutosaveName = NSWindow.FrameAutosaveName("FinderAIWorkspaceWindow")

    func windowWillClose(_ notification: Notification) {
        if let rightPane { preferences.secondDirectory = rightPane.currentDirectory }
        onClose?()
    }
}

extension WorkspaceWindowController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        splitView === paneSplit ? Self.minimumPaneWidth : proposedMinimumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === paneSplit else { return proposedMaximumPosition }
        // Each pane carries its own sidebar and columns; letting one shrink past
        // this leaves a strip too narrow to read. The divider sits between them,
        // so its thickness comes out of the width too — without it the right pane
        // lands one point short of the minimum.
        return max(
            Self.minimumPaneWidth,
            splitView.bounds.width - Self.minimumPaneWidth - splitView.dividerThickness
        )
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === paneSplit,
              rightPane != nil,
              paneSplit.bounds.width > 0,
              let left = paneSplit.arrangedSubviews.first else { return }
        preferences.splitRatio = left.frame.width / paneSplit.bounds.width
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // Collapsing would leave an invisible pane still taking commands; ⌃⌘S is
        // the way out.
        false
    }

    /// NSBrowser keeps its own responder chain while column view has focus. The
    /// window controller exposes the same selector as the browser so the
    /// target-less View menu and ⌘2 remain enabled in every view mode.
    @objc func toggleColumnView() {
        browser.toggleColumnView()
    }

    @objc func toggleTerminal() {
        setTerminalExpanded(!terminalExpanded)
    }

    /// ⌃Tab／⌃⇧Tab。帯が詰まって数へ送られたセッションにも、ここからなら
    /// 辿り着ける——押せる的が無くても回れば必ず来る。
    @objc func selectNextSession() {
        terminal.selectAdjacentSession(offset: 1)
    }

    @objc func selectPreviousSession() {
        terminal.selectAdjacentSession(offset: -1)
    }

    /// ⌘⌥J、ヘッダーの配置ボタン、設定ウインドウの共通の出口。
    @objc func toggleTerminalEdge() {
        setTerminalEdge(terminalEdge.opposite)
    }

    /// 設定ウインドウから、開いている全ウインドウへ同じ辺を配る。
    func applyTerminalEdge(_ edge: TerminalPanelEdge) {
        setTerminalEdge(edge)
    }

    /// このウインドウが見せているフォルダ。ウインドウ同士の見分けと、同じ場所を
    /// 二重に開かないための照合に使う。
    var displayedDirectory: URL { activePane.currentDirectory }

    /// タイトルの出しかたはコーディネータが決める。同名フォルダを何枚も開いたとき、
    /// どれがどれか分からなくなるのを避けるため、重なったときだけ親フォルダを添える。
    func applyDisplayTitle(_ title: String, subtitle: String) {
        window?.title = title
        window?.subtitle = subtitle
    }

    /// ヘッダーのダブルクリック。畳む→半分→最大→畳む、と一段ずつ進む。
    @objc func cycleTerminalSize() {
        let next = TerminalPanelLayout.nextSnap(
            currentThickness: terminalSizeConstraint.constant,
            isExpanded: terminalExpanded,
            edge: terminalEdge,
            available: availableThickness,
            browserMinimum: browserMinimumThickness
        )
        guard let thickness = TerminalPanelLayout.thickness(
            for: next,
            edge: terminalEdge,
            available: availableThickness,
            browserMinimum: browserMinimumThickness
        ) else {
            setTerminalExpanded(false)
            return
        }
        setTerminalExpanded(true, thickness: thickness)
    }

    private func setTerminalExpanded(_ expanded: Bool, thickness: CGFloat? = nil) {
        terminalExpanded = expanded
        preferences.terminalExpanded = expanded
        terminal.setExpanded(expanded)
        if expanded, let thickness {
            requestedTerminalThickness = clampedTerminalThickness(thickness)
            preferences.setTerminalThickness(requestedTerminalThickness, for: terminalEdge)
        }
        terminalSizeConstraint.constant = expanded
            ? clampedTerminalThickness(requestedTerminalThickness)
            : TerminalPanelLayout.collapsedThickness
        animateLayout()
    }

    private func setTerminalEdge(_ edge: TerminalPanelEdge) {
        guard edge != terminalEdge else { return }
        terminalEdge = edge
        preferences.terminalEdge = edge
        // 高さと幅は別に覚えてあるので、戻ってきたときは前回の大きさが復活する。
        requestedTerminalThickness = preferences.terminalThickness(for: edge)
        terminal.setEdge(edge)
        updateWindowMinimumSize()
        installEdgeLayout()
        animateLayout()
    }

    private func animateLayout() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window?.contentView?.animator().layoutSubtreeIfNeeded()
        }
    }

    /// 制約を辺ごとに丸ごと差し替える。高さと幅ではアンカーが違うので、
    /// 定数の付け替えでは足りない。
    private func installEdgeLayout() {
        guard let root = rootController?.view else { return }
        NSLayoutConstraint.deactivate(edgeConstraints)
        let browserView: NSView = paneSplit
        let terminalView = terminal.view
        let size = terminalExpanded
            ? clampedTerminalThickness(requestedTerminalThickness)
            : TerminalPanelLayout.collapsedThickness

        var constraints: [NSLayoutConstraint]
        let browserMinimum: NSLayoutConstraint
        switch terminalEdge {
        case .bottom:
            terminalSizeConstraint = terminalView.heightAnchor.constraint(equalToConstant: size)
            browserMinimum = browserView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Self.minimumBrowserHeight
            )
            constraints = [
                browserView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                browserView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                browserView.topAnchor.constraint(equalTo: root.topAnchor),
                browserView.bottomAnchor.constraint(equalTo: terminalView.topAnchor),
                terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ]
        case .right:
            terminalSizeConstraint = terminalView.widthAnchor.constraint(equalToConstant: size)
            browserMinimum = browserView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: minimumBrowserWidth
            )
            constraints = [
                browserView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                browserView.topAnchor.constraint(equalTo: root.topAnchor),
                browserView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                browserView.trailingAnchor.constraint(equalTo: terminalView.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: root.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ]
        }
        // The terminal must yield to the browser's minimum, otherwise a large
        // terminal in a small window silently eats the file list: rows and the
        // status bar get clipped out of view with nothing to stop it. Ranking the
        // size below the minimum makes the terminal shrink instead.
        terminalSizeConstraint.priority = .defaultHigh
        browserMinimum.priority = .required
        constraints.append(contentsOf: [browserMinimum, terminalSizeConstraint])
        NSLayoutConstraint.activate(constraints)
        edgeConstraints = constraints
    }

    var terminalPanelThickness: CGFloat { terminalSizeConstraint.constant }
    var isTerminalExpanded: Bool { terminalExpanded }
    var terminalPanelEdge: TerminalPanelEdge { terminalEdge }

    func showTerminal() {
        guard !terminalExpanded else { return }
        toggleTerminal()
    }

    /// ⌃⌘S. The second pane opens on the same folder, which is what "split this"
    /// almost always means — you then navigate one side away.
    @objc func toggleSplit() {
        setSplitEnabled(!splitEnabled)
        preferences.splitEnabled = splitEnabled
    }

    var isSplit: Bool { splitEnabled }

    /// The pane splitter. Exposed because it is indistinguishable from a pane's
    /// own sidebar splitter by inspection — both are vertical with two subviews.
    var paneSplitViewForTesting: NSSplitView { paneSplit }

    private func setSplitEnabled(_ enabled: Bool) {
        guard enabled != splitEnabled else { return }
        splitEnabled = enabled

        if enabled {
            let directory = preferences.secondDirectory ?? leftPane.currentDirectory
            let pane = WorkspaceBrowserViewController(
                initialDirectory: directory,
                preferences: preferences,
                showsSidebar: false
            )
            rootController.addChild(pane)
            paneSplit.addArrangedSubview(pane.view)
            wire(pane)
            rightPane = pane
            // Half a window is not enough for a sidebar and a readable list.
            leftPane.setSidebarVisible(false)
            paneSplit.layoutSubtreeIfNeeded()
            applySplitRatio()
        } else {
            // Closing the split hands focus back rather than leaving commands
            // pointed at a pane that no longer exists.
            if let rightPane {
                preferences.secondDirectory = rightPane.currentDirectory
                rightPane.view.removeFromSuperview()
                rightPane.removeFromParent()
            }
            rightPane = nil
            activePane = leftPane
            leftPane.setSidebarVisible(true)
            terminal.setDirectory(leftPane.currentDirectory)
        }
        updatePaneHighlight()
        // 2枚目のペインは右辺のターミナルと横幅を取り合う。下限が変わるので
        // ウインドウの最小サイズと制約を引き直す。
        if terminalEdge == .right {
            updateWindowMinimumSize()
            installEdgeLayout()
        }
        window?.makeFirstResponder(activePane.view)
        // 見ている場所が変わったのと同じこと。ウインドウ名も俯瞰も台帳も、
        // どれもactivePaneの現在地から作るので、ここで知らせないと
        // 「閉じた2枚目の場所」を名乗り続ける——中身はわさびなのに
        // タイトルはCloudStorage、という状態を実機で踏んだ。
        onDirectoryChanged?()
    }

    private func applySplitRatio() {
        guard rightPane != nil, paneSplit.bounds.width > 0 else { return }
        paneSplit.setPosition(paneSplit.bounds.width * preferences.splitRatio, ofDividerAt: 0)
    }

    /// With two identical panes there is nothing to say which one a command will
    /// hit, so the inactive one is dimmed.
    private func updatePaneHighlight() {
        guard rightPane != nil else {
            leftPane.setPaneActive(true)
            return
        }
        leftPane.setPaneActive(activePane === leftPane)
        rightPane?.setPaneActive(activePane === rightPane)
    }

    static let minimumBrowserHeight: CGFloat = 220
    static let minimumPaneWidth: CGFloat = 380
    private static let baseWindowMinimumSize = NSSize(width: 820, height: 520)

    /// 分割中は2枚ぶんの読める幅が要る。右辺のターミナルはその残りを分け合う。
    private var minimumBrowserWidth: CGFloat {
        splitEnabled
            ? Self.minimumPaneWidth * 2 + paneSplit.dividerThickness
            : Self.minimumPaneWidth
    }

    private var browserMinimumThickness: CGFloat {
        terminalEdge == .bottom ? Self.minimumBrowserHeight : minimumBrowserWidth
    }

    private var availableThickness: CGFloat {
        let bounds = window?.contentView?.bounds ?? .zero
        return terminalEdge == .bottom ? bounds.height : bounds.width
    }

    /// The largest terminal this window can show while the file list still keeps
    /// its minimum. A size saved from a bigger window, or a window shrunk after
    /// the fact, would otherwise push the list out of sight.
    func clampedTerminalThickness(_ proposed: CGFloat) -> CGFloat {
        TerminalPanelLayout.clamped(
            proposed,
            edge: terminalEdge,
            available: availableThickness,
            browserMinimum: browserMinimumThickness
        )
    }

    /// 右辺に置くと、ブラウザとターミナルの下限が横方向で足し算になる。既定の
    /// 最小幅のままだと両方の最小を同時に満たせず、どちらかが潰れる。
    private func updateWindowMinimumSize() {
        guard let window else { return }
        let minimum: NSSize
        switch terminalEdge {
        case .bottom:
            minimum = Self.baseWindowMinimumSize
        case .right:
            let needed = minimumBrowserWidth + TerminalPanelLayout.minimumThickness(for: .right)
            minimum = NSSize(
                width: max(Self.baseWindowMinimumSize.width, needed),
                height: Self.baseWindowMinimumSize.height
            )
        }
        window.minSize = minimum
        // minSizeはこれから起きるリサイズにしか効かない。今が狭いなら広げる。
        guard window.frame.width < minimum.width else { return }
        var frame = window.frame
        frame.size.width = minimum.width
        window.setFrame(frame, display: true, animate: false)
    }

    private func resizeTerminal(by delta: CGFloat) {
        guard terminalExpanded else { return }
        requestedTerminalThickness = clampedTerminalThickness(requestedTerminalThickness + delta)
        terminalSizeConstraint.constant = requestedTerminalThickness
        preferences.setTerminalThickness(requestedTerminalThickness, for: terminalEdge)
    }

    /// モニタの並びが変わったときに、コーディネータから呼ばれる。
    func rescueOffscreenWindow() {
        pullOntoScreen()
    }

    /// Shrinking the window must not let a previously fine terminal size start
    /// eating the list.
    func windowDidResize(_ notification: Notification) {
        guard terminalExpanded else { return }
        terminalSizeConstraint.constant = clampedTerminalThickness(requestedTerminalThickness)
    }
}
