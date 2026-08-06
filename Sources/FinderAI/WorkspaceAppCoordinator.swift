import AppKit
import FinderAICore

@MainActor
final class WorkspaceAppCoordinator {
    private let sessionManager: any TerminalSessionManaging = TerminalSessionManager(
        registry: SessionRegistryStore()
    )
    private let preferences = WorkspacePreferences()
    private let restorationStore = WorkspaceRestorationStore()
    private let updater = WorkspaceUpdater()
    private var windows: [WorkspaceWindowController] = []
    private var lastCapturedSnapshot: WorkspaceRestorationSnapshot?
    private var sessionsPanel: TerminalSessionsPanelController?
    private var windowsPanel: WorkspaceWindowsPanelController?
    private var settingsWindow: SettingsWindowController?
    /// 画面の縁のタブ。ウインドウに属さないので、セッション同様アプリ全体で1つ。
    private lazy var edgeTabs: EdgeTabsController = {
        let controller = EdgeTabsController(
            preferences: preferences,
            sessionManager: sessionManager
        )
        controller.onOpenDirectory = { [weak self] url in
            self?.revealDirectory(url)
        }
        controller.onShowWindows = { [weak self] in
            self?.showWindowsPanel()
        }
        controller.onAddCurrentFolder = { [weak self] in
            self?.toggleEdgeTabForCurrentFolder()
        }
        controller.windowRowsProvider = { [weak self] in self?.windowRows() ?? [] }
        controller.onSelectWindow = { [weak self] id in
            // 押したら確定。覚えた重なりは捨てる。
            self?.previewRestoreOrder = []
            self?.windows.first { ObjectIdentifier($0) == id }?.show()
        }
        controller.onCloseWindow = { [weak self] id in
            self?.windows.first { ObjectIdentifier($0) == id }?.window?.performClose(nil)
        }
        controller.onPreviewWindow = { [weak self] id in self?.previewWindow(id) }
        controller.onBeginPreviewWindows = { [weak self] in self?.beginWindowPreview() }
        controller.onEndPreviewWindows = { [weak self] in self?.endWindowPreview() }
        controller.windowsLayoutProvider = { [weak self] in
            guard let self else { return .init(screens: [], windows: [], frontmost: nil) }
            let front = self.lastKeyWorkspaceWindow
            return .init(
                screens: NSScreen.screens.map(\.frame),
                windows: self.windows.compactMap { $0.window?.frame },
                frontmost: self.windows.first { $0.window === front }?.window?.frame
            )
        }
        controller.onRevealTerminal = { [weak self] url in
            guard let self else { return }
            let target = self.frontmostWindow ?? self.windows.first ?? self.workspace
            target.browser.navigate(to: url)
            target.showTerminal()
            target.show()
        }
        return controller
    }()
    // Read back only in `deinit`, which cannot hop to the main actor.
    private nonisolated(unsafe) var sessionsObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?
    private var restartRequired = false
    /// 終了処理に入ったか。入ったら構成のスナップショットを凍結する。
    private var isTerminating = false
    /// ウインドウに振る通し番号。閉じても詰め直さない。
    private var nextWindowSerial = 1
    /// 最後にkeyだったワークスペースのウインドウ。
    ///
    /// 前面の判定に`NSApp.keyWindow`をそのまま使うと、一覧パネル自身がkeyに
    /// なった瞬間、どの行も「前面ではない」ことになる。
    private weak var lastKeyWorkspaceWindow: NSWindow?
    /// 一覧を開いた時点の重なり（前面から順）。畳んだらこの順へ並べ直す。
    private var previewRestoreOrder: [NSWindow] = []


    /// Terminal sessions are keyed by folder and kind across the whole app, so two
    /// windows on the same folder share one shell rather than racing to spawn a
    /// second. That makes the manager app-wide, not per-window.
    /// 実際に何十枚と開いて使われる。20で止めていたが、それは足りない数だった。
    /// 上限が要るのは暴走を防ぐためだけなので、実用の範囲より十分上に置く。
    static let windowLimit = 64

    private var workspace: WorkspaceWindowController {
        windows.first ?? makeWindow(directory: Self.defaultDirectory())
    }

    func start() {
        // beginRun()がフラグをdirtyへ倒す前に、前回の終わり方と構成を読み取る。
        // この順を崩すと自分の起動をクラッシュと誤認する。
        let endedCleanly = restorationStore.previousRunEndedCleanly
        let snapshot = restorationStore.snapshot
        let crashSnapshot = endedCleanly ? nil : snapshot
        // 正常に終了したときも、開いていたウインドウはそのまま開き直す。
        //
        // 復元をクラッシュ時だけにしていたので、ふつうに終了して起動し直すたびに
        // 何枚も開いていたウインドウが1枚に戻っていた。何十枚も開いて使う道具で、
        // それは「閉じた覚えのないものが消える」に等しい。クラッシュのときだけは
        // 従来どおり、セッションを含めて復元するか訊く。
        let resumeSnapshot = endedCleanly ? snapshot : nil
        restorationStore.beginRun()

        configureMainMenu()
        _ = makeWindow(directory: Self.defaultDirectory())
        windows.first?.show()
        edgeTabs.reload()
        restoreLastDirectory()
        refreshInstallationIndicator()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // ワークスペースのウインドウだけを覚える。一覧パネルや設定が
                // keyになった瞬間に「どれも前面ではない」ことにしないため。
                guard let key = NSApp.keyWindow,
                      self.windows.contains(where: { $0.window === key }) else { return }
                self.lastKeyWorkspaceWindow = key
                self.windowsPanel?.refreshIfVisible()
                self.edgeTabs.refreshWindowsOverview()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInstallationIndicator() }
        }
        // モニタの並びが変わると、前の座標に居たウインドウは誰の画面でもない場所に
        // 取り残される。開いているのに見えない状態なので、その都度引き戻す。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows.forEach { $0.rescueOffscreenWindow() } }
        }

        sessionsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionsDidChange,
            object: sessionManager,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureSnapshot() }
        }
        captureSnapshot()

        Task.detached(priority: .utility) {
            SessionLogStore.pruneLogs()
        }

        if let crashSnapshot, crashSnapshot.isWorthRestoring {
            // ウインドウが画面に出てからシートを掛ける。
            Task { [weak self] in
                self?.offerRestore(of: crashSnapshot)
            }
        } else if let resumeSnapshot,
                  preferences.restoresWindows,
                  resumeSnapshot.windowDirectoryPaths.count > 1 {
            // 前回と同じ並びで開き直す。1枚だけだった回は、最後に見ていた
            // フォルダの復元（`restoreLastDirectory`）が同じ仕事をする。
            restoreWindowsOnly(from: resumeSnapshot)
        }
    }

    deinit {
        if let sessionsObserver {
            NotificationCenter.default.removeObserver(sessionsObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    @discardableResult
    private func makeWindow(directory: URL) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            sessionManager: sessionManager,
            initialDirectory: directory,
            preferences: preferences,
            // Only the first window restores the saved frame; the rest cascade off
            // it, or they would all stack on the same rectangle.
            restoresFrame: windows.isEmpty,
            serial: nextWindowSerial
        )
        nextWindowSerial += 1
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
            self.captureSnapshot()
            self.windowsPanel?.refreshIfVisible()
            self.edgeTabs.refreshWindowsOverview()
        }
        controller.onDirectoryChanged = { [weak self] in
            self?.captureSnapshot()
            self?.refreshWindowTitles()
            self?.windowsPanel?.refreshIfVisible()
        }
        controller.onManageTerminalSessions = { [weak self] in
            self?.showTerminalSessionsPanel()
        }
        windows.append(controller)
        applyInstallationIndicator(to: controller)
        captureSnapshot()
        refreshWindowTitles()
        windowsPanel?.refreshIfVisible()
        edgeTabs.refreshWindowsOverview()
        return controller
    }

    /// 同名フォルダのウインドウが複数あるときだけ、親フォルダ名を副題に添える。
    ///
    /// 「logs」を3枚開くとタイトルが全部同じになり、ウインドウメニューでもDockでも
    /// 選べない。常に親を出すと今度は冗長なので、重なったときだけにする。
    private func refreshWindowTitles() {
        var counts: [String: Int] = [:]
        for controller in windows {
            counts[controller.displayedDirectory.lastPathComponent, default: 0] += 1
        }
        for controller in windows {
            let directory = controller.displayedDirectory
            let name = directory.lastPathComponent
            let title = name.isEmpty ? directory.path : name
            let parent = directory.deletingLastPathComponent().lastPathComponent
            let ambiguous = (counts[name] ?? 0) > 1 && !parent.isEmpty
            controller.applyDisplayTitle(title, subtitle: ambiguous ? parent : "FinderAI")
        }
    }

    /// すでにそのフォルダを見ているウインドウ。あるなら新しく開かずそれを使う。
    private func window(showing url: URL) -> WorkspaceWindowController? {
        let target = url.standardizedFileURL
        return windows.first { $0.displayedDirectory.standardizedFileURL == target }
    }

    /// そのフォルダを前に出す。
    ///
    /// 探す順は「FinderAIのウインドウ → Finderのウインドウ → FinderAIの手前の
    /// ウインドウで移動」。すでに開いているものがあるなら、それを前に出すのが
    /// いちばん速く、窓も増えない。Finderを何枚も開いて使う人にとっては、その
    /// 中の1枚が本命の窓であることも多い。
    private func revealDirectory(_ url: URL) {
        if let existing = window(showing: url) {
            existing.show()
            return
        }
        if preferences.edgeTabsUsesFinderWindows, FinderWindowLocator.reveal(url) {
            return
        }
        let target = frontmostWindow ?? windows.first ?? workspace
        target.show()
        target.browser.navigate(to: url)
    }

    /// Updating the bundle does not update a running process. Keep that state
    /// visible in every window and in the Dock so a newly installed interaction
    /// is never mistaken for one that is already active.
    private func refreshInstallationIndicator() {
        restartRequired = WorkspaceBuildInfo.current.installationState == .restartRequired
        NSApp.dockTile.badgeLabel = restartRequired ? "更新" : nil
        windows.forEach(applyInstallationIndicator)
    }

    private func applyInstallationIndicator(to controller: WorkspaceWindowController) {
        controller.window?.subtitle = restartRequired ? "新版あり — 再起動で適用" : ""
    }

    // MARK: - Crash restoration

    /// 落ちる直前の構成を常に持っておく。書き込みはUserDefaultsへの小さなJSONで、
    /// 内容が変わったときだけ行う。
    private func captureSnapshot() {
        // 終了が始まったら、そこで見えていた構成のまま止める。
        //
        // 終了時はAppKitがウインドウを1枚ずつ閉じ、そのたびに`windowWillClose`が
        // ここを呼ぶ。最後には「0枚」で上書きされ、次の起動で戻すものが無くなる。
        // クラッシュではこの経路を通らないので、これまで表に出ていなかった。
        guard !isTerminating else { return }
        let snapshot = WorkspaceRestorationSnapshot(
            windowDirectoryPaths: windows.compactMap { controller in
                guard controller.window != nil else { return nil }
                return controller.browser.currentDirectory.path
            },
            sessions: sessionManager.allSessions
                .filter(\.isRunning)
                .map { .init(directoryPath: $0.directoryURL.path, kind: $0.kind) }
        )
        guard snapshot != lastCapturedSnapshot else { return }
        lastCapturedSnapshot = snapshot
        restorationStore.snapshot = snapshot
    }

    private func offerRestore(of snapshot: WorkspaceRestorationSnapshot) {
        let alert = NSAlert()
        alert.messageText = "前回、FinderAIは正常に終了しませんでした"
        var lines = [
            "前回の構成（ウインドウ\(snapshot.windowDirectoryPaths.count)枚・Terminalセッション\(snapshot.sessions.count)件）を復元しますか？"
        ]
        if !snapshot.sessions.isEmpty {
            lines.append(sessionManager.persistenceEnabled
                ? "tmuxに残っている永続セッションへは再接続します。"
                : "Terminalは同じフォルダで新しく開始します（実行中だった内容は戻りません）。")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "復元する")
        alert.addButton(withTitle: "復元しない")

        guard let window = windows.first?.window, window.isVisible else {
            if alert.runModal() == .alertFirstButtonReturn { performRestore(snapshot) }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performRestore(snapshot)
        }
    }

    /// ウインドウの並びだけを開き直す。セッションには触らない。
    ///
    /// 正常終了からの再開はこちら。プロセスは自分で畳んだのだから、勝手に起こす
    /// のは行きすぎ——閉じた覚えのないウインドウだけを戻す。
    private func restoreWindowsOnly(from snapshot: WorkspaceRestorationSnapshot) {
        Task { [weak self] in
            guard let self else { return }
            for (index, path) in snapshot.windowDirectoryPaths.enumerated() {
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                guard await Self.isReachableDirectory(url) else { continue }
                if index == 0 {
                    self.windows.first?.browser.navigate(to: url)
                } else if self.windows.count < Self.windowLimit {
                    if self.cascadePoint == .zero, let front = self.frontmostWindow {
                        self.cascadePoint = front.cascadeOrigin
                    }
                    let controller = self.makeWindow(directory: url)
                    self.cascadePoint = controller.cascade(from: self.cascadePoint)
                    controller.show()
                }
            }
        }
    }

    private func performRestore(_ snapshot: WorkspaceRestorationSnapshot) {
        Task { [weak self] in
            guard let self else { return }
            for (index, path) in snapshot.windowDirectoryPaths.enumerated() {
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                // 消えたフォルダ（外部ボリュームなど）は黙って飛ばす。半端に
                // エラー状態のウインドウを並べても復元にはならない。
                guard await Self.isReachableDirectory(url) else { continue }
                if index == 0 {
                    self.windows.first?.browser.navigate(to: url)
                } else if self.windows.count < Self.windowLimit {
                    if self.cascadePoint == .zero, let front = self.frontmostWindow {
                        self.cascadePoint = front.cascadeOrigin
                    }
                    let controller = self.makeWindow(directory: url)
                    self.cascadePoint = controller.cascade(from: self.cascadePoint)
                    controller.show()
                }
            }
            for entry in snapshot.sessions {
                let url = URL(fileURLWithPath: entry.directoryPath, isDirectory: true)
                    .standardizedFileURL
                guard await Self.isReachableDirectory(url) else { continue }
                // CLIが消えている等の失敗は個別に握る。復元は全部か無かではない。
                _ = try? self.sessionManager.create(kind: entry.kind, directoryURL: url)
            }
            self.captureSnapshot()
        }
    }

    /// `applicationWillTerminate`から。ここに到達した終了だけがクラッシュ扱いを
    /// 免れる。
    func finalizeTermination() {
        restorationStore.markCleanShutdown()
    }

    /// New windows open on the key window's folder, which is nearly always what
    /// "another window of this" means.
    @objc func newWindow() {
        guard windows.count < Self.windowLimit else {
            let alert = NSAlert()
            alert.messageText = "ウインドウは\(Self.windowLimit)個までです"
            alert.informativeText = "使っていないウインドウを閉じてから開いてください。"
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }

        let front = frontmostWindow
        let directory = front?.browser.currentDirectory ?? Self.defaultDirectory()
        // Seed the walk from the window this one came from, then let it run.
        if cascadePoint == .zero, let front {
            cascadePoint = front.cascadeOrigin
        }
        let controller = makeWindow(directory: directory)
        cascadePoint = controller.cascade(from: cascadePoint)
        controller.show()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(
                sessionManager: sessionManager,
                preferences: preferences
            )
            controller.onEdgeTabsChanged = { [weak self] in
                self?.edgeTabs.reload()
            }
            // 設定は全ウインドウに効く。開いているウインドウが古い辺のままだと、
            // 「設定したのに変わらない」ように見える。
            controller.onTerminalEdgeChanged = { [weak self] edge in
                self?.windows.forEach { $0.applyTerminalEdge(edge) }
            }
            settingsWindow = controller
        }
        settingsWindow?.show()
    }

    /// アプリ内の全セッションとtmux残存の俯瞰。tmuxが無くてもアプリ内セッションの
    /// 管理はできるので、ゲートは掛けない。
    @objc func showTerminalSessionsPanel() {
        if sessionsPanel == nil {
            let panel = TerminalSessionsPanelController(sessionManager: sessionManager)
            panel.onOpenFolder = { [weak self] url in
                guard let self else { return }
                let target = self.frontmostWindow ?? self.windows.first
                if let target {
                    target.browser.navigate(to: url)
                    target.show()
                } else {
                    let controller = self.makeWindow(directory: url)
                    controller.show()
                }
            }
            panel.onRevealFolder = { [weak self] url in
                guard let self else { return }
                let target = self.frontmostWindow ?? self.windows.first
                if let target {
                    target.browser.navigate(to: url)
                    target.showTerminal()
                    target.show()
                } else {
                    let controller = self.makeWindow(directory: url)
                    controller.showTerminal()
                    controller.show()
                }
            }
            sessionsPanel = panel
        }
        sessionsPanel?.show()
    }

    /// 開いているウインドウの一覧。何十枚も開くので、ウインドウメニューの並び
    /// だけでは足りない——あちらはタイトルしか出ず、同名フォルダが並ぶと選べない。
    @objc func showWindowsPanel() {
        if windowsPanel == nil {
            let panel = WorkspaceWindowsPanelController()
            panel.rowsProvider = { [weak self] in self?.windowRows() ?? [] }
            panel.onSelect = { [weak self] id in
                // 押したら確定。覚えた重なりは捨てる。
                self?.previewRestoreOrder = []
                self?.windows.first { ObjectIdentifier($0) == id }?.show()
            }
            panel.onClose = { [weak self] id in
                self?.windows.first { ObjectIdentifier($0) == id }?.window?.performClose(nil)
            }
            panel.onOpenNew = { [weak self] in self?.newWindow() }
            panel.onPreview = { [weak self] id in self?.previewWindow(id) }
            panel.onBeginPreview = { [weak self] in self?.beginWindowPreview() }
            panel.onEndPreview = { [weak self] in self?.endWindowPreview() }
            windowsPanel = panel
        }
        windowsPanel?.show()
    }

    /// 一覧のカードに触れているあいだ、そのウインドウを仮に前へ出す。
    ///
    /// カードには名前と置き場所しか書けない。同じフォルダを何枚も開いていると
    /// それでも足りず、結局どれか当てる作業が残る——中身を見せてしまうのが早い。
    /// 「仮に」なので、離れれば元の並びへ戻す。
    private func previewWindow(_ id: ObjectIdentifier) {
        guard let target = windows.first(where: { ObjectIdentifier($0) == id })?.window else { return }
        // `orderFront`は、このアプリが前面にいないと効かない回がある。袖は
        // 非アクティブのまま使うものなので、効いたり効かなかったりした——
        // 実測で、触れても前に出ない行が並びの中に混ざった。
        target.orderFrontRegardless()
        // 独立した一覧は上に残す。前に出した拍子に隠れると、次の行へ移れない。
        // 袖から広げた一覧は`.floating`なので、放っておいても隠れない。
        raiseWindowsPanelIfVisible()
    }

    /// 一覧を開いた。いまの重なりをそっくり覚えておく。
    ///
    /// 覚えるのは開いたときの1回だけ。行ごとに覚えて行ごとに戻す作りにしていた
    /// が、隣へ移る一瞬の「入った」と「離れた」は順序が決まっておらず、片方が
    /// 落ちることさえある——実測でも戻る先が1手ずれた。
    private func beginWindowPreview() {
        previewRestoreOrder = orderedWorkspaceWindows()
    }


    /// 一覧を畳んだ。覚えた重なりへ並べ直す。押して確定した場合は戻さない。
    ///
    /// 前へ出した1枚を背面まで戻す。手元の1枚を前に出すだけだと、覗いた1枚が
    /// 2番目に残る——見ただけのものが並びに残るなら、それは「仮に」ではない。
    private func endWindowPreview() {
        let order = previewRestoreOrder
        previewRestoreOrder = []
        guard order.count > 1 else { return }
        // 前から順に「ひとつ前の下」へ置き直す。背面から`orderFront`で積むと、
        // 他のアプリのウインドウまで全部またいで手前に出てしまう——戻したはず
        // が、覗く前より前に出ている状態になる。直すのは相互の前後だけ。
        for index in 1..<order.count {
            let above = order[index - 1]
            let below = order[index]
            guard above.isVisible, below.isVisible else { continue }
            below.order(.below, relativeTo: above.windowNumber)
        }
        raiseWindowsPanelIfVisible()
    }

    /// いま画面に出ている順（前面から）に、このアプリのウインドウを並べる。
    ///
    /// `NSApp.orderedWindows`の前後関係は、このアプリが前面にいないあいだ
    /// 更新されない。袖は非アクティブのまま使うのでまさにその状況で、実測でも
    /// 実際の重なりと食い違った。並びはウインドウサーバーに訊く。
    private func orderedWorkspaceWindows() -> [NSWindow] {
        guard let info = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var byNumber: [Int: NSWindow] = [:]
        for controller in windows {
            guard let window = controller.window else { continue }
            byNumber[Int(window.windowNumber)] = window
        }
        let result = info.compactMap { entry -> NSWindow? in
            guard let number = entry[kCGWindowNumber as String] as? Int else { return nil }
            return byNumber[number]
        }
        return result
    }

    /// 開いているときだけ前に戻す。閉じている一覧を開いてしまわない。
    private func raiseWindowsPanelIfVisible() {
        guard let panel = windowsPanel?.window, panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    private func windowRows() -> [WorkspaceWindowsPanelController.Row] {
        // 一覧パネルがkeyになっても、直前まで前にいたウインドウを前面として扱う。
        let front = lastKeyWorkspaceWindow ?? NSApp.keyWindow
        return windows.map { controller in
            let directory = controller.displayedDirectory
            let frame = controller.window?.frame ?? .zero
            let screen = controller.window?.screen ?? NSScreen.main
            let baseName = directory.lastPathComponent.isEmpty
                ? directory.path
                : directory.lastPathComponent
            return .init(
                id: ObjectIdentifier(controller),
                serial: controller.serial,
                name: baseName,
                parent: directory.deletingLastPathComponent().path(percentEncoded: false),
                path: directory.path(percentEncoded: false),
                runningSessions: sessionManager.sessions(for: directory)
                    .filter(\.isRunning).count,
                isFrontmost: controller.window === front,
                windowFrame: frame,
                screenFrame: screen?.visibleFrame ?? .zero,
                screenName: Self.screenName(for: screen),
                sizeText: "\(Int(frame.width))×\(Int(frame.height))"
            )
        }
    }

    /// 「主画面」「外部1」のように、どのモニタかを短く言う。
    private static func screenName(for screen: NSScreen?) -> String {
        guard let screen else { return "画面" }
        guard let index = NSScreen.screens.firstIndex(of: screen) else { return "画面" }
        return index == 0 ? "主画面" : "外部\(index)"
    }

    /// いま見ているフォルダを画面の縁に置く／外す。
    @objc func toggleEdgeTabForCurrentFolder() {
        let target = frontmostWindow ?? windows.first
        guard let directory = target?.browser.currentDirectory else { return }
        guard edgeTabs.canAdd(directory) else {
            let alert = NSAlert()
            alert.messageText = "画面端に置けるのは\(WorkspaceEdgeTabs.capacity)個までです"
            alert.informativeText = "どれかのタブを右クリックして「画面端から外す」を選ぶと空きが作れます。"
            alert.addButton(withTitle: "OK")
            if let window = target?.window, window.isVisible {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        edgeTabs.toggle(directory)
    }

    /// 縁のタブをまとめて消す／戻す。登録は消さないので、戻せば同じ並びが出る。
    @objc func toggleEdgeTabsVisibility() {
        edgeTabs.setEnabled(!edgeTabs.isEnabledSetting)
    }

    @objc func toggleEdgeTabsSide() {
        edgeTabs.setEdge(edgeTabs.currentEdge.opposite)
    }

    /// 普段は画面の外へ引っ込め、縁に触れたときだけ滑り出す。
    @objc func toggleEdgeTabsAutoHide() {
        edgeTabs.setAutoHide(!edgeTabs.isAutoHiding)
    }

    private var cascadePoint: NSPoint = .zero

    private var frontmostWindow: WorkspaceWindowController? {
        windows.first { $0.window === NSApp.keyWindow }
            ?? windows.first { $0.window?.isVisible == true }
    }

    /// The window opens on the always-known home URL first, then moves to the
    /// previous folder once it is confirmed to exist.
    ///
    /// The check has to stay off the launch path: `fileExists` on a protected or
    /// File Provider folder blocks, and doing it before the first window is what
    /// made launch take 15 seconds instead of 0.4.
    private func restoreLastDirectory() {
        guard let candidate = preferences.lastDirectory,
              candidate != Self.defaultDirectory() else { return }
        Task { [weak self] in
            guard await Self.isReachableDirectory(candidate) else { return }
            self?.workspace.browser.navigate(to: candidate)
        }
    }

    /// `nonisolated` so the blocking `fileExists` runs off the main actor.
    nonisolated static func isReachableDirectory(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
            return exists && isDirectory.boolValue
        }.value
    }

    /// Clicking the Dock icon with every window closed has to produce a window,
    /// not silently do nothing.
    func showWorkspace() {
        if let existing = frontmostWindow ?? windows.first {
            existing.show()
            return
        }
        let controller = makeWindow(directory: preferences.lastDirectory ?? Self.defaultDirectory())
        controller.show()
    }

    func prepareForTermination() -> NSApplication.TerminateReply {
        // ここから先、ウインドウが閉じられてもスナップショットは動かさない。
        // 終了をやめたときは解く。
        isTerminating = true
        let ephemeralCount = sessionManager.runningEphemeralCount
        let persistentCount = sessionManager.runningCount - ephemeralCount
        // 失われるものが無ければ聞くことも無い。永続セッションのクライアント終了は
        // デタッチで、tmux側の本体は生き残る。
        guard ephemeralCount > 0 else {
            sessionManager.shutdownOwnedProcesses()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "FinderAIを終了しますか？"
        var lines = ["実行中のPTYセッションが\(ephemeralCount)件あります。このアプリが開始したプロセスだけを終了します。"]
        if persistentCount > 0 {
            lines.append("永続セッション\(persistentCount)件はtmuxが保持し、次回起動時に再接続できます。")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "終了")
        alert.addButton(withTitle: "キャンセル")

        // Without a window there is no sheet to attach to, so fall back to a modal
        // rather than deferring a reply that nothing would ever send.
        guard let window = workspace.window, window.isVisible else {
            guard alert.runModal() == .alertFirstButtonReturn else {
                isTerminating = false
                return .terminateCancel
            }
            sessionManager.shutdownOwnedProcesses()
            return .terminateNow
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                self?.isTerminating = false
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            self?.sessionManager.shutdownOwnedProcesses()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configureMainMenu() {
        let main = Self.makeMainMenu(coordinator: self)
        // Populates the window list and keeps the checkmark on the key window.
        NSApp.windowsMenu = main.items.compactMap(\.submenu).first { $0.title == "ウインドウ" }
        NSApp.mainMenu = main
    }

    /// Built without touching app state so the key-equivalent table can be
    /// asserted in tests. `coordinator` is only the target for the two commands
    /// that own the window list; everything else rides the responder chain.
    static func makeMainMenu(coordinator: WorkspaceAppCoordinator?) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "FinderAI")
        let about = NSMenuItem(title: "FinderAIについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let update = NSMenuItem(
            title: "アップデートを確認…",
            action: #selector(WorkspaceUpdater.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        update.target = coordinator?.updater
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(
            title: "設定…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = coordinator
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "FinderAIを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
        // The coordinator owns the window list, so this one keeps an explicit
        // target instead of riding the responder chain.
        let newWindowItem = NSMenuItem(
            title: "新規ウインドウ",
            action: #selector(WorkspaceAppCoordinator.newWindow),
            keyEquivalent: "n"
        )
        newWindowItem.target = coordinator
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("フォルダを開く…", action: #selector(WorkspaceBrowserViewController.openFolderChooser), key: "o"))
        let newFolder = item("新規フォルダ", action: #selector(WorkspaceBrowserViewController.createFolder), key: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newFolder)
        let open = item("開く", action: #selector(WorkspaceBrowserViewController.openSelection), key: "\u{F701}")
        open.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(open)
        let quickLook = item("クイックルック", action: #selector(WorkspaceBrowserViewController.toggleQuickLook), key: "y")
        fileMenu.addItem(quickLook)
        fileMenu.addItem(item("名前を変更…", action: #selector(WorkspaceBrowserViewController.renameSelection), key: ""))
        fileMenu.addItem(.separator())
        // These existed only in the context menu, so a user who never
        // right-clicked had no way to reach them — or to learn they existed.
        // Keys match Finder: ⌘I, ⌘D, ⌃⌘A.
        fileMenu.addItem(item("情報を見る", action: #selector(WorkspaceBrowserViewController.showInfo), key: "i"))
        fileMenu.addItem(item("複製", action: #selector(WorkspaceBrowserViewController.duplicateSelection), key: "d"))
        let alias = item(
            "エイリアスを作成",
            action: #selector(WorkspaceBrowserViewController.makeAliasForSelection),
            key: "a"
        )
        alias.keyEquivalentModifierMask = [.command, .control]
        fileMenu.addItem(alias)
        fileMenu.addItem(item("圧縮", action: #selector(WorkspaceBrowserViewController.compressSelection), key: ""))
        fileMenu.addItem(.separator())
        let trash = item("ゴミ箱に入れる…", action: #selector(WorkspaceBrowserViewController.trashSelection), key: "\u{8}")
        trash.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(trash)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Undo targets nil so it walks the responder chain to the window's
        // UndoManager, which is where the browser registers its operations.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        // Standard selectors deliberately stay on the responder chain. Text
        // fields and Terminal consume them first; a workspace view falls
        // through to WorkspaceBrowserViewController's file operations.
        editMenu.addItem(NSMenuItem(
            title: "カット",
            action: #selector(WorkspaceBrowserViewController.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "コピー",
            action: #selector(WorkspaceBrowserViewController.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "ペースト",
            action: #selector(WorkspaceBrowserViewController.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "移動")
        goMenu.addItem(item("戻る", action: #selector(WorkspaceBrowserViewController.goBack), key: "["))
        goMenu.addItem(item("進む", action: #selector(WorkspaceBrowserViewController.goForward), key: "]"))
        let up = item("親フォルダ", action: #selector(WorkspaceBrowserViewController.goUp), key: "\u{F700}")
        up.keyEquivalentModifierMask = [.command]
        goMenu.addItem(up)
        goMenu.addItem(item("再読み込み", action: #selector(WorkspaceBrowserViewController.refresh), key: "r"))
        goMenu.addItem(.separator())
        let finderHere = item(
            "Finderの現在地を開く",
            action: #selector(WorkspaceBrowserViewController.openFinderLocation),
            key: "f"
        )
        finderHere.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(finderHere)
        goItem.submenu = goMenu
        main.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "表示")
        // ⌘2/⌘3/⌘4 are where Finder puts list/column/gallery. The cycle keeps
        // its own key so the older habit still works.
        viewMenu.addItem(item("リスト表示", action: #selector(WorkspaceBrowserViewController.selectListView), key: "2"))
        viewMenu.addItem(item("カラム表示", action: #selector(WorkspaceBrowserViewController.selectColumnView), key: "3"))
        viewMenu.addItem(item("ギャラリー表示", action: #selector(WorkspaceBrowserViewController.selectGalleryView), key: "4"))
        let cycleView = item(
            "表示モードを切り替え",
            action: #selector(WorkspaceBrowserViewController.toggleColumnView),
            key: "2"
        )
        cycleView.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(cycleView)
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Terminalを開く／隠す", action: #selector(WorkspaceWindowController.toggleTerminal), key: "j"))
        let terminalEdge = item(
            "Terminalを右／下に移動",
            action: #selector(WorkspaceWindowController.toggleTerminalEdge),
            key: "j"
        )
        terminalEdge.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(terminalEdge)
        let terminalSize = item(
            "Terminalの大きさを切り替え",
            action: #selector(WorkspaceWindowController.cycleTerminalSize),
            key: "j"
        )
        terminalSize.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(terminalSize)
        // 永続化と出力ログのトグルは設定ウインドウ（⌘,）にある。メニューに残すのは
        // 動作だけで、状態の置き場にはしない。
        let manageSessions = NSMenuItem(
            title: "Terminalセッションを管理…",
            action: #selector(WorkspaceAppCoordinator.showTerminalSessionsPanel),
            keyEquivalent: "t"
        )
        manageSessions.keyEquivalentModifierMask = [.command, .option]
        manageSessions.target = coordinator
        viewMenu.addItem(manageSessions)
        let split = item("2画面に分割／解除", action: #selector(WorkspaceWindowController.toggleSplit), key: "s")
        split.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(split)
        let hidden = item("隠しファイルを表示／隠す", action: #selector(WorkspaceBrowserViewController.toggleHiddenFiles), key: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(hidden)
        // ⌘D belongs to 複製 in Finder; pinning takes ⌃⌘T, where Finder puts
        // "サイドバーに追加".
        let pin = item(
            "サイドバーにピン留め／解除",
            action: #selector(WorkspaceBrowserViewController.togglePin),
            key: "t"
        )
        pin.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(pin)
        // 画面端のタブはウインドウに属さないので、コマンドはレスポンダチェーンでは
        // なくコーディネータへ直接向ける。
        let edgeTab = NSMenuItem(
            title: "このフォルダを画面端に置く／外す",
            action: #selector(WorkspaceAppCoordinator.toggleEdgeTabForCurrentFolder),
            keyEquivalent: "e"
        )
        edgeTab.keyEquivalentModifierMask = [.command, .control]
        edgeTab.target = coordinator
        viewMenu.addItem(edgeTab)
        let edgeTabsVisibility = NSMenuItem(
            title: "画面端のフォルダを表示／隠す",
            action: #selector(WorkspaceAppCoordinator.toggleEdgeTabsVisibility),
            keyEquivalent: ""
        )
        edgeTabsVisibility.target = coordinator
        viewMenu.addItem(edgeTabsVisibility)
        let edgeTabsSide = NSMenuItem(
            title: "画面端のフォルダを左右に切り替え",
            action: #selector(WorkspaceAppCoordinator.toggleEdgeTabsSide),
            keyEquivalent: ""
        )
        edgeTabsSide.target = coordinator
        viewMenu.addItem(edgeTabsSide)
        let edgeTabsAutoHide = NSMenuItem(
            title: "画面端のフォルダを自動的に隠す",
            action: #selector(WorkspaceAppCoordinator.toggleEdgeTabsAutoHide),
            keyEquivalent: ""
        )
        edgeTabsAutoHide.target = coordinator
        viewMenu.addItem(edgeTabsAutoHide)
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("このフォルダを検索", action: #selector(WorkspaceBrowserViewController.focusSearchField), key: "f"))
        viewMenu.addItem(item("パスを入力…", action: #selector(WorkspaceBrowserViewController.beginPathEditing), key: "l"))
        let copyPath = item("パス名をコピー", action: #selector(WorkspaceBrowserViewController.copyCurrentPath), key: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(copyPath)
        viewMenu.addItem(item(
            "“cd” コマンドをコピー",
            action: #selector(WorkspaceBrowserViewController.copyChangeDirectoryCommand),
            key: ""
        ))
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(NSMenuItem(title: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "すべてを手前に移動", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        let windowList = NSMenuItem(
            title: "ウインドウの一覧…",
            action: #selector(WorkspaceAppCoordinator.showWindowsPanel),
            keyEquivalent: "w"
        )
        // ⌘⌥WはmacOSが「すべてを閉じる」に使う。奪うと閉じるほうが効かなくなる。
        windowList.keyEquivalentModifierMask = [.command, .control]
        windowList.target = coordinator
        windowMenu.addItem(windowList)
        // 開いているウインドウをAppKitがここへ並べる（`configureMainMenu`で
        // `windowsMenu`に繋いである）。20枚まで開ける作りなので、「どれがどれか」
        // を辿れる場所として要る。
        windowMenu.addItem(.separator())
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }

    /// Target stays nil so AppKit walks the responder chain and the command lands
    /// on whichever window is key.
    ///
    /// These used to target `workspace.browser` — the first window's browser —
    /// which was invisible with one window and would have sent every menu command
    /// to window 1 regardless of what the user was looking at.
    private static func item(
        _ title: String,
        action: Selector,
        key: String
    ) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private static func defaultDirectory() -> URL {
        // Protected/File Provider folders can block synchronous metadata calls.
        // Start from the always-known home URL so the first window is immediate;
        // project roots remain one click away in the sidebar.
        //
        // Restoring the previous folder resolves a bookmark, which stays local and
        // returns nil rather than blocking when the volume is gone.
        WorkspacePreferences().lastDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
