import AppKit
import FinderAICore

/// ⌘,の設定ウインドウ。設定の実体はこれまでどおり`WorkspacePreferences`で、
/// ここはそれを見せる場所にすぎない。表示メニューに直置きしていたトグルは
/// ここへ移した：メニューは動作の場所で、状態の置き場ではないから。
@MainActor
final class SettingsWindowController: NSWindowController {
    /// 画面端のフォルダに関する設定が変わった。反映はアプリ全体で1つの
    /// `EdgeTabsController`が持っているので、コーディネータへ返す。
    var onEdgeTabsChanged: (() -> Void)?
    /// Terminalパネルの辺が変わった。開いている全ウインドウに適用する。
    var onTerminalEdgeChanged: ((TerminalPanelEdge) -> Void)?

    private let sessionManager: any TerminalSessionManaging
    private let preferences: WorkspacePreferences
    /// 高さを測るために持っておく。窓の大きさは中身から決める。
    private var contentStack: NSStackView?

    private let terminalEdgeControl = NSSegmentedControl(
        labels: ["下辺", "右辺"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let terminalEdgeCaption = NSTextField(wrappingLabelWithString: "")
    private let persistCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let persistCaption = NSTextField(wrappingLabelWithString: "")
    private let loggingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loggingCaption = NSTextField(wrappingLabelWithString: "")

    private let edgeTabsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let edgeTabsCaption = NSTextField(wrappingLabelWithString: "")
    private let edgeTabsSideControl = NSSegmentedControl(
        labels: ["左端", "右端"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let edgeTabsAutoHideCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let edgeTabsAutoHideCaption = NSTextField(wrappingLabelWithString: "")
    private let edgeTabsHoverCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let edgeTabsHoverCaption = NSTextField(wrappingLabelWithString: "")
    private let edgeTabsFollowCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let edgeTabsFollowCaption = NSTextField(wrappingLabelWithString: "")
    /// 帯がどこに出るかの図。4つの設定の掛け算で決まるので、文章より図が早い。
    private let edgeTabsMap = EdgeTabsMapView()
    private let edgeTabsMapCaption = NSTextField(wrappingLabelWithString: "")
    private let edgeTabsPreviewCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let edgeTabsFinderCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let edgeTabsFinderCaption = NSTextField(wrappingLabelWithString: "")
    /// 登録済みのフォルダ。ここから外せないと、タブを右クリックする方法しか
    /// 無いことになる——隠す設定にしていると、その右クリックの的が画面に無い。
    private let edgeTabsList = NSStackView()
    /// 縁に置くフォルダを、ここからも足せるように。⌃⌘Eしか道が無いと、
    /// 何も登録していない人には設定画面から始められる操作が1つも無い。
    private let edgeTabsAddButton = NSButton(title: "", target: nil, action: nil)
    /// 新しいウインドウで開くフォルダの現在値。指定なしのときはその旨を出す。
    private let newWindowPathLabel = NSTextField(labelWithString: "")
    private let newWindowCaption = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let commitLabel = NSTextField(labelWithString: "")
    private let installationLabel = NSTextField(wrappingLabelWithString: "")

    init(
        sessionManager: any TerminalSessionManaging,
        preferences: WorkspacePreferences
    ) {
        self.sessionManager = sessionManager
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 0),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "設定"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(in: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        refresh()
        fitToScreen()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 開くたびに実体から読み直す。設定はここ以外（将来のメニューやコード）からも
    /// 変わり得る前提で、このウインドウは真実を写すだけにする。
    private func refresh() {
        terminalEdgeControl.selectedSegment = preferences.terminalEdge == .bottom ? 0 : 1
        edgeTabsCheckbox.state = preferences.edgeTabsEnabled ? .on : .off
        edgeTabsSideControl.selectedSegment = preferences.edgeTabsEdge == .left ? 0 : 1
        edgeTabsAutoHideCheckbox.state = preferences.edgeTabsAutoHide ? .on : .off
        // タブが1つも無ければ、左右も自動的に隠すも効きようがない。
        edgeTabsHoverCheckbox.state = preferences.edgeTabsOpensOnHover ? .on : .off
        edgeTabsFollowCheckbox.state = preferences.edgeTabsFollowsPointer ? .on : .off
        edgeTabsMap.edge = preferences.edgeTabsEdge
        edgeTabsMap.followsPointer = preferences.edgeTabsFollowsPointer
        edgeTabsMap.autoHides = preferences.edgeTabsAutoHide
        edgeTabsPreviewCheckbox.state = preferences.edgeTabsShowsPreview ? .on : .off
        edgeTabsFinderCheckbox.state = preferences.edgeTabsUsesFinderWindows ? .on : .off
        // フォルダが1つも無くても、置き方は先に決められる。登録するまで全部を
        // 触れなくしていたので、設定を開いても押せるものが1つも無かった——
        // 決めた設定は、最初の1つを入れた瞬間から効く。
        let enabled = preferences.edgeTabsEnabled
        edgeTabsSideControl.isEnabled = enabled
        edgeTabsAutoHideCheckbox.isEnabled = enabled
        edgeTabsHoverCheckbox.isEnabled = enabled
        edgeTabsPreviewCheckbox.isEnabled = enabled
        edgeTabsFollowCheckbox.isEnabled = enabled
        edgeTabsFinderCheckbox.isEnabled = enabled
        edgeTabsMap.isActive = enabled
        // 上限まで入っていれば、足す先が無い。
        edgeTabsAddButton.isEnabled = enabled
            && preferences.edgeTabs.urls.count < WorkspaceEdgeTabs.capacity
        rebuildEdgeTabsList()

        let tmuxAvailable = sessionManager.persistenceAvailable
        persistCheckbox.state = sessionManager.persistenceEnabled ? .on : .off
        persistCheckbox.isEnabled = tmuxAvailable
        persistCaption.stringValue = tmuxAvailable
            ? "FinderAIが落ちたり終了しても、以降に開始したセッションはtmux内で生き続け、同じフォルダから再接続できます。"
            : "tmuxが見つかりません。Homebrewなら `brew install tmux` で導入すると有効にできます。"
        loggingCheckbox.state = preferences.sessionLogging ? .on : .off
        newWindowPathLabel.stringValue = preferences.newWindowDirectory
            .map { "開く先: \($0.path)" }
            ?? "指定なし（⌘Nは手前のウインドウと同じフォルダ）"
        let buildInfo = WorkspaceBuildInfo.current
        versionLabel.stringValue = buildInfo.versionText
        commitLabel.stringValue = buildInfo.commitText
        installationLabel.stringValue = buildInfo.installationText
        installationLabel.textColor = buildInfo.installationState == .restartRequired
            ? .systemOrange
            : .secondaryLabelColor
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "Terminal")
        title.font = .boldSystemFont(ofSize: 13)

        let edgeTabsTitle = NSTextField(labelWithString: "画面端のフォルダ")
        edgeTabsTitle.font = .boldSystemFont(ofSize: 13)

        let appTitle = NSTextField(labelWithString: "FinderAI")
        appTitle.font = .boldSystemFont(ofSize: 13)

        terminalEdgeControl.target = self
        terminalEdgeControl.action = #selector(changeTerminalEdge)
        terminalEdgeCaption.stringValue = "パネルを置く辺です。下辺は横に長く、右辺は縦に長くなります。ビルド出力やAIセッションのように縦へ流れるものは右辺のほうが読めます。高さと幅は別々に覚えます。"

        edgeTabsCheckbox.title = "画面端にフォルダのタブを表示"
        edgeTabsCheckbox.target = self
        edgeTabsCheckbox.action = #selector(toggleEdgeTabs)
        edgeTabsCaption.stringValue = "よく使うフォルダを画面の縁に貼り付けます。カーソルを乗せると中身が開き、離れると畳まれます。FinderAIが前面になくても使え、押しても前面に出てきません。フォルダは`⌃⌘E`で追加します（\(WorkspaceEdgeTabs.capacity)個まで）。"

        edgeTabsSideControl.target = self
        edgeTabsSideControl.action = #selector(changeEdgeTabsSide)

        edgeTabsAutoHideCheckbox.title = "使わないときは画面の外に隠す"
        edgeTabsAutoHideCheckbox.target = self
        edgeTabsAutoHideCheckbox.action = #selector(toggleEdgeTabsAutoHide)
        edgeTabsAutoHideCaption.stringValue = "普段はタブを画面の外へ引っ込め、画面の縁にカーソルを当てたときだけ滑り出させます。"

        edgeTabsHoverCheckbox.title = "マウスを乗せるだけで開く"
        edgeTabsHoverCheckbox.target = self
        edgeTabsHoverCheckbox.action = #selector(toggleEdgeTabsHover)
        edgeTabsHoverCaption.stringValue = "触れて0.2秒で開きます。オフのときはクリックで開きます。タブの⌃クリックでリスト／アイコン表示と並び順、⌘クリックで上の階層を辿れます。"

        edgeTabsFollowCheckbox.title = "カーソルのいる側へ移す"
        edgeTabsFollowCheckbox.target = self
        edgeTabsFollowCheckbox.action = #selector(toggleEdgeTabsFollow)
        edgeTabsFollowCaption.stringValue = "その画面でカーソルが右半分にいるときは右端、左半分なら左端へ帯を移します。手のある側に出ているほうが近いためです。オフにすると上で選んだ縁に固定します。"

        edgeTabsMapCaption.stringValue = "モニタの左右の縁を押すと、タブを置く縁が変わります。"
        edgeTabsMap.onSelectEdge = { [weak self] edge in
            guard let self else { return }
            self.preferences.edgeTabsEdge = edge
            self.refresh()
            self.onEdgeTabsChanged?()
        }
        edgeTabsMap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            edgeTabsMap.widthAnchor.constraint(equalToConstant: 296),
            edgeTabsMap.heightAnchor.constraint(equalToConstant: 124)
        ])

        edgeTabsPreviewCheckbox.title = "選んだものを一覧の下でプレビュー"
        edgeTabsPreviewCheckbox.target = self
        edgeTabsPreviewCheckbox.action = #selector(toggleEdgeTabsPreview)

        edgeTabsFinderCheckbox.title = "開くときにFinderのウインドウも探す"
        edgeTabsFinderCheckbox.target = self
        edgeTabsFinderCheckbox.action = #selector(toggleEdgeTabsFinder)
        edgeTabsFinderCaption.stringValue = "macOS標準のFinderがすでにそのフォルダを開いていれば、そのウインドウを前に出します。Finderを何枚も開いて使うときに、同じ場所の窓が増えません。"

        edgeTabsList.orientation = .vertical
        edgeTabsList.alignment = .leading
        edgeTabsList.spacing = 2

        edgeTabsAddButton.title = "フォルダを追加..."
        edgeTabsAddButton.bezelStyle = .rounded
        edgeTabsAddButton.target = self
        edgeTabsAddButton.action = #selector(addEdgeTabFolders)

        persistCheckbox.title = "セッションを永続化（tmux）"
        persistCheckbox.target = self
        persistCheckbox.action = #selector(togglePersistence)

        loggingCheckbox.title = "出力をログに保存"
        loggingCheckbox.target = self
        loggingCheckbox.action = #selector(toggleLogging)
        loggingCaption.stringValue = "これ以降に開始するセッションの出力（コマンドと表示内容を含む）をローカルに保存します。完全終了時に選んだ回復用記録も同じフォルダに置かれ、どちらも14日で自動削除します。"

        newWindowCaption.stringValue = "⌘Nと起動時の最初のウインドウを、決めたフォルダで開きます。指定が無ければ、⌘Nは手前のウインドウと同じフォルダ、起動時は最後に見ていたフォルダです。"
        newWindowPathLabel.font = .systemFont(ofSize: 11)
        newWindowPathLabel.textColor = .labelColor
        newWindowPathLabel.lineBreakMode = .byTruncatingMiddle
        newWindowPathLabel.preferredMaxLayoutWidth = 400

        [
            terminalEdgeCaption,
            persistCaption,
            loggingCaption,
            edgeTabsCaption,
            edgeTabsHoverCaption,
            edgeTabsFollowCaption,
            edgeTabsMapCaption,
            edgeTabsAutoHideCaption,
            edgeTabsFinderCaption,
            newWindowCaption,
            commitLabel,
            installationLabel
        ].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.preferredMaxLayoutWidth = 400
        }
        versionLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let openLogs = NSButton(
            title: "ログフォルダを開く",
            target: self,
            action: #selector(openLogFolder)
        )
        openLogs.bezelStyle = .rounded
        openLogs.controlSize = .small

        let separator = NSBox()
        separator.boxType = .separator
        let edgeTabsSeparator = NSBox()
        edgeTabsSeparator.boxType = .separator
        let windowSeparator = NSBox()
        windowSeparator.boxType = .separator

        let windowTitle = NSTextField(labelWithString: "ウインドウ")
        windowTitle.font = .boldSystemFont(ofSize: 13)
        let chooseNewWindowFolder = NSButton(
            title: "開く先のフォルダを選択…",
            target: self,
            action: #selector(chooseNewWindowDirectory)
        )
        chooseNewWindowFolder.bezelStyle = .rounded
        chooseNewWindowFolder.controlSize = .small
        let clearNewWindowFolder = NSButton(
            title: "指定を外す",
            target: self,
            action: #selector(clearNewWindowDirectory)
        )
        clearNewWindowFolder.bezelStyle = .rounded
        clearNewWindowFolder.controlSize = .small
        let newWindowButtonsRow = NSStackView(views: [chooseNewWindowFolder, clearNewWindowFolder])
        newWindowButtonsRow.orientation = .horizontal
        newWindowButtonsRow.spacing = 8

        let placementRow = NSStackView(views: [
            NSTextField(labelWithString: "パネルの位置"),
            terminalEdgeControl
        ])
        placementRow.orientation = .horizontal
        placementRow.spacing = 10

        let sideRow = NSStackView(views: [
            NSTextField(labelWithString: "貼り付ける縁"),
            edgeTabsSideControl
        ])
        sideRow.orientation = .horizontal
        sideRow.spacing = 10

        let stack = NSStackView(views: [
            title,
            placementRow, indented(terminalEdgeCaption),
            persistCheckbox, indented(persistCaption),
            loggingCheckbox, indented(loggingCaption), indented(openLogs),
            windowSeparator,
            windowTitle,
            newWindowPathLabel,
            newWindowButtonsRow, indented(newWindowCaption),
            edgeTabsSeparator,
            edgeTabsTitle,
            edgeTabsCheckbox, indented(edgeTabsCaption),
            indented(edgeTabsMap), indented(edgeTabsMapCaption),
            indented(sideRow),
            indented(edgeTabsFollowCheckbox), indented(edgeTabsFollowCaption),
            indented(edgeTabsHoverCheckbox), indented(edgeTabsHoverCaption),
            indented(edgeTabsPreviewCheckbox),
            indented(edgeTabsAutoHideCheckbox), indented(edgeTabsAutoHideCaption),
            indented(edgeTabsFinderCheckbox), indented(edgeTabsFinderCaption),
            indented(edgeTabsList),
            indented(edgeTabsAddButton),
            separator,
            appTitle, versionLabel, commitLabel, installationLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(16, after: indentedViews[terminalEdgeCaption] ?? terminalEdgeCaption)
        stack.setCustomSpacing(16, after: indentedViews[persistCaption] ?? persistCaption)
        stack.setCustomSpacing(16, after: indentedViews[openLogs] ?? openLogs)
        stack.setCustomSpacing(14, after: edgeTabsTitle)
        stack.setCustomSpacing(16, after: indentedViews[edgeTabsCaption] ?? edgeTabsCaption)
        stack.setCustomSpacing(14, after: indentedViews[edgeTabsMapCaption] ?? edgeTabsMapCaption)
        stack.setCustomSpacing(
            16,
            after: indentedViews[edgeTabsAutoHideCaption] ?? edgeTabsAutoHideCaption
        )
        // 設定は縦に長い。画面に収まらない高さのまま出していたので、下のほうは
        // 見ることも押すこともできなかった（実測で1324pt——1080ptのモニタには
        // 最初から入らない）。中身はスクロールに預け、窓の高さは画面に合わせる。
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        contentStack = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            // 横はスクロールさせない。文章が折り返す幅は窓が決める。
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    /// 開くたびに、その画面に収まる高さへ合わせる。
    ///
    /// 中身が伸びても窓が伸び続けないよう、上限は画面の見える範囲。足りないぶんは
    /// スクロールが引き受ける。
    private func fitToScreen() {
        guard let window, let stack = contentStack else { return }
        stack.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize.height + 40
        let screen = window.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 900) - 60
        window.setContentSize(NSSize(width: 460, height: min(needed, available)))
    }

    /// captionをcheckboxの文字位置に揃えるためのぶら下げインデント。
    private var indentedViews: [NSView: NSView] = [:]

    private func indented(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        indentedViews[view] = container
        return container
    }

    /// 登録済みフォルダの一覧を作り直す。設定を開いたときと、ここから外した直後。
    private func rebuildEdgeTabsList() {
        edgeTabsList.arrangedSubviews.forEach {
            edgeTabsList.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let urls = preferences.edgeTabs.urls
        guard !urls.isEmpty else {
            let empty = NSTextField(labelWithString: "まだ登録がありません。フォルダを開いて⌃⌘Eです。")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            edgeTabsList.addArrangedSubview(empty)
            return
        }
        for (index, url) in urls.enumerated() {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: url.lastPathComponent)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = url.path(percentEncoded: false)
            let remove = NSButton()
            remove.title = ""
            remove.isBordered = false
            remove.image = NSImage(
                systemSymbolName: "minus.circle",
                accessibilityDescription: "画面端から外す"
            )
            remove.contentTintColor = .secondaryLabelColor
            remove.toolTip = "画面端から外す"
            remove.tag = index
            remove.target = self
            remove.action = #selector(removeEdgeTab(_:))

            let row = NSStackView(views: [icon, label, remove])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                remove.widthAnchor.constraint(equalToConstant: 18),
                remove.heightAnchor.constraint(equalToConstant: 18),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
            ])
            edgeTabsList.addArrangedSubview(row)
        }
    }

    @objc private func changeTerminalEdge() {
        let edge: TerminalPanelEdge = terminalEdgeControl.selectedSegment == 0 ? .bottom : .right
        preferences.terminalEdge = edge
        onTerminalEdgeChanged?(edge)
    }

    @objc private func toggleEdgeTabs() {
        preferences.edgeTabsEnabled = edgeTabsCheckbox.state == .on
        onEdgeTabsChanged?()
        refresh()
    }

    @objc private func changeEdgeTabsSide() {
        preferences.edgeTabsEdge = edgeTabsSideControl.selectedSegment == 0 ? .left : .right
        refresh()
        onEdgeTabsChanged?()
    }

    @objc private func toggleEdgeTabsAutoHide() {
        preferences.edgeTabsAutoHide = edgeTabsAutoHideCheckbox.state == .on
        refresh()
        onEdgeTabsChanged?()
    }

    @objc private func toggleEdgeTabsHover() {
        preferences.edgeTabsOpensOnHover = edgeTabsHoverCheckbox.state == .on
        onEdgeTabsChanged?()
    }

    @objc private func toggleEdgeTabsFollow() {
        preferences.edgeTabsFollowsPointer = edgeTabsFollowCheckbox.state == .on
        refresh()
        onEdgeTabsChanged?()
    }

    @objc private func toggleEdgeTabsPreview() {
        preferences.edgeTabsShowsPreview = edgeTabsPreviewCheckbox.state == .on
        onEdgeTabsChanged?()
    }

    @objc private func toggleEdgeTabsFinder() {
        preferences.edgeTabsUsesFinderWindows = edgeTabsFinderCheckbox.state == .on
    }

    @objc private func removeEdgeTab(_ sender: NSButton) {
        var tabs = preferences.edgeTabs
        let urls = tabs.urls
        guard urls.indices.contains(sender.tag) else { return }
        tabs.remove(urls[sender.tag])
        preferences.edgeTabs = tabs
        onEdgeTabsChanged?()
        refresh()
    }

    @objc private func togglePersistence() {
        sessionManager.persistenceEnabled = persistCheckbox.state == .on
    }

    @objc private func toggleLogging() {
        preferences.sessionLogging = loggingCheckbox.state == .on
    }

    @objc private func openLogFolder() {
        // まだ一度もログを書いていなくても、開けるように作ってから開く。
        try? FileManager.default.createDirectory(
            at: SessionLogStore.directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(SessionLogStore.directory)
    }

    @objc private func chooseNewWindowDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.newWindowDirectory
        panel.prompt = "この場所にする"
        panel.message = "新しいウインドウで開くフォルダを選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.newWindowDirectory = url
        refresh()
    }

    @objc private func addEdgeTabFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "縁に置く"
        panel.message = "画面の縁に置くフォルダを選んでください（\(WorkspaceEdgeTabs.capacity)個まで）"
        guard panel.runModal() == .OK else { return }
        var tabs = preferences.edgeTabs
        // 上限に当たったぶんは黙って落ちる。選び直させるより、入ったものを
        // そのまま見せて、足りなければもう一度押してもらうほうが早い。
        for url in panel.urls {
            _ = tabs.add(url)
        }
        preferences.edgeTabs = tabs
        refresh()
        onEdgeTabsChanged?()
    }

    @objc private func clearNewWindowDirectory() {
        preferences.newWindowDirectory = nil
        refresh()
    }
}
