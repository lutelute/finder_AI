import AppKit
import FinderAICore
import QuickLookThumbnailing
import QuickLookUI

/// タブから開くフォルダの中身。
///
/// 一覧は`WorkspaceDirectoryListing.contents`をそのまま使う。ブラウザ本体と同じ
/// 並び・同じ隠しファイル規則になるので、「FinderAIで見たときと違う」が起きない。
///
/// 中身はディスクに残さない。畳んでいるあいだは読み込みもしない（開いた瞬間に
/// 読み、閉じたら捨てる）。常駐UIが裏で仕事を続けないための線引き。
@MainActor
final class EdgeTabPopoverController: NSObject {
    var onOpenDirectory: ((URL) -> Void)?
    /// ポップアップ自身の上にカーソルがあるか。タブから渡ってくる途中で閉じない
    /// ように、コントローラ側の猶予タイマーと繋ぐ。
    var onHoverChanged: ((Bool) -> Void)?
    /// 一覧から何かを掴んでいる最中か。
    var onDraggingChanged: ((Bool) -> Void)?

    /// 開いているか。自動的に隠す設定でも、覗いているあいだは土台を引っ込めない。
    var isPresented: Bool { panel.isVisible }
    /// いまどのタブから開いているか。同じタブをもう一度押したら閉じるための目印。
    private(set) var presentedRoot: URL?
    /// どのモニタの帯から開いたか。その画面の帯だけは引っ込めない。
    private(set) var presentedScreenID: CGDirectDisplayID?
    /// 画面上の位置。カーソルがこの上にあるあいだは閉じない。
    var frame: CGRect { panel.frame }

    private let panel: EdgeTabPanel
    private let container = HoverReportingView()
    private let backButton = NSButton()
    private let headerRow = NSStackView()
    private let headerSpacer = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let tableView = EdgeTabTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// 選んだものの中身をその場で見せる帯。開くかどうか決める前に確かめられる。
    private let previewBox = NSView()
    private let previewImage = NSImageView()
    private let previewName = NSTextField(labelWithString: "")
    private let previewDetail = NSTextField(labelWithString: "")
    private var previewTask: Task<Void, Never>?
    private var previewedURL: URL?
    private var previewHeightConstraint: NSLayoutConstraint!
    private let fileService = WorkspaceFileService()
    private let clipboard = WorkspaceFileClipboard()
    private var quickLookURLs: [NSURL] = []
    private let preferences: WorkspacePreferences
    /// アイコン表示。行の一覧と同じ`items`を、並べ方だけ変えて見せる。
    private let iconGrid = EdgeTabCollectionView()
    private let iconScrollView = NSScrollView()

    private var directory: URL?
    private var items: [WorkspaceItem] = []
    private var loadTask: Task<Void, Never>?
    /// タブが指すフォルダ。ここから何階層降りても、戻る先の起点は動かない。
    private var rootDirectory: URL?
    /// いま開いている場所までの道。戻るボタンはこれを1つずつ巻き戻す。
    private var descent: [URL] = []
    private var edge: WorkspaceScreenEdge = .right
    private var anchor: CGRect = .zero
    private var visibleFrame: CGRect = .zero

    private static let rowHeight: CGFloat = 24
    private static let chromeHeight: CGFloat = 46
    /// プレビュー帯の高さ。畳んでいるあいだは0で、選ぶと開く。
    ///
    /// 小さすぎるサムネイルは「何かが写っている」以上のことを伝えない。開くか
    /// どうかを決められる大きさが要る。
    private static let previewHeight: CGFloat = 208
    private static let previewImageHeight: CGFloat = 152

    init(preferences: WorkspacePreferences) {
        self.preferences = preferences
        // 一覧は矢印キーで動かせる必要があるので、こちらはキーになれるパネル。
        // `.nonactivatingPanel`のままなので、キーになってもFinderAIは前面に出ない。
        panel = EdgeTabPanel(acceptsKey: true)
        super.init()
        configure()
    }

    private func configure() {
        // 背景・角・枠は`draw`が引く。レイヤー側にも角丸を置くと、帯に接する辺を
        // 落とした形の上から全周の丸みが重なって輪郭が濁る。
        container.wantsLayer = true
        container.appearance = NSAppearance(named: .darkAqua)
        container.onHoverChanged = { [weak self] isInside in
            self?.onHoverChanged?(isInside)
        }
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = IntegratedPanelTheme.text
        titleLabel.lineBreakMode = .byTruncatingMiddle

        backButton.title = ""
        backButton.isBordered = false
        backButton.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "1つ上へ戻る"
        )
        backButton.contentTintColor = IntegratedPanelTheme.secondaryText
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = "1つ上へ戻る"
        backButton.isHidden = true

        openButton.title = "開く"
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.target = self
        openButton.action = #selector(openDirectory)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = IntegratedPanelTheme.secondaryText
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelectedRow)
        // 取り出しはコピーでも移動でもよく、放り込みも受ける。規則はブラウザ本体と
        // 同じ`WorkspaceDragDrop`に預けてあるので、こことあちらで挙動が割れない。
        tableView.setDraggingSourceOperationMask(WorkspaceDragDrop.localSourceOperations, forLocal: true)
        tableView.setDraggingSourceOperationMask(WorkspaceDragDrop.localSourceOperations, forLocal: false)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.onContextMenu = { [weak self] in
            self?.makeItemMenu(for: self?.contextItem)
        }
        iconGrid.onContextMenu = { [weak self] in
            self?.makeItemMenu(for: self?.selectedItem)
        }
        tableView.onDragSessionChanged = { [weak self] isDragging in
            // ドロップ先を探しているあいだにポップアップが消えるのが、この種の
            // UIでいちばん多い失敗。ドラッグ中は閉じる猶予を止める。
            self?.onHoverChanged?(isDragging)
            self?.onDraggingChanged?(isDragging)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 84, height: 76)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        iconGrid.collectionViewLayout = layout
        iconGrid.dataSource = self
        iconGrid.delegate = self
        iconGrid.isSelectable = true
        iconGrid.backgroundColors = [.clear]
        iconGrid.register(
            EdgeTabIconItem.self,
            forItemWithIdentifier: EdgeTabIconItem.identifier
        )
        iconGrid.setDraggingSourceOperationMask(WorkspaceDragDrop.localSourceOperations, forLocal: true)
        iconGrid.setDraggingSourceOperationMask(WorkspaceDragDrop.localSourceOperations, forLocal: false)
        iconGrid.registerForDraggedTypes([.fileURL])
        iconScrollView.documentView = iconGrid
        iconScrollView.hasVerticalScroller = true
        iconScrollView.drawsBackground = false
        iconScrollView.automaticallyAdjustsContentInsets = false
        iconScrollView.isHidden = true

        headerRow.setViews([backButton, titleLabel, headerSpacer, openButton], in: .leading)
        let header = headerRow
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        NSLayoutConstraint.activate([
            backButton.widthAnchor.constraint(equalToConstant: 18),
            backButton.heightAnchor.constraint(equalToConstant: 18)
        ])

        configurePreview()

        [header, scrollView, iconScrollView, previewBox, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        previewHeightConstraint = previewBox.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            iconScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            iconScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            iconScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            iconScrollView.bottomAnchor.constraint(equalTo: previewBox.topAnchor, constant: -6),

            previewBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            previewBox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            previewBox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            previewHeightConstraint
        ])
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 22),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: previewBox.topAnchor, constant: -6),

            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        ])
        panel.contentView = container
    }

    func present(
        directory: URL,
        anchor: CGRect,
        edge: WorkspaceScreenEdge,
        visibleFrame: CGRect,
        screenID: CGDirectDisplayID?,
        relativeTo owner: NSPanel
    ) {
        presentedScreenID = screenID
        // 縁のどちら側から出るかで、角の落とし方とヘッダーの並びが変わる。
        container.edge = edge
        applyEdgeChrome(edge)
        // タブを押し直したときは、前回降りていた階層ではなくフォルダの入口へ戻す。
        // 「そのタブを開く」といえば普通は根のことなので。
        let isSameRoot = rootDirectory == directory
        rootDirectory = directory
        descent = []
        self.edge = edge
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        if !isSameRoot {
            items = []
            tableView.reloadData()
        }
        presentedRoot = directory
        applyPresentationSettings()
        show(directory: directory, preferredRowCount: max(items.count, 8))
        // `orderFront`でも`makeKeyAndOrderFront`でもなく`orderFrontRegardless`。
        // このパネルが役に立つのはFinderAIが非アクティブなときで、その状態では
        // 前の2つはウインドウを前に出さない——出ているつもりで画面には何も無い、
        // という形で実機でだけ壊れる（実際に壊した）。
        //
        // 帯の子にするのはそのあと。可視にする前に親へ繋ぐと、子が親の表示状態を
        // 引き継いだきり前に出ないことがある。
        panel.orderFrontRegardless()
        owner.addChildWindow(panel, ordered: .above)
        // 矢印キーで動かせるように受け口を用意する。キーにできるのはアプリが
        // アクティブなときだけなので、できなくても描画には影響させない。
        panel.makeKey()
        panel.makeFirstResponder(preferences.edgeTabsUsesIconView ? iconGrid : tableView)
    }

    /// 縁の側に合わせて、ヘッダーの並びと戻る矢印の向きを入れ替える。
    ///
    /// 右の縁から左へ開くなら、指は右から入ってくる。「開く」は指の側、戻る矢印は
    /// 進む向きと逆——左右で同じ並びのままだと、どちらかで必ず遠い方を押しに行く
    /// ことになる。
    private func applyEdgeChrome(_ edge: WorkspaceScreenEdge) {
        guard headerRow.superview != nil else { return }
        let views: [NSView] = edge == .right
            ? [backButton, titleLabel, headerSpacer, openButton]
            : [openButton, headerSpacer, titleLabel, backButton]
        guard headerRow.arrangedSubviews != views else { return }
        headerRow.setViews(views, in: .leading)
        backButton.image = NSImage(
            systemSymbolName: edge == .right ? "chevron.left" : "chevron.right",
            accessibilityDescription: "1つ上へ戻る"
        )
        titleLabel.alignment = edge == .right ? .left : .right
    }

    private func configurePreview() {
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = IntegratedPanelTheme.header.cgColor
        previewBox.layer?.cornerRadius = 6
        previewBox.isHidden = true
        previewBox.toolTip = "クリックまたはスペースで大きく表示"
        let expand = NSClickGestureRecognizer(target: self, action: #selector(expandPreview))
        previewBox.addGestureRecognizer(expand)

        previewImage.imageScaling = .scaleProportionallyDown
        previewImage.imageAlignment = .alignCenter

        previewName.font = .systemFont(ofSize: 11, weight: .medium)
        previewName.textColor = IntegratedPanelTheme.text
        previewName.lineBreakMode = .byTruncatingMiddle
        previewDetail.font = .systemFont(ofSize: 10)
        previewDetail.textColor = IntegratedPanelTheme.secondaryText
        previewDetail.lineBreakMode = .byTruncatingTail

        [previewImage, previewName, previewDetail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            previewBox.addSubview($0)
        }
        NSLayoutConstraint.activate([
            previewImage.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 6),
            previewImage.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            previewImage.widthAnchor.constraint(lessThanOrEqualTo: previewBox.widthAnchor, constant: -12),
            previewImage.heightAnchor.constraint(equalToConstant: Self.previewImageHeight),
            previewName.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            previewName.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
            previewName.topAnchor.constraint(equalTo: previewImage.bottomAnchor, constant: 5),
            previewDetail.leadingAnchor.constraint(equalTo: previewName.leadingAnchor),
            previewDetail.trailingAnchor.constraint(equalTo: previewName.trailingAnchor),
            previewDetail.topAnchor.constraint(equalTo: previewName.bottomAnchor, constant: 1)
        ])
    }

    /// 選んだものの中身を、開く前に確かめられるようにする。
    ///
    /// サムネイルは`QLThumbnailGenerator`に任せる。種類ごとの分岐を自前で書くと、
    /// 対応できるものが増えるたびに追いかけることになる。
    private func updatePreview() {
        guard preferences.edgeTabsShowsPreview else {
            hidePreview()
            return
        }
        guard let item = selectedItem else {
            hidePreview()
            return
        }
        guard previewedURL != item.url else { return }
        previewedURL = item.url
        previewBox.isHidden = false
        previewHeightConstraint.constant = Self.previewHeight
        previewName.stringValue = item.name
        previewDetail.stringValue = previewDetailText(for: item)
        previewImage.image = WorkspaceIconProvider.shared.quickIcon(for: item)

        // 帯の高さが変わったぶん、パネルも伸ばす。制約だけ変えてもウインドウの
        // 大きさは変わらないので、ここを忘れると中身が枠からはみ出す。
        resize(edge: edge, anchor: anchor, visibleFrame: visibleFrame)

        previewTask?.cancel()
        let url = item.url
        let scale = max(panel.backingScaleFactor, 1)
        previewTask = Task { [weak self] in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(
                    width: EdgeTabPlacement.popoverWidth - 24,
                    height: Self.previewImageHeight
                ),
                scale: scale,
                representationTypes: .all
            )
            let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard !Task.isCancelled, let self, self.previewedURL == url else { return }
            if let image { self.previewImage.image = image.nsImage }
        }
    }

    private func previewDetailText(for item: WorkspaceItem) -> String {
        var parts: [String] = []
        if item.isDirectory {
            parts.append("フォルダ")
        } else if let size = item.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modified = item.modifiedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            parts.append(formatter.string(from: modified))
        }
        return parts.joined(separator: " · ")
    }

    private func hidePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewedURL = nil
        previewBox.isHidden = true
        previewHeightConstraint.constant = 0
    }

    /// プレビューを押したら、Quick Lookで大きく見る。この帯で足りないときの逃げ道。
    @objc private func expandPreview() {
        quickLookContextItem()
    }

    /// 表示形式と並び順を今の設定に合わせる。開いたままでも切り替えられる。
    func applyPresentationSettings() {
        let usesIcons = preferences.edgeTabsUsesIconView
        scrollView.isHidden = usesIcons
        iconScrollView.isHidden = !usesIcons
        items = preferences.edgeTabsSort.sorted(
            items,
            ascending: preferences.edgeTabsSortAscending
        )
        tableView.reloadData()
        iconGrid.reloadData()
        panel.makeFirstResponder(usesIcons ? iconGrid : tableView)
    }

    func dismiss() {
        loadTask?.cancel()
        loadTask = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        directory = nil
        rootDirectory = nil
        presentedRoot = nil
        presentedScreenID = nil
        descent = []
        items = []
        tableView.reloadData()
        iconGrid.reloadData()
    }

    // MARK: - キー操作

    /// 矢印で選び、→とreturnで開き（フォルダなら降り）、←で戻り、escで閉じる。
    ///
    /// ↑↓はテーブルとコレクションが自前で処理するので、ここで拾うのは残りだけ。
    /// パネルはキーになれるが`.nonactivatingPanel`なので、キーボードが使えるように
    /// なってもFinderAIが前面へ出ることはない。
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // ウインドウ側と同じ割り当て。端から覗いているだけで、できることは同じ。
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copyContextItem(); return true
            case "v": pasteIntoCurrentDirectory(); return true
            case "d": duplicateContextItem(); return true
            case "i": showInfoForContextItem(); return true
            case "n" where event.modifierFlags.contains(.shift):
                createFolderHere()
                return true
            case "\u{8}", String(UnicodeScalar(127)): // ⌘⌫
                trashContextItem()
                return true
            default: break
            }
        }
        if event.keyCode == 49 { // space
            quickLookContextItem()
            return true
        }
        switch event.keyCode {
        case 51, 117 where event.modifierFlags.contains(.command): // ⌘⌫ / ⌘delete
            trashContextItem()
            return true
        case 53: // esc
            onRequestDismiss?()
            return true
        case 123: // ←
            if descent.isEmpty {
                onRequestDismiss?()
            } else {
                goBack()
            }
            return true
        case 124, 36, 76: // → / return / enter
            activateSelection()
            return true
        default:
            return false
        }
    }

    /// escや←で閉じたいときに、コントローラ側の後始末（帯の収納など）へ返す。
    var onRequestDismiss: (() -> Void)?

    private var selectedItem: WorkspaceItem? {
        if preferences.edgeTabsUsesIconView {
            guard let index = iconGrid.selectionIndexPaths.first?.item,
                  items.indices.contains(index) else { return nil }
            return items[index]
        }
        guard items.indices.contains(tableView.selectedRow) else { return nil }
        return items[tableView.selectedRow]
    }

    private func activateSelection() {
        guard let item = selectedItem else { return }
        if item.isDirectory {
            descend(into: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// 表示先を差し替えて読み直す。降りるのも戻るのも同じ入口を通る。
    private func show(directory: URL, preferredRowCount: Int) {
        self.directory = directory
        titleLabel.stringValue = directory.lastPathComponent
        titleLabel.toolTip = directory.path(percentEncoded: false)
        backButton.isHidden = descent.isEmpty
        panel.setFrame(
            EdgeTabPlacement.popoverFrame(
                anchor: anchor,
                preferredHeight: EdgeTabPlacement.popoverHeight(
                    rowCount: preferredRowCount,
                    rowHeight: Self.rowHeight,
                    chrome: Self.chromeHeight + previewHeightConstraint.constant
                ),
                edge: edge,
                visibleFrame: visibleFrame
            ),
            display: true
        )
        load(directory: directory, edge: edge, anchor: anchor, visibleFrame: visibleFrame)
    }

    /// サブフォルダへ降りる。Dockより速く深い場所へ着けることがこの機能の主眼で、
    /// ここが無いとタブは単なるショートカットで終わる。
    private func descend(into directory: URL) {
        guard let current = self.directory else { return }
        descent.append(current)
        items = []
        tableView.reloadData()
        show(directory: directory, preferredRowCount: 8)
    }

    @objc private func goBack() {
        guard let parent = descent.popLast() else { return }
        items = []
        tableView.reloadData()
        show(directory: parent, preferredRowCount: 8)
    }

    private func load(
        directory: URL,
        edge: WorkspaceScreenEdge,
        anchor: CGRect,
        visibleFrame: CGRect
    ) {
        loadTask?.cancel()
        statusLabel.isHidden = true
        loadTask = Task { [weak self] in
            let result: Result<[WorkspaceItem], Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try WorkspaceDirectoryListing.contents(of: directory))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled, let self, self.directory == directory else { return }
            switch result {
            case .success(let loaded):
                let items = self.preferences.edgeTabsSort.sorted(
                    loaded,
                    ascending: self.preferences.edgeTabsSortAscending
                )
                self.items = items
                self.tableView.reloadData()
                self.iconGrid.reloadData()
                // 空に見えるのが権限のせいなのか本当に空なのかは、利用者からは
                // 区別できない。読めたが0件、と読めなかった、を書き分ける。
                self.statusLabel.stringValue = items.isEmpty ? "項目がありません" : ""
                self.statusLabel.isHidden = !items.isEmpty
            case .failure:
                self.items = []
                self.tableView.reloadData()
                self.iconGrid.reloadData()
                self.statusLabel.stringValue = "このフォルダを読み取れません\n（アクセス許可を確認してください）"
                self.statusLabel.isHidden = false
            }
            self.resize(edge: edge, anchor: anchor, visibleFrame: visibleFrame)
        }
    }

    /// 中身の数が分かってから、その高さに合わせ直す。
    private func resize(edge: WorkspaceScreenEdge, anchor: CGRect, visibleFrame: CGRect) {
        let height = EdgeTabPlacement.popoverHeight(
            rowCount: items.count,
            rowHeight: Self.rowHeight,
            chrome: Self.chromeHeight + previewHeightConstraint.constant
        )
        panel.setFrame(
            EdgeTabPlacement.popoverFrame(
                anchor: anchor,
                preferredHeight: height,
                edge: edge,
                visibleFrame: visibleFrame
            ),
            display: true,
            animate: false
        )
    }

    @objc private func openDirectory() {
        guard let directory else { return }
        onOpenDirectory?(directory)
    }

    /// フォルダはこのパネルの中で降り、ファイルは関連アプリで開く。
    ///
    /// フォルダのダブルクリックでFinderAIのウインドウへ飛ばさないのは、そうすると
    /// 「端から覗く」流れが毎回ウインドウを前面に引きずり出す操作に変わるから。
    /// ウインドウで開きたいときはヘッダーの「開く」がある。
    @objc private func activateSelectedRow() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        if item.isDirectory {
            descend(into: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - ファイル操作

    /// 端から覗いた一覧でも、ウインドウでできることはできる。
    ///
    /// 実処理はすべて`WorkspaceFileService`とクリップボードに委ねてある。ここに
    /// 別の実装を置くと、同名の拒否やゴミ箱の扱いがウインドウ側とずれていく。
    private func makeItemMenu(for item: WorkspaceItem?) -> NSMenu {
        let menu = NSMenu(title: item?.name ?? directory?.lastPathComponent ?? "")
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled
            menu.addItem(entry)
        }

        if item != nil {
            add("開く", #selector(openContextItem))
            add("クイックルック", #selector(quickLookContextItem))
            menu.addItem(.separator())
            add("情報を見る", #selector(showInfoForContextItem))
            add("Finderで表示", #selector(revealContextItemInFinder))
            menu.addItem(.separator())
            add("コピー", #selector(copyContextItem))
            add("パス名をコピー", #selector(copyContextItemPath))
        }
        add("ペースト", #selector(pasteIntoCurrentDirectory), enabled: canPaste)
        if item != nil {
            add("複製", #selector(duplicateContextItem))
            add("エイリアスを作成", #selector(makeAliasForContextItem))
            add("圧縮", #selector(compressContextItem))
        }
        menu.addItem(.separator())
        if item != nil {
            add("名前を変更…", #selector(renameContextItem))
        }
        add("新規フォルダ", #selector(createFolderHere))
        if item != nil {
            menu.addItem(.separator())
            add("ゴミ箱に入れる", #selector(trashContextItem))
        }
        return menu
    }

    private var canPaste: Bool {
        guard let directory else { return false }
        return clipboard.canPaste(into: directory)
    }

    /// 右クリックされた行。クリックが行の外なら選択中のもの。
    private var contextItem: WorkspaceItem? {
        if preferences.edgeTabsUsesIconView { return selectedItem }
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard items.indices.contains(row) else { return nil }
        return items[row]
    }

    @objc private func openContextItem() {
        guard let item = contextItem else { return }
        if item.isDirectory {
            descend(into: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// スペースキーとメニューから出すQuick Look。
    ///
    /// レスポンダチェーン経由の自動制御には乗せず、データ元を直に差してパネルを
    /// 出す。ボーダーレスのパネルはチェーンの都合でプレビューの制御権を取り損ねる
    /// ことがあり、押しても何も起きない形で失敗するため。
    @objc private func quickLookContextItem() {
        guard let item = contextItem else { return }
        guard let preview = QLPreviewPanel.shared() else { return }
        if preview.isVisible, quickLookURLs.first as URL? == item.url {
            preview.orderOut(nil)
            return
        }
        quickLookURLs = [item.url as NSURL]
        preview.dataSource = self
        preview.reloadData()
        preview.makeKeyAndOrderFront(nil)
    }

    @objc private func showInfoForContextItem() {
        guard let item = contextItem else { return }
        WorkspaceInfoWindowController.show(for: item.url)
    }

    @objc private func revealContextItemInFinder() {
        guard let item = contextItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func copyContextItem() {
        guard let item = contextItem else { return }
        clipboard.write([item.url], operation: .copy)
    }

    @objc private func copyContextItemPath() {
        guard let item = contextItem else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.url.path(percentEncoded: false), forType: .string)
    }

    @objc private func pasteIntoCurrentDirectory() {
        guard let directory, let contents = clipboard.read() else { return }
        let copies = contents.operation == .copy
        do {
            let moved = try fileService.transfer(contents.urls, to: directory, copy: copies)
            if !copies {
                // カットのペーストは1回きり。移動後の場所をボードに書き戻して、
                // 二度目のペーストが消えたものを探しにいかないようにする。
                clipboard.finishMove(with: moved.map(\.destination))
            }
            load(directory: directory, edge: edge, anchor: anchor, visibleFrame: visibleFrame)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = copies ? "コピーできません" : "移動できません"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func duplicateContextItem() {
        guard let item = contextItem else { return }
        run { _ = try self.fileService.duplicate(item.url) }
    }

    @objc private func makeAliasForContextItem() {
        guard let item = contextItem else { return }
        run { _ = try self.fileService.makeAlias(for: item.url) }
    }

    @objc private func compressContextItem() {
        guard let item = contextItem, let directory else { return }
        run { _ = try WorkspaceArchiver.archive([item.url], in: directory) }
    }

    @objc private func createFolderHere() {
        guard let directory else { return }
        run { _ = try self.fileService.createFolder(in: directory) }
    }

    /// 改名はシートではなくアラートで訊く。ボーダーレスのパネルにシートは掛けられず、
    /// 一覧の行を編集可能にするとパネルの外へフォーカスが逃げる。
    @objc private func renameContextItem() {
        guard let item = contextItem else { return }
        let alert = NSAlert()
        alert.messageText = "名前を変更"
        alert.informativeText = item.name
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposed = field.stringValue
        run { _ = try self.fileService.rename(item.url, to: proposed) }
    }

    @objc private func trashContextItem() {
        guard let item = contextItem else { return }
        run { try self.fileService.moveToTrash([item.url]) }
    }

    /// 失敗したら理由を出し、成功したら一覧を読み直す。
    private func run(_ work: () throws -> Void) {
        do {
            try work()
            if let directory {
                load(directory: directory, edge: edge, anchor: anchor, visibleFrame: visibleFrame)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "操作できません"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func performTransfer(_ sources: [URL], to destination: URL, copy: Bool) -> Bool {
        do {
            _ = try fileService.transfer(sources, to: destination, copy: copy)
            if let directory { load(directory: directory, edge: edge, anchor: anchor, visibleFrame: visibleFrame) }
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

extension EdgeTabPopoverController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    // MARK: - 取り出す

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(row) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: items[row].url)
    }

    // MARK: - 放り込む

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        guard !sources.isEmpty else { return [] }
        // 落とし先はAppKitの提案ではなく、カーソルの下にある行から決める。行の上に
        // フォルダがあればその中へ、それ以外は今のフォルダへ。細いポップアップで
        // 「行の上」と「行と行のあいだ」を撃ち分けさせない。
        let point = tableView.convert(info.draggingLocation, from: nil)
        let hovered = tableView.row(at: point)
        let landsOnFolder = items.indices.contains(hovered) && items[hovered].isDirectory
        let destination = landsOnFolder ? items[hovered].url : directory
        guard let destination else { return [] }
        let proposed = WorkspaceDragDrop.operation(
            allowedOperations: info.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        guard WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: proposed
        ) else { return [] }
        if landsOnFolder {
            tableView.setDropRow(hovered, dropOperation: .on)
        } else {
            // -1 は「テーブル全体」＝このフォルダ自身。
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return proposed
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        // `validateDrop`が寄せた行をそのまま使う。`.on`ならその行のフォルダ、
        // それ以外は今のフォルダ。
        let destination = operation == .on && items.indices.contains(row) && items[row].isDirectory
            ? items[row].url
            : directory
        guard !sources.isEmpty, let destination else { return false }
        let proposed = WorkspaceDragDrop.operation(
            allowedOperations: info.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        guard WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: proposed
        ) else { return false }
        return performTransfer(sources, to: destination, copy: proposed == .copy)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let identifier = NSUserInterfaceItemIdentifier("EdgeTabRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)
        cell.textField?.stringValue = item.name
        cell.textField?.textColor = IntegratedPanelTheme.text
        cell.imageView?.image = WorkspaceIconProvider.shared.quickIcon(for: item)
        WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak tableView] image in
            // 解決が返るころには別のフォルダを映しているかもしれないので、行が
            // まだ同じものを指しているときだけ差し替える。
            guard let tableView,
                  let current = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NSTableCellView,
                  current === cell else { return }
            cell.imageView?.image = image
        }
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        [icon, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview($0)
        }
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

// 本体のブラウザと同じ扱い。プレビューパネルはmain actorからしか触らないので、
// 実行時チェックに委ねる。
extension EdgeTabPopoverController: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs.indices.contains(index) ? quickLookURLs[index] : nil
    }
}

// MARK: - アイコン表示

extension EdgeTabPopoverController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: EdgeTabIconItem.identifier,
            for: indexPath
        )
        guard let cell = item as? EdgeTabIconItem, items.indices.contains(indexPath.item) else {
            return item
        }
        cell.configure(with: items[indexPath.item])
        return cell
    }

    /// ダブルクリックはコレクションビューには無いので、選択のたびにクリック数を見る。
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updatePreview()
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .leftMouseDown,
              event.clickCount == 2,
              let index = indexPaths.first?.item,
              items.indices.contains(index) else { return }
        let item = items[index]
        if item.isDirectory {
            descend(into: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(indexPath.item) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: items[indexPath.item].url)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let sources = WorkspaceDragDrop.fileURLs(from: draggingInfo.draggingPasteboard)
        guard !sources.isEmpty, let destination = directory else { return [] }
        let proposed = WorkspaceDragDrop.operation(
            allowedOperations: draggingInfo.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        guard WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: proposed
        ) else { return [] }
        return proposed
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let sources = WorkspaceDragDrop.fileURLs(from: draggingInfo.draggingPasteboard)
        guard !sources.isEmpty, let destination = directory else { return false }
        let proposed = WorkspaceDragDrop.operation(
            allowedOperations: draggingInfo.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        guard WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: proposed
        ) else { return false }
        return performTransfer(sources, to: destination, copy: proposed == .copy)
    }
}

/// アイコン表示側の右クリック。
@MainActor
private final class EdgeTabCollectionView: NSCollectionView {
    var onContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point), !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return onContextMenu?() ?? super.menu(for: event)
    }
}

/// アイコン表示の1マス。
@MainActor
final class EdgeTabIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("EdgeTabIconItem")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected
            ? IntegratedPanelTheme.activeTab.cgColor
            : NSColor.clear.cgColor
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 6
        view = root

        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 10)
        label.textColor = IntegratedPanelTheme.text
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true

        [icon, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3)
        ])
    }

    func configure(with item: WorkspaceItem) {
        loadViewIfNeeded()
        label.stringValue = item.name
        view.toolTip = item.name
        icon.image = WorkspaceIconProvider.shared.quickIcon(for: item)
        let path = item.url.path
        WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak self] image in
            // 使い回されたマスが別のファイルを映しているかもしれない。
            guard let self, self.view.toolTip == item.name, self.currentPath == path else { return }
            self.icon.image = image
        }
        currentPath = path
    }

    private var currentPath: String?
}

/// ドラッグの開始と終了を知らせるテーブル。
///
/// ドラッグ中はカーソルがポップアップの外へ出るが、そこで畳まれると掴んだものを
/// どこにも置けない。`mouseExited`とドラッグを区別するためにセッションの生死を
/// 拾う。
@MainActor
private final class EdgeTabTableView: NSTableView {
    var onDragSessionChanged: ((Bool) -> Void)?
    /// 右クリックのたびに、そのとき選ばれているものに合わせて作り直す。
    var onContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return onContextMenu?() ?? super.menu(for: event)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint
    ) {
        super.draggingSession(session, willBeginAt: screenPoint)
        onDragSessionChanged?(true)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        onDragSessionChanged?(false)
    }
}

/// ポップアップ全体のホバーを1か所で拾うための器。
///
/// 背景はレイヤーの`backgroundColor`ではなく`draw`で塗る。ボーダーレスのパネルの
/// `contentView`にすると、こちらで設定したレイヤーの背景が効かず、中身のない
/// 透明な板になった（実機で踏んだ）。縁のタブが同じ理由で`draw`で塗っている。
@MainActor
private final class HoverReportingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    /// タブが貼り付いている側の角は落とす。そこは帯と接する辺で、丸めると
    /// 浮いて見える——左右どちらの縁でも、帯から生えてきたように繋げたい。
    var edge: WorkspaceScreenEdge = .right {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = 10
        let path = NSBezierPath()
        switch edge {
        case .right:
            // 右の縁に貼り付く＝ポップアップの右辺が帯側。
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
                radius: radius, startAngle: 270, endAngle: 180, clockwise: true
            )
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                radius: radius, startAngle: 180, endAngle: 90, clockwise: true
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        case .left:
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
                radius: radius, startAngle: 270, endAngle: 0, clockwise: false
            )
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                radius: radius, startAngle: 0, endAngle: 90, clockwise: false
            )
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.close()
        IntegratedPanelTheme.background.setFill()
        path.fill()
        IntegratedPanelTheme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
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
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
