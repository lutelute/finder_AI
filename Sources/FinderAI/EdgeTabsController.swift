import AppKit
import FinderAICore

/// 画面の縁に貼り付く、フォルダのタブ。
///
/// Dockは画面の下端にあるが作業は画面の上半分で起きるので、そこへ往復するのが
/// 動線として合わない——という不満が出発点。縁のタブなら手が届く位置に置ける。
///
/// FinderAIのウインドウが前面にいなくても使えることが要点なので、パネルは
/// `.nonactivatingPanel`で、押してもこのアプリは前面に出ない。ホバーの検出は
/// パネル自身の`NSTrackingArea`と、隠れているあいだのマウス座標の監視だけで行う:
/// `addGlobalMonitorForEvents`は入力監視の許可を要求するので、同じ効果が権限なしで
/// 出せるならそちらを採る。
///
/// 帯はモニタごとに1本ずつ出す。1本だけ作ってマウスのいる画面へ動かす作りだと、
/// 「今見ている画面の端に当てても、帯は前の画面にいるので何も起きない」が起きた。
@MainActor
final class EdgeTabsController {
    /// フォルダを前に出す（FinderAIのウインドウ、またはFinderのウインドウ）。
    var onOpenDirectory: ((URL) -> Void)?
    /// そのフォルダのTerminalセッションを前面に出す（無ければ開始する）。
    var onRevealTerminal: ((URL) -> Void)?
    /// 独立した一覧のウインドウを開く（メニューから呼ぶ経路）。
    var onShowWindows: (() -> Void)?
    /// いま見ているフォルダを袖に入れる。空の袖に出す「＋」から呼ぶ。
    var onAddCurrentFolder: (() -> Void)?
    /// 袖から広げる一覧に出す中身。
    var windowRowsProvider: (() -> [WorkspaceWindowsPanelController.Row])?
    var onSelectWindow: ((ObjectIdentifier) -> Void)?
    var onCloseWindow: ((ObjectIdentifier) -> Void)?
    /// 行に触れているあいだ、そのウインドウを仮に前へ出す／戻す。
    var onPreviewWindow: ((ObjectIdentifier) -> Void)?
    var onEndPreviewWindows: (() -> Void)?
    /// いま開いているウインドウの配置。袖の先頭に俯瞰として描く。
    var windowsLayoutProvider: (() -> EdgeWindowsTabButton.Layout)?

    private let preferences: WorkspacePreferences
    /// 縁のタブに実行中の印を出すためだけに見る。セッションを触りはしない。
    private let sessionManager: (any TerminalSessionManaging)?
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?

    /// 1枚のモニタに出ている帯。
    @MainActor
    private final class Strip {
        let panel: EdgeTabPanel
        let container = EdgeStripHoverView()
        var tabs: [EdgeTabButton] = []
        /// ウインドウの俯瞰。フォルダを1つも入れていなくても、これだけは出る。
        var windowsTab: EdgeWindowsTabButton?
        /// フォルダが1つも入っていないときだけ出る、入れるための的。
        var addTab: EdgeActionTabButton?
        var isHidden = false
        /// この帯が貼り付いている縁。カーソルのいる側へ移るので、画面ごとに違う。
        var edge: WorkspaceScreenEdge = .right

        init(panel: EdgeTabPanel) {
            self.panel = panel
            panel.contentView = container
        }
    }

    private var strips: [CGDirectDisplayID: Strip] = [:]
    private let popover: EdgeTabPopoverController
    /// 袖に入れた全フォルダを縦積みで見せるほう。設定でこちらを使う。
    private let accordion: EdgeTabAccordionController
    /// 袖から広げるウインドウの一覧。別ウインドウを立てない。
    private let windowsList = EdgeWindowsListController()
    private var tabs = WorkspaceEdgeTabs()
    private var isEnabled = false
    private var edge: WorkspaceScreenEdge = .right
    /// 普段は画面の外へ引っ込め、縁に触れたときだけ滑り出す。
    private var autoHide = false

    private var hideTask: Task<Void, Never>?
    /// カーソルのいる側へ帯を移すための見張り。
    private var pointerFollowTask: Task<Void, Never>?
    private static let pointerFollowInterval = Duration.milliseconds(350)
    private static let slideDuration = 0.16
    /// ポップアップから何かを掴んでいる最中。掴んだまま土台が消えると置けない。
    private var isDraggingFromPopover = false

    /// マウスが通り過ぎただけで開かないための滞留時間と、タブとポップアップの
    /// あいだをカーソルが渡る猶予。どちらも無いと、この種のUIは「触ってもいない
    /// のに開く」「渡ろうとすると消える」のどちらかになる。
    private static let openDelay = Duration.milliseconds(200)
    private static let closeDelay = Duration.milliseconds(400)
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    init(
        preferences: WorkspacePreferences,
        sessionManager: (any TerminalSessionManaging)? = nil
    ) {
        self.preferences = preferences
        self.sessionManager = sessionManager
        popover = EdgeTabPopoverController(preferences: preferences)
        accordion = EdgeTabAccordionController(preferences: preferences)
        popover.onOpenDirectory = { [weak self] url in
            self?.hidePopover()
            self?.onOpenDirectory?(url)
        }
        popover.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            if isInside {
                self.cancelClose()
            } else {
                self.scheduleClose()
            }
        }
        popover.onDraggingChanged = { [weak self] isDragging in
            guard let self else { return }
            self.isDraggingFromPopover = isDragging
            // 掴んだものの行き先はタブでもある。隠す設定でも、運んでいるあいだは
            // 出しておく。
            if isDragging { self.revealAllStrips() }
        }
        popover.onRequestDismiss = { [weak self] in
            self?.hidePopover()
            self?.hideStripsIfAutoHiding()
        }
        accordion.onOpenDirectory = { [weak self] url in
            self?.hidePopover()
            self?.onOpenDirectory?(url)
        }
        accordion.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            if isInside { self.cancelClose() } else { self.scheduleClose() }
        }
        accordion.onDraggingChanged = { [weak self] isDragging in
            guard let self else { return }
            self.isDraggingFromPopover = isDragging
            if isDragging { self.revealAllStrips() }
        }
        accordion.onRequestDismiss = { [weak self] in
            self?.hidePopover()
            self?.hideStripsIfAutoHiding()
        }
        windowsList.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            if isInside { self.cancelClose() } else { self.scheduleClose() }
        }
        windowsList.onRequestDismiss = { [weak self] in
            self?.hidePopover()
            self?.hideStripsIfAutoHiding()
        }
        windowsList.onSelect = { [weak self] id in
            self?.hidePopover()
            self?.onSelectWindow?(id)
        }
        windowsList.onClose = { [weak self] id in
            guard let self else { return }
            self.onCloseWindow?(id)
            // 閉じた1枚を残した一覧は、次に押した行が別のウインドウになる。
            self.windowsList.refresh(rows: self.windowRowsProvider?() ?? [])
        }
        windowsList.onPreview = { [weak self] id in self?.onPreviewWindow?(id) }
        windowsList.onEndPreview = { [weak self] in self?.onEndPreviewWindows?() }
        reload()
        startPointerFollow()
        // スクリーンの抜き差しや解像度変更で、帯の要る枚数と位置が変わる。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildStrips() }
        }
        if let sessionManager {
            // 走っているセッションの所在を縁にも映す。ドロワーのタブ帯と同じ
            // 通知を見るので、片方だけ古い、が起きない。
            sessionsObserver = NotificationCenter.default.addObserver(
                forName: .terminalSessionsDidChange,
                object: sessionManager,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSessionBadges() }
            }
        }
    }

    deinit {
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
        hideTask?.cancel()
        pointerFollowTask?.cancel()
    }

    // MARK: - 状態

    func reload() {
        tabs = preferences.edgeTabs
        isEnabled = preferences.edgeTabsEnabled
        edge = preferences.edgeTabsEdge
        autoHide = preferences.edgeTabsAutoHide
        rebuildStrips()
    }

    /// 袖を出すか。
    ///
    /// フォルダを1つも入れていなくても出す——ウインドウの俯瞰が先頭にあるので、
    /// 空の袖にも見るものがある。「常に縁にある」ことがこの機能の前提で、
    /// 中身が空だから消える、では手を伸ばす先が無くなる。
    var isVisible: Bool { isEnabled }
    var isAutoHiding: Bool { autoHide }
    var currentEdge: WorkspaceScreenEdge { edge }
    var isEnabledSetting: Bool { isEnabled }

    func contains(_ url: URL) -> Bool { tabs.contains(url) }

    /// フォルダを縁に置く／外す。空になったら帯ごと消える。
    func toggle(_ url: URL) {
        var updated = tabs
        let wasPresent = updated.contains(url)
        updated.toggle(url)
        if !wasPresent, updated.contains(url) {
            // 最初の1つを足したときは、機能ごと点ける。ここで自動で有効にしないと
            // 「追加したのに何も起きない」になる。
            preferences.edgeTabsEnabled = true
        }
        preferences.edgeTabs = updated
        reload()
    }

    /// 追加できたかどうか。上限に当たった場合はfalseで、呼び出し側が理由を言う。
    func canAdd(_ url: URL) -> Bool {
        tabs.contains(url) || !tabs.isFull
    }

    func setEnabled(_ enabled: Bool) {
        preferences.edgeTabsEnabled = enabled
        reload()
    }

    func setEdge(_ edge: WorkspaceScreenEdge) {
        preferences.edgeTabsEdge = edge
        reload()
    }

    func setAutoHide(_ enabled: Bool) {
        preferences.edgeTabsAutoHide = enabled
        reload()
    }

    // MARK: - 帯の組み立て

    /// モニタの数だけ帯を作り直す。無くなった画面のものは片付ける。
    private func rebuildStrips() {
        guard isVisible else {
            strips.values.forEach { $0.panel.orderOut(nil) }
            strips = [:]
            hidePopover()
            return
        }

        // どのモニタにも置く。作業している画面に無いのでは「常に手の届く場所」に
        // ならない。画面と画面の継ぎ目に当たる縁にも置く——そこはカーソルが
        // 通り抜ける場所でもあるが、避けると広い画面の内側の縁が丸ごと使えなくなる。
        // 3440ptの画面で左に手があっても、右端まで往復することになっていた。
        // 継ぎ目に2本が重なる件は、置いたあとに`resolveSeamConflicts`が解く。
        let hosts = NSScreen.screens

        var live: Set<CGDirectDisplayID> = []
        for screen in hosts {
            guard let id = screen.displayID else { continue }
            live.insert(id)
            let strip = strips[id] ?? {
                let created = Strip(panel: EdgeTabPanel())
                created.isHidden = autoHide
                created.edge = edge
                strips[id] = created
                return created
            }()
            strip.edge = edge
            buildTabs(in: strip, on: screen)
            layout(strip, on: screen)
        }
        for (id, strip) in strips where !live.contains(id) {
            strip.panel.orderOut(nil)
            strips.removeValue(forKey: id)
        }
        // 全画面が同じ縁を向くので、継ぎ目では必ずぶつかる。ここで片方を退ける。
        // カーソルのいる画面に先に選ばせる——手元の画面が優先されるべき。
        let pointerScreen = NSScreen.screens
            .first { $0.frame.contains(NSEvent.mouseLocation) }?
            .displayID
        resolveSeamConflicts(preferring: pointerScreen)
        refreshSessionBadges()
    }

    /// カーソルのいる側へ帯を移す。
    ///
    /// 右半分にいるなら右端、左半分なら左端。手のある側に出ているほうが近い。
    /// 画面をまたいだときも、移った先の画面でその判断をやり直す。
    private func startPointerFollow() {
        pointerFollowTask?.cancel()
        pointerFollowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pointerFollowInterval)
                guard !Task.isCancelled, let self else { return }
                self.followPointer()
            }
        }
    }

    private func followPointer() {
        guard isVisible, preferences.edgeTabsFollowsPointer else { return }
        // 掴んでいる最中と、一覧を開いている最中は動かさない。狙っているものが
        // 反対側へ飛ぶ。
        guard NSEvent.pressedMouseButtons == 0,
              !isDraggingFromPopover,
              !isListPresented else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let id = screen.displayID,
              let strip = strips[id] else { return }
        // 帯が付くのは画面の縁だけ。FinderAIの窓の縁へ寄せる案もあったが、
        // 入れなかった——窓の一部に見えるものが窓とは別の層に浮くことになり、
        // 窓を背面に回しても帯だけが他アプリの上に残る。子ウインドウにして
        // 前後を揃える手も試したが、隠れ方が読みにくくなるだけだった。
        //
        // 隣と接している縁へも寄せる。継ぎ目は通り道でもあるが、避けると
        // 画面の内側半分から帯が遠のく——3440ptの画面ではそれが致命的で、
        // 左に手があるのに右端まで往復することになっていた。継ぎ目で2本が
        // 重なる件は、動かしたあとに`resolveSeamConflicts`が解く。
        //
        // カーソルのいる側へ素直に移る。ただし中央をまたぐ瞬間に往復しない
        // よう、移った先から戻るには中央より少し先まで行く必要がある
        // （行きと帰りで境目をずらす）。
        let hysteresis = screen.frame.width * 0.06
        let boundary = strip.edge == .right
            ? screen.frame.midX - hysteresis
            : screen.frame.midX + hysteresis
        let wanted: WorkspaceScreenEdge = mouse.x >= boundary ? .right : .left

        guard strip.edge != wanted else { return }
        strip.edge = wanted
        // 角の落とし方が左右で変わるので、移ったらタブごと作り直す。
        buildTabs(in: strip, on: screen)
        layout(strip, on: screen)
        // 移った先が継ぎ目なら、向かいの画面の帯を退ける。カーソルのいる画面が優先。
        resolveSeamConflicts(preferring: id)
        refreshSessionBadges()
        refreshWindowsOverview()
    }

    /// 継ぎ目に2本が重ならないよう、あとから来たほうを反対の縁へ退ける。
    ///
    /// 縁が継ぎ目でも帯は置く。置かないほうが行儀はいいが、隣を並べた側の縁が
    /// 丸ごと使えなくなるほうが実害が大きい。代わりに、両側の画面が同じ継ぎ目へ
    /// 寄ったときだけ片方を退ける。`preferring`——ふつうはカーソルのいる画面——が
    /// 先に縁を取り、残りは空いている縁があればそちらへ移る。
    ///
    /// どちらの縁も塞がっているなら動かさない。3画面を横一列に並べた真ん中では
    /// 逃げ場が無く、動かしても別の継ぎ目でぶつかるだけになる。
    ///
    /// - Returns: `preferring`以外の画面の帯を動かしたか。
    @discardableResult
    private func resolveSeamConflicts(preferring activeID: CGDirectDisplayID?) -> Bool {
        var screens = NSScreen.screens
        if let activeID, let index = screens.firstIndex(where: { $0.displayID == activeID }) {
            screens.insert(screens.remove(at: index), at: 0)
        }
        var settled: [(frame: CGRect, edge: WorkspaceScreenEdge)] = []
        var movedOthers = false
        for screen in screens {
            guard let id = screen.displayID, let strip = strips[id] else { continue }
            func collides(_ candidate: WorkspaceScreenEdge) -> Bool {
                settled.contains {
                    EdgeTabPlacement.sharesSeam(
                        screen.frame,
                        edge: candidate,
                        with: $0.frame,
                        edge: $0.edge
                    )
                }
            }
            var wanted = strip.edge
            if collides(wanted), !collides(wanted.opposite) {
                wanted = wanted.opposite
            }
            settled.append((screen.frame, wanted))
            guard wanted != strip.edge else { continue }
            strip.edge = wanted
            // 角の落とし方が左右で変わるので、タブごと作り直す。
            buildTabs(in: strip, on: screen)
            layout(strip, on: screen)
            if id != activeID { movedOthers = true }
        }
        return movedOthers
    }

    private func buildTabs(in strip: Strip, on screen: NSScreen) {
        strip.tabs.forEach { $0.removeFromSuperview() }
        strip.tabs = []
        // 板そのものを受け口にする。タブ1枚ずつを狙わせない。
        strip.container.onHoverChanged = { [weak self, weak strip] isInside in
            guard let self, let strip else { return }
            let screenID = screen.displayID
            if isInside {
                self.cancelClose()
                if let screenID { self.stripHoverChanged(true, on: screenID) }
                if self.preferences.edgeTabsOpensOnHover { self.scheduleOpenNearest(in: strip) }
            } else {
                // 板の上に載っているタブへ移っただけでも「外れた」が飛ぶ。通知を
                // そのまま信じると、触れた直後に自分で取り消してリストが開かない。
                guard !self.cursorIsOverPanels else { return }
                self.cancelOpen()
                self.scheduleClose()
                if let screenID { self.stripHoverChanged(false, on: screenID) }
            }
        }
        strip.windowsTab?.removeFromSuperview()
        let windowsTab = EdgeWindowsTabButton(edge: strip.edge)
        windowsTab.onPress = { [weak self, weak strip] in
            guard let self, let strip else { return }
            self.cancelOpen()
            self.cancelClose()
            if self.windowsList.isPresented {
                self.hidePopover()
            } else {
                self.showWindowsList(in: strip)
            }
        }
        windowsTab.onHoverChanged = { [weak self, weak strip] isInside in
            guard let self, let strip else { return }
            if isInside {
                self.cancelClose()
                if let id = screen.displayID { self.stripHoverChanged(true, on: id) }
                // フォルダのタブと同じで、触れれば開く。ここだけ押さないと
                // 開かないのでは、袖の中で振る舞いが割れる。
                if self.preferences.edgeTabsOpensOnHover { self.scheduleShowWindows(in: strip) }
            } else {
                self.cancelOpen()
                self.scheduleClose()
                if let id = screen.displayID { self.stripHoverChanged(false, on: id) }
            }
        }
        strip.container.addSubview(windowsTab)
        strip.windowsTab = windowsTab
        for url in tabs.urls {
            let tab = EdgeTabButton(url: url, edge: strip.edge)
            let screenID = screen.displayID
            tab.onHoverChanged = { [weak self, weak tab] isInside in
                guard let self, let tab else { return }
                if isInside {
                    // 隠れているなら、触れられた時点で出す。取っ手が画面に残って
                    // いるので、これだけで足りる。
                    if let screenID { self.stripHoverChanged(true, on: screenID) }
                    // 一覧まで開くのは、そう選んだときだけ。既定はクリック。
                    if self.preferences.edgeTabsOpensOnHover { self.scheduleOpen(for: tab) }
                    self.cancelClose()
                } else {
                    self.cancelOpen()
                    self.scheduleClose()
                    if let screenID { self.stripHoverChanged(false, on: screenID) }
                }
            }
            tab.onToggle = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.togglePopover(for: tab)
            }
            tab.onOpenInWorkspace = { [weak self] in
                self?.hidePopover()
                self?.onOpenDirectory?(url)
            }
            tab.onShowPathMenu = { [weak self, weak tab] point in
                guard let self, let tab else { return }
                self.showPathMenu(for: tab, at: point)
            }
            tab.contextMenuExtras = { [weak self] in
                self?.presentationMenuItems() ?? []
            }
            tab.onRemove = { [weak self] in self?.toggle(url) }
            tab.onDropFiles = { [weak self] sources, copy in
                self?.transfer(sources, to: url, copy: copy) ?? false
            }
            tab.onRevealTerminal = { [weak self] in
                self?.hidePopover()
                self?.onRevealTerminal?(url)
            }
            strip.container.addSubview(tab)
            strip.tabs.append(tab)
        }

        // 足すための的は常に袖に置く。
        //
        // 空のときだけ出していたが、それでは1つ入れた時点で消えてしまい、2つ目を
        // 足す道が`⌃⌘E`しか無くなる——袖にフォルダが1つきりで止まるのはこれが
        // 理由だった。上限まで埋まったときだけ引っ込める。
        strip.addTab?.removeFromSuperview()
        strip.addTab = nil
        guard !tabs.isFull else { return }
        let add = EdgeActionTabButton(
            symbol: "plus",
            tooltip: "いま見ているフォルダを袖に入れる（⌃⌘E）",
            edge: strip.edge
        )
        add.onPress = { [weak self] in self?.onAddCurrentFolder?() }
        add.onHoverChanged = { [weak self] isInside in
            guard let self, let id = screen.displayID else { return }
            if isInside {
                self.cancelClose()
                self.stripHoverChanged(true, on: id)
            } else {
                self.scheduleClose()
                self.stripHoverChanged(false, on: id)
            }
        }
        strip.container.addSubview(add)
        strip.addTab = add
    }

    private func layout(_ strip: Strip, on screen: NSScreen) {
        guard let resting = EdgeTabPlacement.stripFrame(
            tabCount: strip.tabs.count + 1 + (strip.addTab == nil ? 0 : 1),
            edge: strip.edge,
            visibleFrame: screen.visibleFrame
        ) else {
            strip.panel.orderOut(nil)
            return
        }
        strip.panel.setFrame(
            strip.isHidden
                ? EdgeTabPlacement.hiddenStripFrame(visible: resting, edge: strip.edge)
                : resting,
            display: true
        )
        layoutTabs(in: strip, within: resting)
        strip.panel.orderFrontRegardless()
    }

    private func layoutTabs(in strip: Strip, within resting: CGRect) {
        var y = resting.height
        if let windowsTab = strip.windowsTab {
            y -= EdgeTabPlacement.tabHeight
            windowsTab.frame = NSRect(
                x: 0,
                y: y,
                width: EdgeTabPlacement.tabWidth,
                height: EdgeTabPlacement.tabHeight
            )
            y -= EdgeTabPlacement.tabSpacing
        }
        for tab in strip.tabs {
            y -= EdgeTabPlacement.tabHeight
            tab.frame = NSRect(
                x: 0,
                y: y,
                width: EdgeTabPlacement.tabWidth,
                height: EdgeTabPlacement.tabHeight
            )
            y -= EdgeTabPlacement.tabSpacing
        }
        if let addTab = strip.addTab {
            y -= EdgeTabPlacement.tabHeight
            addTab.frame = NSRect(
                x: 0,
                y: y,
                width: EdgeTabPlacement.tabWidth,
                height: EdgeTabPlacement.tabHeight
            )
        }
    }

    /// ウインドウの配置を描き直す。増減や移動のたびに呼ばれる。
    func refreshWindowsOverview() {
        guard let layout = windowsLayoutProvider?() else { return }
        for strip in strips.values {
            strip.windowsTab?.layout = layout
        }
    }

    /// タブごとに「そのフォルダで何か走っているか」を塗り直す。
    private func refreshSessionBadges() {
        guard let sessionManager else { return }
        for strip in strips.values {
            for tab in strip.tabs {
                tab.isRunningSession = sessionManager
                    .sessions(for: tab.url)
                    .contains(where: \.isRunning)
            }
        }
    }

    // MARK: - 出し入れ


    /// 帯に触れた／離れた。取っ手が画面に残っているので、ふつうのトラッキングで足りる。
    private func stripHoverChanged(_ isInside: Bool, on screenID: CGDirectDisplayID) {
        guard autoHide else { return }
        if isInside {
            guard let (strip, screen) = stripAndScreen(for: screenID) else { return }
            slide(strip, on: screen, hidden: false)
        } else {
            scheduleHideStrips()
        }
    }

    private func stripAndScreen(for id: CGDirectDisplayID) -> (Strip, NSScreen)? {
        guard let strip = strips[id],
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return nil }
        return (strip, screen)
    }

    /// 離れてしばらくしたら引っ込める。掴んでいる最中と、一覧を覗いている最中は待つ。
    private func scheduleHideStrips() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled, let self, self.autoHide else { return }
            guard NSEvent.pressedMouseButtons == 0, !self.isDraggingFromPopover else {
                self.scheduleHideStrips()
                return
            }
            guard !self.cursorIsOverPanels, !self.isListPresented else { return }
            self.hideStripsIfAutoHiding()
        }
    }

    private func slide(_ strip: Strip, on screen: NSScreen, hidden: Bool) {
        guard hidden != strip.isHidden,
              let resting = EdgeTabPlacement.stripFrame(
                  tabCount: strip.tabs.count + 1,
                  edge: strip.edge,
                  visibleFrame: screen.visibleFrame
              ) else { return }
        strip.isHidden = hidden
        // 出す位置が変わるので、タブも新しい枠に合わせて置き直す。
        layoutTabs(in: strip, within: resting)
        let target = hidden
            ? EdgeTabPlacement.hiddenStripFrame(visible: resting, edge: strip.edge)
            : resting
        strip.panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strip.panel.animator().setFrame(target, display: true)
        }
    }

    private func revealAllStrips() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let strip = strips[id] else { continue }
            slide(strip, on: screen, hidden: false)
        }
    }

    private func hideStripsIfAutoHiding() {
        guard autoHide else { return }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let strip = strips[id] else { continue }
            slide(strip, on: screen, hidden: true)
        }
    }

    // MARK: - 一覧の開閉

    private func scheduleOpen(for tab: EdgeTabButton) {
        cancelClose()
        openTask?.cancel()
        openTask = Task { [weak self, weak tab] in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, let self, let tab else { return }
            self.showPopover(for: tab)
        }
    }

    /// 袖に触れたら、カーソルのいる高さに最も近いフォルダを開く。
    ///
    /// どのタブに当たったかを問わないので、端へ寄せるだけでリストが広がる。
    /// 俯瞰のタブに乗っているあいだだけは、そちらの受け持ちに譲る。
    private func scheduleOpenNearest(in strip: Strip) {
        let mouse = NSEvent.mouseLocation
        if let windowsTab = strip.windowsTab,
           strip.panel.convertToScreen(windowsTab.frame).contains(mouse) {
            return
        }
        guard let nearest = strip.tabs.min(by: { lhs, rhs in
            let left = strip.panel.convertToScreen(lhs.frame).midY
            let right = strip.panel.convertToScreen(rhs.frame).midY
            return abs(left - mouse.y) < abs(right - mouse.y)
        }) else { return }
        scheduleOpen(for: nearest)
    }

    /// 俯瞰に触れてしばらくしたら、ウインドウの一覧を出す。
    private func scheduleShowWindows(in strip: Strip) {
        cancelClose()
        openTask?.cancel()
        openTask = Task { [weak self, weak strip] in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, let self, let strip else { return }
            self.showWindowsList(in: strip)
        }
    }

    /// フォルダの一覧と同じ場所へ、開いているウインドウを縦に並べて出す。
    ///
    /// 以前は別ウインドウの一覧を立てていた。フォルダは袖から広がるのにウインドウ
    /// だけ別のウインドウが出るのでは袖の中で振る舞いが割れるうえ、一覧そのものが
    /// 「開いているウインドウ」を1枚増やしてしまう。
    private func showWindowsList(in strip: Strip) {
        guard let windowsTab = strip.windowsTab,
              let screen = strip.panel.screen ?? NSScreen.main else { return }
        // フォルダの一覧とは同時に出さない。同じ場所へ重なる。
        popover.dismiss()
        accordion.dismiss()
        windowsList.present(
            rows: windowRowsProvider?() ?? [],
            anchor: strip.panel.convertToScreen(windowsTab.frame),
            edge: strip.edge,
            visibleFrame: screen.visibleFrame,
            screenID: screen.displayID,
            relativeTo: strip.panel
        )
    }

    private func cancelOpen() {
        openTask?.cancel()
        openTask = nil
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled, let self else { return }
            // 何かを掴んでいるあいだは閉じない。掴んだまま置き場所が消えると、
            // タブへ運ぶ途中で一覧も帯も無くなる。
            guard NSEvent.pressedMouseButtons == 0, !self.isDraggingFromPopover else {
                self.scheduleClose()
                return
            }
            // 実際にカーソルがどこにあるかで決める。出入りの通知だけを信じると、
            // 一覧が開いた瞬間——カーソルはまだタブの上、つまり一覧の外——に
            // 「外へ出た」が飛んできて、開いた直後に自分で閉じる。
            guard !self.cursorIsOverPanels else { return }
            self.hidePopover()
            self.hideStripsIfAutoHiding()
        }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    private var cursorIsOverPanels: Bool {
        let mouse = NSEvent.mouseLocation
        for strip in strips.values where strip.panel.isVisible {
            if strip.panel.frame.contains(mouse) { return true }
        }
        if popover.isPresented, popover.frame.contains(mouse) { return true }
        if accordion.isPresented, accordion.frame.contains(mouse) { return true }
        if windowsList.isPresented, windowsList.frame.contains(mouse) { return true }
        return false
    }

    /// クリックでの開閉。同じタブをもう一度押したら閉じる。
    private func togglePopover(for tab: EdgeTabButton) {
        cancelOpen()
        cancelClose()
        let openedRoot = accordion.isPresented ? accordion.presentedRoot : popover.presentedRoot
        if isListPresented, openedRoot == tab.url {
            hidePopover()
            return
        }
        showPopover(for: tab)
    }

    private func showPopover(for tab: EdgeTabButton) {
        guard let panel = tab.window as? EdgeTabPanel,
              let screen = panel.screen ?? NSScreen.main else { return }
        let anchor = panel.convertToScreen(tab.frame)
        let tabEdge = strips.values.first { $0.tabs.contains(tab) }?.edge ?? edge
        // ウインドウの一覧とは同じ場所へ出る。片方を開くならもう片方は畳む。
        windowsList.dismiss()
        if preferences.edgeTabsUsesAccordion {
            // すでに同じ画面で開いているなら、開き直さずその中で寄せる。縦積みには
            // 袖の全フォルダが載っているので、目的の見出しはもう画面にある——
            // 出し直すと一度消えて開き直り、読んでいる途中の場所を見失う。
            if accordion.isPresented, accordion.presentedScreenID == screen.displayID {
                accordion.moveFocus(to: tab.url)
                return
            }
            // 袖に入れた全フォルダを縦積みで出す。押されたものはその場で開く。
            accordion.present(
                roots: tabs.urls,
                focus: tab.url,
                anchor: anchor,
                edge: tabEdge,
                visibleFrame: screen.visibleFrame,
                screenID: screen.displayID,
                relativeTo: panel
            )
            return
        }
        popover.present(
            directory: tab.url,
            anchor: anchor,
            edge: tabEdge,
            visibleFrame: screen.visibleFrame,
            screenID: screen.displayID,
            relativeTo: panel
        )
    }

    private func hidePopover() {
        cancelOpen()
        cancelClose()
        popover.dismiss()
        accordion.dismiss()
        windowsList.dismiss()
    }

    /// 袖から広げたウインドウの一覧が出ているなら、その位置と縁。
    ///
    /// 覗いた中身の縮小を、一覧に重ならない側へ置くために使う。
    var presentedWindowsList: (frame: CGRect, edge: WorkspaceScreenEdge)? {
        guard windowsList.isPresented else { return nil }
        return (windowsList.frame, windowsList.edge)
    }

    /// いま一覧が開いているか（どちらの形でも）。
    private var isListPresented: Bool {
        popover.isPresented || accordion.isPresented || windowsList.isPresented
    }

    // MARK: - タブのメニュー

    /// ⌘クリック。Finderのタイトルバーと同じで、上の階層が並ぶ。
    private func showPathMenu(for tab: EdgeTabButton, at point: NSPoint) {
        let menu = NSMenu(title: tab.url.lastPathComponent)
        var url = tab.url.standardizedFileURL
        var ancestors: [URL] = [url]
        while url.path != "/" {
            let parent = url.deletingLastPathComponent().standardizedFileURL
            guard parent != url else { break }
            ancestors.append(parent)
            url = parent
        }
        for ancestor in ancestors {
            let item = NSMenuItem(
                title: ancestor.path == "/" ? "Macintosh HD" : ancestor.lastPathComponent,
                action: #selector(openAncestor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ancestor
            item.image = {
                let icon = NSWorkspace.shared.icon(forFile: ancestor.path)
                icon.size = NSSize(width: 16, height: 16)
                return icon
            }()
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: tab)
    }

    @objc private func openAncestor(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        hidePopover()
        onOpenDirectory?(url)
    }

    /// 表示形式と並び順。タブの右クリック（⌃クリック）から出る。
    private func presentationMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let asIcons = preferences.edgeTabsUsesIconView
        for (title, wantsIcons) in [("リストで表示", false), ("アイコンで表示", true)] {
            let item = NSMenuItem(title: title, action: #selector(changeViewMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = wantsIcons
            item.state = asIcons == wantsIcons ? .on : .off
            items.append(item)
        }
        items.append(.separator())
        for sort in WorkspaceEdgeTabSort.allCases {
            let item = NSMenuItem(
                title: "\(sort.title)で並べる",
                action: #selector(changeSort(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = sort.rawValue
            item.state = preferences.edgeTabsSort == sort ? .on : .off
            items.append(item)
        }
        let direction = NSMenuItem(
            title: preferences.edgeTabsSortAscending ? "降順にする" : "昇順にする",
            action: #selector(toggleSortDirection),
            keyEquivalent: ""
        )
        direction.target = self
        items.append(direction)
        return items
    }

    @objc private func changeViewMode(_ sender: NSMenuItem) {
        guard let wantsIcons = sender.representedObject as? Bool else { return }
        preferences.edgeTabsUsesIconView = wantsIcons
        popover.applyPresentationSettings()
    }

    @objc private func changeSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let sort = WorkspaceEdgeTabSort(rawValue: raw) else { return }
        preferences.edgeTabsSort = sort
        popover.applyPresentationSettings()
    }

    @objc private func toggleSortDirection() {
        preferences.edgeTabsSortAscending.toggle()
        popover.applyPresentationSettings()
    }

    /// タブへ直接落とされたファイルを受け取る。規則（移動／Optionコピー、同名の
    /// 拒否、自分自身への移動の禁止）はブラウザ本体と同じ`WorkspaceFileService`。
    private func transfer(_ sources: [URL], to destination: URL, copy: Bool) -> Bool {
        do {
            _ = try WorkspaceFileService().transfer(sources, to: destination, copy: copy)
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = copy ? "コピーできません" : "移動できません"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }
}

extension NSScreen {
    /// モニタの同一性は`NSScreen`の参照ではなくディスプレイIDで見る。
    /// `NSScreen.screens`が返すオブジェクトは作り直されることがあり、参照比較は
    /// 当てにならない。
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// 常駐する側のパネル。
///
/// `.nonactivatingPanel`で、`canJoinAllSpaces`＋`fullScreenAuxiliary`。Spaceを
/// またいでも、他アプリがフルスクリーンでも同じ縁に居続ける。
@MainActor
final class EdgeTabPanel: NSPanel {
    private let acceptsKey: Bool

    /// 矢印・return・escをコントローラへ回す。trueを返したら消費済み。
    var onKeyDown: ((NSEvent) -> Bool)?

    init(acceptsKey: Bool = false) {
        self.acceptsKey = acceptsKey
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: EdgeTabPlacement.tabWidth, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    /// クリックしてもFinderAIを前面に持ち上げない。縁のタブは「今使っているアプリ
    /// の上で、ちょっと開いて閉じる」ものなので、前面化はむしろ邪魔。
    ///
    /// 一覧のほうはキーになれる（矢印キーで選びたい）。`.nonactivatingPanel`なので
    /// キーになってもアプリ自体は前面に出ない。
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        guard onKeyDown?(event) != true else { return }
        super.keyDown(with: event)
    }
}
