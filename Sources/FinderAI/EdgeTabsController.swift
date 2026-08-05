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

    private let preferences: WorkspacePreferences
    /// 縁のタブに実行中の印を出すためだけに見る。セッションを触りはしない。
    private let sessionManager: (any TerminalSessionManaging)?
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?

    /// 1枚のモニタに出ている帯。
    @MainActor
    private final class Strip {
        let panel: EdgeTabPanel
        let container = NSView()
        var tabs: [EdgeTabButton] = []
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
    private static let openDelay = Duration.milliseconds(300)
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

    var isVisible: Bool { isEnabled && !tabs.isEmpty }
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

        // 出しっぱなしなら、どのモニタにも置く。作業している画面に無いのでは
        // 「常に手の届く場所」にならない。
        var hosts = NSScreen.screens
        if autoHide {
            // 隠すときだけ、隣に別のモニタが接している縁を避ける。そこは画面の端
            // ではなくカーソルが行き来する通路で、隠れた帯を置くと隣の画面へ移る
            // たびに触れて出入りし、掴もうとすると逃げる。出したままなら起きない。
            let outer = hosts.filter { Self.isOuterEdge($0, edge: edge) }
            // どの画面も内側を向く置き方（縦に積む、など）では、それでも1本は要る。
            hosts = outer.isEmpty
                ? [NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                    ?? NSScreen.main].compactMap { $0 }
                : outer
        }

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
            if !preferences.edgeTabsFollowsPointer { strip.edge = edge }
            buildTabs(in: strip, on: screen)
            layout(strip, on: screen)
        }
        for (id, strip) in strips where !live.contains(id) {
            strip.panel.orderOut(nil)
            strips.removeValue(forKey: id)
        }
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
              !popover.isPresented else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let id = screen.displayID,
              let strip = strips[id] else { return }
        // 画面の真ん中で往復しないよう、中央には触らない帯を設ける。
        let deadZone = screen.frame.width * 0.08
        let wanted: WorkspaceScreenEdge
        if mouse.x > screen.frame.midX + deadZone {
            wanted = .right
        } else if mouse.x < screen.frame.midX - deadZone {
            wanted = .left
        } else {
            return
        }
        guard strip.edge != wanted else { return }
        strip.edge = wanted
        // 角の落とし方が左右で変わるので、タブごと作り直す。
        buildTabs(in: strip, on: screen)
        layout(strip, on: screen)
        refreshSessionBadges()
    }

    /// その縁が外を向いているか（隣に別のモニタが接していないか）。
    ///
    /// 縁に沿って何点か当たりを取る。境界が縦にずれて重なっている置き方——
    /// 大きいモニタの右に小さいモニタを高さ違いで並べる、など——では、中央だけを
    /// 見ると「接していない」と読み違える。
    static func isOuterEdge(_ screen: NSScreen, edge: WorkspaceScreenEdge) -> Bool {
        let frame = screen.frame
        let others = NSScreen.screens.filter { $0.frame != frame }
        guard !others.isEmpty else { return true }
        let x = edge == .right ? frame.maxX + 1 : frame.minX - 1
        let samples = [0.15, 0.35, 0.5, 0.65, 0.85].map { ratio in
            CGPoint(x: x, y: frame.minY + frame.height * ratio)
        }
        return !samples.contains { point in
            others.contains { $0.frame.contains(point) }
        }
    }

    private func buildTabs(in strip: Strip, on screen: NSScreen) {
        strip.tabs.forEach { $0.removeFromSuperview() }
        strip.tabs = []
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
    }

    private func layout(_ strip: Strip, on screen: NSScreen) {
        guard let resting = EdgeTabPlacement.stripFrame(
            tabCount: strip.tabs.count,
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
            guard !self.cursorIsOverPanels, !self.popover.isPresented else { return }
            self.hideStripsIfAutoHiding()
        }
    }

    private func slide(_ strip: Strip, on screen: NSScreen, hidden: Bool) {
        guard hidden != strip.isHidden,
              let resting = EdgeTabPlacement.stripFrame(
                  tabCount: strip.tabs.count,
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
        return false
    }

    /// クリックでの開閉。同じタブをもう一度押したら閉じる。
    private func togglePopover(for tab: EdgeTabButton) {
        cancelOpen()
        cancelClose()
        if popover.isPresented, popover.presentedRoot == tab.url {
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
