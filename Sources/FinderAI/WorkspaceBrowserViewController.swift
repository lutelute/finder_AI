import AppKit
import FinderAICore
import QuickLookUI

@MainActor
private final class WorkspaceNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = FinderInlineRenameField()
    private let cloudView = NSImageView()
    /// 他のグループにも並んでいることの印。見出しと同じ印を10ptで並べる。
    private let otherChips = NSStackView()
    private let overflowLabel = NSTextField(labelWithString: "")
    private lazy var indent = iconView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: 6
    )
    /// クラウドの印が無い行で幅を残さないための可変幅。`isHidden`にしても
    /// 固定幅の制約は効き続けるので、名前の後ろに常に24ptの空白が空いていた。
    private lazy var cloudWidth = cloudView.widthAnchor.constraint(equalToConstant: 14)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceNameCell")
        iconView.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = IntegratedPanelTheme.text
        cloudView.imageScaling = .scaleProportionallyDown
        cloudView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        otherChips.orientation = .horizontal
        otherChips.spacing = 3
        otherChips.alignment = .centerY
        // 「↳ グループA, グループB」という字だった。矢印は「移動先」を連想させるのに、
        // 実際の意味は「同じものが別の見出しの下にも出ている」で、記号が合っていない。
        // 見出しと同じ印を小さく並べれば、どの束にも居るかが一目で分かる。
        overflowLabel.font = .systemFont(ofSize: 10)
        overflowLabel.textColor = IntegratedPanelTheme.secondaryText
        [iconView, label, cloudView, otherChips, overflowLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        // 名前が長ければ先に印のほうが削れる。どのグループにも居ることより、
        // 何という名前かのほうが先に要る。
        [otherChips, overflowLabel].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // The badge sits after the name and is hugged tight, so a long name
        // truncates instead of pushing the badge out of the cell.
        cloudView.setContentHuggingPriority(.required, for: .horizontal)
        cloudView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            indent,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            cloudView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudWidth,
            otherChips.leadingAnchor.constraint(equalTo: cloudView.trailingAnchor, constant: 6),
            otherChips.centerYAnchor.constraint(equalTo: centerYAnchor),
            otherChips.heightAnchor.constraint(equalToConstant: 7),
            overflowLabel.leadingAnchor.constraint(equalTo: otherChips.trailingAnchor, constant: 3),
            overflowLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            overflowLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        imageView = iconView
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Which file this cell currently shows. The async icon resolution checks
    /// it before applying, so a reused cell never receives a stale icon.
    var representedURL: URL?

    func configure(
        name: String,
        image: NSImage,
        cloud: WorkspaceCloudStatus,
        otherGroups: [String] = [],
        otherColors: [NSColor] = [],
        indent: CGFloat = 6
    ) {
        label.show(name)
        iconView.image = image
        applyCloud(cloud)
        self.indent.constant = indent

        otherChips.arrangedSubviews.forEach {
            otherChips.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        // 三つまで。四つ以上は数で出す — 印が並びすぎると名前より目立つ。
        let shown = Array(zip(otherGroups, otherColors).prefix(3))
        for (title, color) in shown {
            let chip = WorkspaceGroupChipView()
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.show(initial: WorkspaceGroupPalette.initial(for: title), fill: color)
            NSLayoutConstraint.activate([
                chip.widthAnchor.constraint(equalToConstant: 7),
                chip.heightAnchor.constraint(equalToConstant: 7)
            ])
            otherChips.addArrangedSubview(chip)
        }
        let hidden = max(otherGroups.count - shown.count, 0)
        overflowLabel.isHidden = hidden == 0
        overflowLabel.stringValue = hidden == 0 ? "" : "+\(hidden)"
        toolTip = otherGroups.isEmpty
            ? nil
            : "同じものが「\(otherGroups.joined(separator: "」「"))」にも並んでいます"
    }

    func containsName(at point: NSPoint) -> Bool {
        label.frame.insetBy(dx: -3, dy: -2).contains(point)
    }

    func beginRenaming(
        name: String,
        isDirectory: Bool,
        onCommit: @escaping (String) -> Void
    ) {
        label.beginEditing(name: name, isDirectory: isDirectory, onCommit: onCommit)
    }

    func updateIcon(_ image: NSImage) {
        iconView.image = image
    }

    private func applyCloud(_ status: WorkspaceCloudStatus) {
        switch status {
        case .none:
            cloudView.isHidden = true
            cloudView.image = nil
            cloudWidth.constant = 0
            return
        case .notDownloaded:
            cloudView.isHidden = false
            cloudView.image = NSImage(
                systemSymbolName: "icloud.and.arrow.down",
                accessibilityDescription: "未ダウンロード"
            )
            cloudView.contentTintColor = IntegratedPanelTheme.secondaryText
            cloudView.toolTip = "このMacにダウンロードされていません"
        case .downloading:
            cloudView.isHidden = false
            cloudView.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "ダウンロード中"
            )
            cloudView.contentTintColor = IntegratedPanelTheme.accent
            cloudView.toolTip = "ダウンロード中"
        case .uploading:
            cloudView.isHidden = false
            cloudView.image = NSImage(
                systemSymbolName: "arrow.up.circle",
                accessibilityDescription: "アップロード中"
            )
            cloudView.contentTintColor = IntegratedPanelTheme.accent
            cloudView.toolTip = "アップロード中"
        }
        cloudWidth.constant = 14
    }
}

@MainActor
private final class WorkspaceSidebarCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceSidebarCell")
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = IntegratedPanelTheme.text
        // 長い名前は中ほどを省く。省かずに全部出していたので、読むにはサイドバーを
        // 広げるしかなく、「幅が要る」のではなく「省略していない」のが原因だった。
        // 末尾ではなく中ほどを落とすのは、日付や連番で見分けているものがあるから。
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.contentTintColor = IntegratedPanelTheme.secondaryText
        [iconView, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        imageView = iconView
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, symbol: String) {
        label.stringValue = title
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
}

@MainActor
private final class WorkspaceSidebarHeaderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceSidebarHeader")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = IntegratedPanelTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.stringValue = title.uppercased()
    }
}

/// 一覧の左端に立てるレールの寸法。見出しと行で同じ位置に立てるためにここに集める。
///
/// 見出しにしかグループの色が無いと、116個の未分類をスクロールしている間じゅう
/// 自分がどの束にいるか分からない。行にも引けば、見出しが画面の外へ出ても残る。
/// 一覧の見出しと行の左端に立てるレール。地図の右一覧でも同じ位置に立てるので共有する。
enum WorkspaceGroupRail {
    static let width: CGFloat = 3
    static let leading: CGFloat = 8
    /// 入れ子一段ぶんの間隔。親のレールを残したまま、自分のレールを右へずらす。
    static let step: CGFloat = 14

    static func x(atLevel level: Int) -> CGFloat {
        leading + CGFloat(min(level, 4)) * step
    }

    /// レール一本の矩形。`slice`/`total`で縦に割る — 複数のグループに属する行は
    /// 棒が上下に割れ、「割れている＝複数所属」が色を読まずに形で分かる。
    static func rect(in bounds: NSRect, level: Int, slice: Int = 0, of total: Int = 1) -> NSRect {
        let height = bounds.height / CGFloat(max(total, 1))
        return NSRect(
            x: x(atLevel: level),
            y: bounds.minY + height * CGFloat(slice),
            width: width,
            height: height
        )
    }

    static func fill(_ rect: NSRect) {
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

/// 一覧のなかのグループの見出し。
///
/// 行ではなく**面**にしてある。以前は件数の右から右端まで1ptの罫線を引いていたが、
/// 5列の表の上を横断する水平線は列の区切り線と同じ語彙になり、束をまとめる記号ではなく
/// 行を切る記号に見えた。行高も26pt対27ptで、本文との段差がほとんど無かった。
///
/// 帯の地はグループの色ではなく中立にする。6つの束が全部違う彩度で光ると一覧が縞になり、
/// どれを見ているのか分からなくなるし、黄土色の帯と青の帯では見かけの強さが倍違って、
/// 束の重要度が色で決まってしまう。色は印とレールという小さくて濃い面に集める。
@MainActor
final class WorkspaceGroupHeaderView: NSTableCellView {
    private let chevron = NSImageView()
    private let chip = WorkspaceGroupChipView()
    private lazy var indent = chevron.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: 20
    )
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    /// 先頭が最上位の親で、末尾が自分。`draw(_:)`から読むので持っておく。
    private var railColors: [NSColor] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WorkspaceGroupHeader")
        chevron.imageScaling = .scaleProportionallyDown
        chevron.contentTintColor = IntegratedPanelTheme.secondaryText
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = IntegratedPanelTheme.text
        label.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 10.5)
        countLabel.textColor = IntegratedPanelTheme.secondaryText

        [chevron, chip, label, countLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            indent,
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chip.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 8),
            chip.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        // 帯を不透明にするのが肝心。`floatsGroupRows`で見出しは上端に貼り付くのに、
        // 背景を塗っていなかったので、下を流れる行が見出しに重なって読めなかった。
        IntegratedPanelTheme.header.setFill()
        bounds.fill()
        // 上端の1本だけ。束の「始まり」を示す線で、行を切る線ではない。
        IntegratedPanelTheme.border.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        for (level, color) in railColors.enumerated() {
            // 親のレールも残す。自分の色だけだと、入れ子なのか並列なのか読めない。
            let isSelf = level == railColors.count - 1
            color.withAlphaComponent(isSelf ? 0.9 : 0.35).setFill()
            WorkspaceGroupRail.fill(
                WorkspaceGroupRail.rect(in: bounds.insetBy(dx: 0, dy: 3), level: level)
            )
        }
    }

    /// - Parameter color: グループの色。`nil`は未分類 — 空の破線の印がそれを示す。
    /// - Parameter isCollapsed: 畳んでいるか。三角の向きで示す。
    /// - Parameter depth: 入れ子の深さ。`A ∈ B` の A は 1 で、その分だけ右へ寄せる。
    /// - Parameter ancestorColors: 親のグループの色。近い親が末尾。
    /// - Parameter inChildren: 子のグループの下に居る数。直下に何も入れていない親は
    ///   数が0になり、無いものと読める。「0 (+11)」と添えて、中は空でないと示す。
    func configure(
        title: String,
        count: Int,
        color: NSColor?,
        isCollapsed: Bool,
        depth: Int = 0,
        ancestorColors: [NSColor] = [],
        inChildren: Int = 0
    ) {
        let level = min(depth, 4)
        railColors = color.map { ancestorColors.suffix(level) + [$0] } ?? []
        // 印と文字はレールの右から始める。レールの本数だけ右へ寄る。
        indent.constant = WorkspaceGroupRail.x(atLevel: level) + WorkspaceGroupRail.width + 9
        chip.show(initial: WorkspaceGroupPalette.initial(for: title), fill: color)
        label.stringValue = title
        countLabel.stringValue = inChildren > 0 ? "\(count) (+\(inChildren))" : "\(count)"
        chevron.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: isCollapsed ? "開く" : "畳む"
        )
        toolTip = isCollapsed ? "押して開く" : "押して畳む"
        // 未分類も本文と同じ文字色で出す。116項目を抱えるいちばん大きな束を
        // いちばん弱く描くのは、重要度と見た目が逆立ちしている。
        label.textColor = IntegratedPanelTheme.text
        needsDisplay = true
    }
}

/// 一覧の一行。左端に、その行が属する束のレールを引くためだけの行ビュー。
///
/// レールを**セル**ではなく**行**に描くのは、名前列の幅が動くから。セルに描くと
/// 列幅を変えるたびにレールの位置が動く。
@MainActor
final class WorkspaceGroupedRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("WorkspaceGroupedRow")

    /// 親の色（近い親が末尾）と、自分の束の色。複数の束にいる行は`own`が複数入る。
    var ancestorColors: [NSColor] = []
    var ownColors: [NSColor] = []

    func show(ancestors: [NSColor], own: [NSColor]) {
        guard ancestors != ancestorColors || own != ownColors else { return }
        ancestorColors = ancestors
        ownColors = own
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        for (level, color) in ancestorColors.enumerated() {
            color.withAlphaComponent(0.35).setFill()
            WorkspaceGroupRail.fill(WorkspaceGroupRail.rect(in: bounds, level: level))
        }
        // 複数の束にいる行はレールを縦に割って全部の色を出す。
        for (index, color) in ownColors.enumerated() {
            color.withAlphaComponent(0.9).setFill()
            WorkspaceGroupRail.fill(WorkspaceGroupRail.rect(
                in: bounds,
                level: ancestorColors.count,
                slice: index,
                of: ownColors.count
            ))
        }
    }
}

/// Table subclass that routes the keys a file list is expected to answer.
/// `NSTableView` has no built-in notion of "open the selection", so Return and
/// Space have to be claimed here rather than left to the responder chain.
@MainActor
private final class WorkspaceFileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onRenameRequested: ((Int) -> Void)?
    /// グループの見出しを押したとき。行は選べないので、クリックはここで拾う。
    var onHeaderClicked: ((Int) -> Void)?
    /// グループの見出しを右クリックしたときのメニュー。行が選べないので、
    /// ふつうのコンテキストメニューの経路には乗らない。
    var groupMenuProvider: ((Int) -> NSMenu?)?
    /// その行がグループの見出しかどうか。押されたときの振り分けに使う。
    var isHeaderRow: ((Int) -> Bool)?
    private let renameScheduler = FinderLikeRenameScheduler()
    private var dragOccurred = false

    override func keyDown(with event: NSEvent) {
        renameScheduler.cancel()
        switch FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
        case .rename:
            guard selectedRowIndexes.count == 1,
                  let row = selectedRowIndexes.first else {
                NSSound.beep()
                return
            }
            onRenameRequested?(row)
        case .quickLook:
            onQuickLook?()
        case .forwardToAppKit:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        renameScheduler.cancel()
        dragOccurred = false
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // 見出しは選べない行なので、クリックが選択にならない。畳む操作をここで拾う。
        if row >= 0, isHeaderRow?(row) == true {
            onHeaderClicked?(row)
            return
        }
        let column = self.column(at: point)
        let wasSelected = row >= 0 && selectedRowIndexes.contains(row)
        let nameCell = row >= 0 && column >= 0
            ? nameCell(atRow: row, column: column)
            : nil
        let hitName = nameCell.map {
            $0.containsName(at: $0.convert(point, from: self))
        } ?? false
        let shouldSchedule = FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: wasSelected,
            selectionCount: selectedRowIndexes.count,
            clickCount: event.clickCount,
            modifierFlags: event.modifierFlags,
            hitName: hitName
        )

        super.mouseDown(with: event)
        guard !dragOccurred, shouldSchedule,
              selectedRowIndexes == IndexSet(integer: row) else { return }
        renameScheduler.schedule { [weak self] in
            guard let self,
                  self.selectedRowIndexes == IndexSet(integer: row) else { return }
            self.onRenameRequested?(row)
        }
    }

    /// グループの見出しには専用のメニューを出す。行が選べないので、ふつうのファイル操作の
    /// メニューはどれも当てはまらない（選択がないので全部灰色になる）。
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, isHeaderRow?(row) == true {
            return groupMenuProvider?(row)
        }
        return super.menu(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dragOccurred = true
        renameScheduler.cancel()
        super.mouseDragged(with: event)
    }

    func draggingSessionWillBegin() {
        dragOccurred = true
        renameScheduler.cancel()
    }

    private func nameCell(atRow row: Int, column: Int) -> WorkspaceNameCellView? {
        guard tableColumns.indices.contains(column),
              tableColumns[column].identifier.rawValue == "name" else { return nil }
        return view(atColumn: column, row: row, makeIfNecessary: false)
            as? WorkspaceNameCellView
    }
}

@MainActor
private final class WorkspaceGalleryCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onRenameRequested: ((IndexPath) -> Void)?
    private let renameScheduler = FinderLikeRenameScheduler()
    private var dragOccurred = false

    override func keyDown(with event: NSEvent) {
        renameScheduler.cancel()
        switch FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) {
        case .rename:
            guard selectionIndexPaths.count == 1,
                  let indexPath = selectionIndexPaths.first else {
                NSSound.beep()
                return
            }
            onRenameRequested?(indexPath)
        case .quickLook:
            onQuickLook?()
        case .forwardToAppKit:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        renameScheduler.cancel()
        dragOccurred = false
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        let wasSelected = indexPath.map(selectionIndexPaths.contains) ?? false
        let hitName = indexPath.flatMap { item(at: $0) as? WorkspaceGalleryItem }
            .map { $0.containsName(at: $0.view.convert(point, from: self)) } ?? false
        let shouldSchedule = FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: wasSelected,
            selectionCount: selectionIndexPaths.count,
            clickCount: event.clickCount,
            modifierFlags: event.modifierFlags,
            hitName: hitName
        )
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            renameScheduler.cancel()
            onOpen?()
        } else if !dragOccurred, shouldSchedule, let indexPath,
                  selectionIndexPaths == [indexPath] {
            renameScheduler.schedule { [weak self] in
                guard let self, self.selectionIndexPaths == [indexPath] else { return }
                self.onRenameRequested?(indexPath)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragOccurred = true
        renameScheduler.cancel()
        super.mouseDragged(with: event)
    }

    func draggingSessionWillBegin() {
        dragOccurred = true
        renameScheduler.cancel()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return super.menu(for: event)
    }
}

@MainActor
private final class WorkspaceGalleryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceGalleryItem")
    private let icon = NSImageView()
    private let titleLabel = FinderInlineRenameField()
    private let detail = NSTextField(labelWithString: "")
    var representedURL: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detail.alignment = .center
        detail.font = .systemFont(ofSize: 9.5)
        detail.textColor = IntegratedPanelTheme.secondaryText
        detail.lineBreakMode = .byTruncatingMiddle
        [icon, titleLabel, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 60),
            icon.heightAnchor.constraint(equalToConstant: 60),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            detail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5)
        ])
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).cgColor
                : NSColor.clear.cgColor
        }
    }

    func configure(with item: WorkspaceItem) {
        representedURL = item.url
        titleLabel.show(item.name)
        titleLabel.toolTip = item.relativePath ?? item.name
        detail.stringValue = item.relativePath.map {
            ($0 as NSString).deletingLastPathComponent
        }.flatMap { $0.isEmpty ? nil : $0 } ?? item.typeDescription ?? ""
        detail.toolTip = item.relativePath
        icon.image = WorkspaceIconProvider.shared.quickIcon(for: item)
        WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak self] image in
            guard let self, self.representedURL == item.url else { return }
            self.icon.image = image
        }
    }

    func containsName(at point: NSPoint) -> Bool {
        titleLabel.frame.insetBy(dx: -3, dy: -2).contains(point)
    }

    func beginRenaming(
        name: String,
        isDirectory: Bool,
        onCommit: @escaping (String) -> Void
    ) {
        titleLabel.beginEditing(name: name, isDirectory: isDirectory, onCommit: onCommit)
    }
}

@MainActor
final class WorkspaceBrowserViewController: NSViewController {
    var onDirectoryChange: ((URL) -> Void)?
    var onToggleTerminal: (() -> Void)?
    /// Fires when this pane takes focus, so the window can follow it.
    var onBecameActive: (() -> Void)?

    /// A flattened section list: `NSTableView` has no sections, so headers and
    /// items share one row space and `isGroupRow` tells them apart.
    private enum SidebarRow: Equatable {
        case header(String)
        case item(WorkspaceSidebarModel.Item)
    }

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let kind = NSUserInterfaceItemIdentifier("kind")
        /// 所属するグループ。並べ替えの軸にもなる。
        static let groups = NSUserInterfaceItemIdentifier("groups")
    }

    private var navigator: WorkspaceNavigator
    private let fileService = WorkspaceFileService()
    private let fileClipboard: WorkspaceFileClipboard
    private let preferences: WorkspacePreferences
    private let themePainter = ThemedLayerPainter()
    private let watcher = DirectoryWatcher()
    private var allItems: [WorkspaceItem] = []
    private var displayedItems: [WorkspaceItem] = [] {
        didSet { rebuildFileRows() }
    }

    /// listビューの行。見出しが挟まるので行番号と`displayedItems`の添字は一致しない。
    /// グループの定義が無いフォルダでは見出しが0本になり、行番号＝添字に戻る。
    private enum FileRow: Equatable {
        /// グループの名前。`nil`はどのグループにも属さないものの見出しで、「未分類」という名前の
        /// グループとは別物。同じ文字列で持つと、ユーザーが「未分類」というグループを作った瞬間に
        /// 二つが同じ見出しになる。
        case header(String?, depth: Int)
        /// `displayedItems`の添字と、この行が居るグループ**以外**の所属先。複数のグループに属する
        /// 項目は同じ添字を複数の行が指すので、行ごとに「他はどこか」が変わる。
        case item(index: Int, otherGroups: [String])
    }

    private var fileRows: [FileRow] = []
    /// その行が居る束。見出しの行と、束に入っていない行は`nil`。`fileRows`と同じ長さ。
    private struct SectionPlacement: Equatable {
        let name: String
        let depth: Int
    }

    private var rowSections: [SectionPlacement?] = []
    /// ⌘Gで地図から戻る先。地図しか見ていなければ一覧へ。
    private var modeBeforeMap: WorkspaceViewMode = .list
    private let groupingToggle = NSButton()
    private let ungroupedOnlyToggle = NSButton()
    private let groupedOnlyToggle = NSButton()
    private var addToGroupItem = NSMenuItem()
    private var removeFromGroupItem = NSMenuItem()
    private var itemGroups: WorkspaceItemGroups?
    /// このフォルダに実在する名前（隠しファイルも含む）。グループの「見つからない」判定に使う。
    /// 一覧に見えているものだけで判定すると、隠し表示をオフにしただけで
    /// 隠しフォルダが迷子に化ける。
    private var presentNames: Set<String> = []
    /// 定義が読めなかったときの理由。見出しは出さないが、黙って無かったことにはしない。
    private var itemGroupsError: String?
    private static let ungroupedTitle = "未分類"
    /// 右クリックされたグループの名前。見出し用のメニューが対象を知るために置く。
    private var contextGroupName: String?
    /// 畳んであるグループ。見出しだけ残して中身を隠す。
    ///
    /// グループが増えると一覧が縦に長くなる。いま見ていないグループを畳めれば、
    /// 見たいグループだけを目の前に置ける。フォルダを移っても覚えておく。
    /// 畳んだ束。地図の右の一覧と同じものを見る（表示を替えても畳み方が変わらない）。
    let collapsedGroups = WorkspaceCollapsedGroups()
    /// 外での改名を追う見張り。フォルダごとに覚え直す。
    private var renameTracker = WorkspaceRenameTracker()
    private var listingTask: Task<Void, Never>?
    private var cloudStatusTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var recursiveSearchTask: Task<Void, Never>?
    private var recursiveSearchGeneration: UInt = 0
    private var recursiveSearchIsTruncated = false
    private var recursiveSearchErrorShown = false
    private var pendingSelectionURL: URL?
    private var sortIdentifier = Column.name
    private var sortAscending = true
    private var quickLookURLs: [URL] = []
    private var pathComponentURLs: [URL] = []
    private var openWithItem = NSMenuItem()
    private var shareItem = NSMenuItem()
    private var openWithURL: URL?
    private var shareURLs: [URL] = []

    private var sidebarContainer = NSView()
    private var sidebarRows: [SidebarRow] = []
    private var finderFavorites: [URL] = []
    private var volumes: [URL] = []
    private var sidebarLoadTask: Task<Void, Never>?
    private nonisolated(unsafe) var volumeObservers: [any NSObjectProtocol] = []
    private nonisolated(unsafe) var focusObserver: (any NSObjectProtocol)?
    private var paneIsActive = true
    private let sidebarTable = NSTableView()
    private let fileTable = WorkspaceFileTableView()
    private let galleryView = WorkspaceGalleryCollectionView()
    private let pathField = NSTextField()
    private let fileArea = NSView()
    private let columnView = WorkspaceColumnView()
    private var listScrollView: NSScrollView?
    private var galleryScrollView: NSScrollView?
    private let mapView = WorkspaceMapView()
    private let ribbonPath = NSPathControl()
    private let listingErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton()
    private let showHiddenButton = NSButton()
    private let searchField = NSSearchField()
    private let searchScopeControl = NSSegmentedControl()
    private let viewModeControl = NSSegmentedControl()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let refreshButton = NSButton()
    /// この区画の明るさ。押すたびに システム → ライト → ダーク と巡る。
    private let appearanceButton = NSButton()
    /// 窓の色を選ぶボタン。メニューの奥にだけ置くと、在ることに気付かれない。
    private let tintButton = NSButton()
    /// いまこの窓に付いている色。ボタンの見た目と、開いたメニューの印に使う。
    private var currentTint: WorkspaceWindowTint?
    private let copyCDButton = NSButton()
    private let newFolderButton = NSButton()
    private let newGroupButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    /// サイドバーの幅を押し戻している最中か。再入を止めるための印。
    private var isClampingSidebar = false
    private let progress = NSProgressIndicator()
    private let splitView = NSSplitView()
    private var didSetInitialSidebarPosition = false

    /// The second pane of a split has no sidebar: one set of places is enough for
    /// a window, and at split width a pane is too narrow to spare 210pt for a
    /// duplicate. Left implicit it collapsed to nothing anyway, because the
    /// sidebar's initial position is only applied above 761pt.
    private let showsSidebar: Bool

    init(
        initialDirectory: URL,
        preferences: WorkspacePreferences = WorkspacePreferences(),
        fileClipboard: WorkspaceFileClipboard = .shared,
        showsSidebar: Bool = true
    ) {
        self.preferences = preferences
        self.fileClipboard = fileClipboard
        self.showsSidebar = showsSidebar
        navigator = WorkspaceNavigator(initialDirectory: initialDirectory)
        super.init(nibName: nil, bundle: nil)
        sortIdentifier = NSUserInterfaceItemIdentifier(preferences.sortColumn)
        sortAscending = preferences.sortAscending
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach(center.removeObserver)
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    var currentDirectory: URL { navigator.currentDirectory }
    var viewModeForTesting: WorkspaceViewMode { effectiveViewMode }
    var galleryIsVisibleForTesting: Bool { galleryScrollView?.isHidden == false }
    /// 一覧の表。落とす操作を、GUIを合成せずに同じ経路から叩くために出す。
    var fileTableForTesting: NSTableView { fileTable }
    var galleryViewForTesting: NSCollectionView { galleryView }
    var sidebarTableForTesting: NSTableView { sidebarTable }
    /// サイドバーで、そのフォルダが何行目か。
    func sidebarRowForTesting(named name: String) -> Int? {
        sidebarRows.indices.first { row in
            if case .item(let item) = sidebarRows[row] { return item.url.lastPathComponent == name }
            return false
        }
    }
    /// いま一覧に出ているもの。読み込みは非同期なので、待つ側が見るため。
    var displayedItemsForTesting: [WorkspaceItem] { displayedItems }
    /// その名前が何行目か。見出しがあると行番号と並びがずれる。
    func rowForTesting(named name: String) -> Int? {
        fileRows.indices.first { row in
            if case .item(let index, _) = fileRows[row] {
                return displayedItems.indices.contains(index) && displayedItems[index].name == name
            }
            return false
        }
    }

    private func configureAppearanceButton() {
        configureNavigationButton(
            appearanceButton,
            symbol: preferences.browserAppearance.symbolName,
            action: #selector(cycleAppearance),
            label: "ファイル一覧の明るさ"
        )
        refreshAppearanceButton()
    }

    /// 色を選んだ。掛けるのはウインドウの仕事なので、窓へ渡す。
    ///
    /// ペインは自分の額縁しか塗れないが、色はタイトルバーや反対側のペイン、
    /// ターミナルにも掛かる。ここで自分だけ塗ると、窓の中で色が食い違う。
    var onSelectTint: ((WorkspaceWindowTint?) -> Void)?

    private func configureTintButton() {
        configureNavigationButton(
            tintButton,
            symbol: "circle",
            action: #selector(showTintMenu),
            label: "このウインドウの色"
        )
        refreshTintButton()
    }

    private func refreshTintButton() {
        tintButton.image = WorkspaceWindowTintPalette.buttonImage(for: currentTint)
        // 名前は絵ではなくボタンに持たせる。`configureNavigationButton`は
        // 記号の`accessibilityDescription`を当てにしているが、ここは絵を
        // 差し替えるので、そのままだと読み上げから名前が消える。
        tintButton.setAccessibilityLabel("このウインドウの色")
        // 色そのものを見せる絵なので、ボタンの色付けに塗り潰させない。
        tintButton.contentTintColor = nil
        tintButton.toolTip = currentTint
            .map { "このウインドウの色：\($0.title)（押すと選び直せます）" }
            ?? "このウインドウの色：なし（押すと選べます）"
    }

    /// 押した場所から色の一覧を出す。
    ///
    /// 6色しかないので、階層を作らずその場に全部並べる。見本を添えるのは、
    /// 名前（藍鼠・苔・小豆…）だけでは何色か分からないため。
    @objc private func showTintMenu() {
        let menu = NSMenu(title: "このウインドウの色")
        let none = NSMenuItem(title: "色なし", action: #selector(pickTint(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = ""
        none.image = WorkspaceWindowTintPalette.buttonImage(for: nil)
        none.state = currentTint == nil ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())
        for tint in WorkspaceWindowTint.allCases {
            let item = NSMenuItem(title: tint.title, action: #selector(pickTint(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tint.rawValue
            item.image = WorkspaceWindowTintPalette.swatch(for: tint)
            item.state = currentTint == tint ? .on : .off
            menu.addItem(item)
        }
        // ボタンの真下に開く。押した指の位置と出る場所がずれると、
        // どのボタンのメニューなのか分からなくなる。
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: tintButton.bounds.height + 4),
            in: tintButton
        )
    }

    @objc private func pickTint(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        onSelectTint?(WorkspaceWindowTint.decoded(raw.isEmpty ? nil : raw))
    }

    private func refreshAppearanceButton() {
        let mode = preferences.browserAppearance
        appearanceButton.image = NSImage(
            systemSymbolName: mode.symbolName,
            accessibilityDescription: "ファイル一覧の明るさ"
        )
        appearanceButton.toolTip = "ファイル一覧の明るさ：\(mode.title)（押すと切り替え）"
    }

    @objc private func cycleAppearance() {
        preferences.browserAppearance = preferences.browserAppearance.next
        NotificationCenter.default.post(name: .workspaceAppearanceDidChange, object: nil)
    }

    /// 明るさを選び直したときに掛け替える。
    func applyAppearance() {
        refreshAppearanceButton()
        view.appearance = preferences.browserAppearance.nsAppearance
        themePainter.appearance = view.appearance
        themePainter.repaint()
    }

    /// このペインの額縁に、ウインドウの目印の色を掛ける。
    func applyTint(_ tint: WorkspaceWindowTint?) {
        currentTint = tint
        refreshTintButton()
        themePainter.tint = tint
        themePainter.repaint()
    }

    override func loadView() {
        let root = ThemedRootView()
        // ターミナルとは別に明るさを選べる。
        root.appearance = preferences.browserAppearance.nsAppearance
        themePainter.appearance = root.appearance
        root.onAppearanceChanged = { [weak self] in self?.themePainter.repaint() }
        themePainter.register(root) { IntegratedPanelTheme.background }
        view = root

        let split = splitView
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let browser = makeBrowser()
        // The sidebar view is always built — its table feeds the sidebar code
        // paths whether or not it is on screen — but only mounted when shown.
        sidebarContainer = makeSidebar()
        sidebarContainer.frame.size.width = 210
        if showsSidebar {
            split.addArrangedSubview(sidebarContainer)
            split.addArrangedSubview(browser)
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        } else {
            split.addArrangedSubview(browser)
        }

        configureContextMenu()
        // Draw the sidebar from what needs no I/O, then fill in Finder's
        // favourites and the mounted volumes once they arrive.
        rebuildSidebar()
        loadSidebarSources()
        updateNavigationUI()
        reloadContents()
        watchCurrentDirectory()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(firstResponderForCurrentMode)
        applyGroupColumnVisibility()
        observeVolumeChanges()
        observeFocusChanges()
    }

    /// Clicking anywhere in a pane makes it the active one. Watching the window's
    /// first responder covers every route in — the file list, the sidebar, the
    /// search field — without each of them having to report separately.
    private func observeFocusChanges() {
        guard focusObserver == nil, let window = view.window else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let responder = self.view.window?.firstResponder as? NSView,
                      responder.isDescendant(of: self.view) else { return }
                self.onBecameActive?()
            }
        }
    }

    /// Dims the pane that commands will not hit. With two identical panes there is
    /// otherwise nothing to say which is which.
    func setPaneActive(_ active: Bool) {
        paneIsActive = active
        view.alphaValue = active ? 1.0 : 0.72
    }

    /// Hidden while split: a pane is about half a window wide, and the sidebar's
    /// 160pt minimum only binds a drag — the initial layout squeezed it to an
    /// unreadable strip of truncated labels instead.
    func setSidebarVisible(_ visible: Bool) {
        guard showsSidebar, isViewLoaded else { return }
        let mounted = splitView.arrangedSubviews.first === sidebarContainer
        guard visible != mounted else { return }

        if visible {
            splitView.insertArrangedSubview(sidebarContainer, at: 0)
            splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            didSetInitialSidebarPosition = false
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(preferences.sidebarWidth, ofDividerAt: 0)
            didSetInitialSidebarPosition = true
        } else {
            splitView.removeArrangedSubview(sidebarContainer)
            sidebarContainer.removeFromSuperview()
        }
    }

    /// Plugging a drive in or ejecting one should be reflected without a restart.
    /// These post on `NSWorkspace`'s own centre, not the default one.
    private func observeVolumeChanges() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadSidebarSources() }
            }
            volumeObservers.append(observer)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutFileColumns()
        guard showsSidebar, !didSetInitialSidebarPosition else { return }
        // 761pt無いと初回配置をしていなかった。Terminalを右に開くと分割ビューは
        // それを下回り、**サイドバーが幅0のまま据え置かれて消える**。
        // 要るのは「窓が広いこと」ではなく「サイドバーと本文の両方が置けること」。
        let room = splitView.bounds.width
        guard room >= Self.minimumFileAreaWidth + 160 else { return }
        splitView.setPosition(
            min(preferences.sidebarWidth, room - Self.minimumFileAreaWidth),
            ofDividerAt: 0
        )
        didSetInitialSidebarPosition = true
    }

    /// ナビゲーションバーの高さ。上余白6 + ボタンと検索の行27 + 間隔5 +
    /// 住所欄24 + 下余白6。
    ///
    /// 幅を見て段数を変えるのはやめた。住所欄が自分の行を持ったことで、上の行に
    /// 残るのは幅の要らないものだけになり、二行で足りるようになった。段が窓幅で
    /// 増えたり減ったりすると、下にある中身の位置もそのたび動く。
    private static let barHeight: CGFloat = 68

    /// サイドバーを置いたあと、本文に最低これだけは残す。下回るならサイドバーを削る。
    private static let minimumFileAreaWidth: CGFloat = 320

    private func makeSidebar() -> NSView {
        let root = NSView()
        themePainter.register(root, role: .frame) { IntegratedPanelTheme.sidebar }

        let title = NSTextField(labelWithString: "WORKSPACE")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = IntegratedPanelTheme.secondaryText

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        // **切り抜き側も切る。** `NSScrollView.drawsBackground`を落としても
        // `NSClipView`は自分の背景を持っていて、そちらが不透明なまま残る。
        // 根に敷いた色（窓ごとの色を含む）がここで隠れて、一覧の地だけ
        // 素の灰になっていた。
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        sidebarTable.headerView = nil
        sidebarTable.backgroundColor = .clear
        // `.sourceList`はvibrancyの地を自分で描くので、下に敷いた色が透けない。
        // 行の見た目（角丸の選択・字下げ）は`.inset`でほぼ同じまま残る。
        sidebarTable.rowHeight = 23
        sidebarTable.style = .inset
        sidebarTable.delegate = self
        sidebarTable.dataSource = self
        sidebarTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar")))
        sidebarTable.registerForDraggedTypes([.fileURL])
        scroll.documentView = sidebarTable

        [title, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return root
    }

    private func makeBrowser() -> NSView {
        let root = NSView()
        themePainter.register(root) { IntegratedPanelTheme.background }
        let navigationBar = makeNavigationBar()
        let listScroll = makeFileTable()
        let galleryScroll = makeGalleryView()
        configureColumnView()

        // Both views occupy the same slot; only one is unhidden at a time.
        fileArea.addSubview(listScroll)
        fileArea.addSubview(columnView)
        fileArea.addSubview(galleryScroll)
        fileArea.addSubview(mapView)
        [listScroll, columnView, galleryScroll, mapView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: fileArea.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: fileArea.trailingAnchor),
                $0.topAnchor.constraint(equalTo: fileArea.topAnchor),
                $0.bottomAnchor.constraint(equalTo: fileArea.bottomAnchor)
            ])
        }
        listScrollView = listScroll
        galleryScrollView = galleryScroll
        configureListingErrorState()

        let ribbon = makeRibbon()
        [navigationBar, fileArea, ribbon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            navigationBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            navigationBar.topAnchor.constraint(equalTo: root.topAnchor),
            navigationBar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            fileArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fileArea.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            fileArea.bottomAnchor.constraint(equalTo: ribbon.topAnchor),
            ribbon.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ribbon.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ribbon.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ribbon.heightAnchor.constraint(equalToConstant: 26)
        ])
        applyViewMode()
        return root
    }

    private func makeGalleryView() -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 132, height: 112)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        galleryView.collectionViewLayout = layout
        galleryView.backgroundColors = [IntegratedPanelTheme.background]
        galleryView.isSelectable = true
        galleryView.allowsMultipleSelection = true
        galleryView.registerForDraggedTypes([.fileURL])
        WorkspaceDragDrop.configureDragSource(galleryView)
        galleryView.dataSource = self
        galleryView.delegate = self
        galleryView.register(
            WorkspaceGalleryItem.self,
            forItemWithIdentifier: WorkspaceGalleryItem.identifier
        )
        galleryView.onOpen = { [weak self] in self?.openSelection() }
        galleryView.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        galleryView.onRenameRequested = { [weak self] indexPath in
            self?.beginGalleryRename(at: indexPath)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = IntegratedPanelTheme.background
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = galleryView
        return scroll
    }

    /// Finder's パスバー: a slim strip above the status bar showing where you are,
    /// every ancestor clickable. Fed the same self-built items as the top bar —
    /// letting it resolve paths itself would reintroduce the synchronous XPC that
    /// froze the app on protected folders.
    private func makeRibbon() -> NSView {
        let bar = NSView()
        themePainter.register(bar, role: .frame) { IntegratedPanelTheme.header }

        ribbonPath.pathStyle = .standard
        ribbonPath.controlSize = .small
        ribbonPath.font = .systemFont(ofSize: 10.5)
        ribbonPath.target = self
        ribbonPath.action = #selector(ribbonComponentClicked)
        // Right-clicking the path is how people try to take the path with
        // them; both forms live here so a terminal `cd` is paste-and-return.
        let pathMenu = NSMenu(title: "パス")
        let copyPathItem = NSMenuItem(
            title: "パス名をコピー",
            action: #selector(copyCurrentFolderPath),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        pathMenu.addItem(copyPathItem)
        let copyCDItem = NSMenuItem(
            title: "“cd” コマンドをコピー",
            action: #selector(copyChangeDirectoryCommand),
            keyEquivalent: ""
        )
        copyCDItem.target = self
        pathMenu.addItem(copyCDItem)
        ribbonPath.menu = pathMenu
        ribbonPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 見えるところに置く。隠れたメニューの奥だと、見出しが邪魔なときに
        // 切れることに気づけない。
        groupingToggle.setButtonType(.switch)
        groupingToggle.title = "グループでまとめる"
        groupingToggle.font = .systemFont(ofSize: 10.5)
        groupingToggle.controlSize = .small
        groupingToggle.target = self
        groupingToggle.action = #selector(toggleListGrouping)
        groupingToggle.toolTip = "切ると、名前や変更日で一覧ぜんぶを通して並べられます（グループは「グループ」の列で読めます）"
        groupingToggle.state = preferences.listGrouping ? .on : .off

        ungroupedOnlyToggle.setButtonType(.switch)
        ungroupedOnlyToggle.title = "未分類だけ"
        ungroupedOnlyToggle.font = .systemFont(ofSize: 10.5)
        ungroupedOnlyToggle.controlSize = .small
        ungroupedOnlyToggle.target = self
        ungroupedOnlyToggle.action = #selector(toggleUngroupedOnly)
        ungroupedOnlyToggle.toolTip = "どのグループにも入れていないものだけを出す"
        ungroupedOnlyToggle.state = preferences.listUngroupedOnly ? .on : .off

        // 「未分類だけ」の裏返し。まとめたものが未分類の海に埋もれる場所で、束だけを見る。
        groupedOnlyToggle.setButtonType(.switch)
        groupedOnlyToggle.title = "グループのものだけ"
        groupedOnlyToggle.font = .systemFont(ofSize: 10.5)
        groupedOnlyToggle.controlSize = .small
        groupedOnlyToggle.target = self
        groupedOnlyToggle.action = #selector(toggleGroupedOnly)
        groupedOnlyToggle.toolTip = "どれかのグループに入れてあるものだけを出す"
        groupedOnlyToggle.state = preferences.listGroupedOnly ? .on : .off

        // ステータスは別の帯に分けていた。パンくず22pt＋ステータス25ptで、下だけで
        // 47pt——窓の6%を、ほとんど字の無い二本の帯に使っていた。一本にまとめる。
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = IntegratedPanelTheme.secondaryText
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let terminalButton = NSButton(
            title: "⌘J  TERMINAL",
            target: self,
            action: #selector(toggleTerminal)
        )
        terminalButton.isBordered = false
        terminalButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        terminalButton.contentTintColor = IntegratedPanelTheme.secondaryText

        [
            ribbonPath, statusLabel, progress,
            groupedOnlyToggle, ungroupedOnlyToggle, groupingToggle, terminalButton
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            ribbonPath.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            ribbonPath.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor,
                constant: -12
            ),
            ribbonPath.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(
                equalTo: progress.leadingAnchor,
                constant: -8
            ),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            progress.trailingAnchor.constraint(
                equalTo: groupedOnlyToggle.leadingAnchor,
                constant: -10
            ),
            progress.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            terminalButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            terminalButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            groupedOnlyToggle.trailingAnchor.constraint(
                equalTo: ungroupedOnlyToggle.leadingAnchor,
                constant: -12
            ),
            groupedOnlyToggle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            ungroupedOnlyToggle.trailingAnchor.constraint(
                equalTo: groupingToggle.leadingAnchor,
                constant: -12
            ),
            ungroupedOnlyToggle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            groupingToggle.trailingAnchor.constraint(
                equalTo: terminalButton.leadingAnchor,
                constant: -12
            ),
            groupingToggle.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    private func configureColumnView() {
        columnView.onDirectoryChange = { [weak self] url in
            // The column view walks the path itself; the rest of the UI follows
            // without it re-driving the column view and looping.
            guard let self, url != self.navigator.currentDirectory else { return }
            self.navigator.navigate(to: url)
            self.syncAfterColumnNavigation(to: url)
        }
        columnView.onOpenFile = { url in NSWorkspace.shared.open(url) }
        columnView.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        columnView.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        columnView.onRename = { [weak self] item, name in
            self?.renameItem(at: item.url, to: name)
        }
        columnView.onTransfer = { [weak self] sources, destination, copy in
            guard let self else { return }
            self.transferItems(sources, to: destination, copy: copy)
            self.columnView.reload(directory: destination)
        }
        columnView.contextMenuProvider = { [weak self] in self?.fileTable.menu }

        mapView.onOpen = { [weak self] item in
            guard let self else { return }
            if item.isDirectory {
                self.navigate(to: item.url)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
        mapView.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        mapView.contextMenuProvider = { [weak self] in self?.fileTable.menu }
        mapView.groupMenuProvider = { [weak self] name in self?.groupMenu(named: name) }
        // 畳んだ束は一覧と同じものを見る。表示を替えて畳み方が変わると、覚えたことが使えない。
        mapView.collapsedGroups = collapsedGroups
        mapView.onOthersWidthChanged = { [weak self] width in
            self?.preferences.mapOthersWidth = width
        }
        mapView.restoreOthersWidth(preferences.mapOthersWidth)
        mapView.onSortChanged = { [weak self] identifier, ascending in
            self?.applySort(identifier, ascending: ascending)
        }
        mapView.onRename = { [weak self] url, name in
            self?.renameItem(at: url, to: name)
        }
        mapView.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        mapView.onOthersOnlyChanged = { [weak self] value in
            self?.preferences.mapShowsOthersOnly = value
        }
        mapView.setShowsOthersOnly(preferences.mapShowsOthersOnly)
        mapView.onCollapsedGroupsChanged = { [weak self] in self?.applyFilterAndSort() }
        mapView.onPruneMissing = { [weak self] group in self?.pruneMissingMembers(in: group) }
        mapView.columnHeaderMenuProvider = { [weak self] in self?.makeColumnHeaderMenu() }
        // 右の一覧へ落としてファイルを動かす。島への落とし込み（グループに入れる）
        // とは別のことで、こちらは実体が動く。
        mapView.onTransfer = { [weak self] sources, destination, copy in
            guard let self else { return false }
            return self.transferItems(sources, to: destination, copy: copy) != nil
        }
        mapView.setShowsGroupColumn(preferences.showsGroupColumn)
        mapView.currentDirectory = navigator.currentDirectory
        // 右の一覧から島へ引いてグループに入れる。ファイルは動かないので、
        // 一覧の見出しへのドロップと同じ扱い。
        mapView.onLinkToGroup = { [weak self] urls, group in
            guard let self, let members = self.linkableNames(from: urls) else { return false }
            return self.mutateGroups(actionName: "「\(group)」に入れる") { groups in
                members.forEach { groups.add($0, to: group) }
            }
        }
        // 島から島へ引いたときの張り替え。外して入れるのを一手で行う — 二手に割ると、
        // 途中で失敗したときにどちらにも属さないものが残る。
        mapView.onMoveBetweenGroups = { [weak self] urls, from, to in
            guard let self, let members = self.linkableNames(from: urls) else { return false }
            return self.mutateGroups(actionName: "「\(from)」から「\(to)」へ移す") { groups in
                for member in members {
                    groups.remove(member, from: from)
                    groups.add(member, to: to)
                }
            }
        }
        // 「新しいグループ」の枠。落としたものが空なら、いま選んでいるもので作る。
        mapView.onCreateGroup = { [weak self] urls in
            guard let self else { return false }
            let source = urls.isEmpty ? self.selectedItems.map(\.url) : urls
            guard let members = self.linkableNames(from: source) else { return false }
            guard let name = self.askForGroupName() else { return false }
            return self.mutateGroups(actionName: "「\(name)」を作る") { groups in
                members.forEach { groups.add($0, to: name) }
            }
        }
    }

    private func syncAfterColumnNavigation(to url: URL) {
        updateNavigationUI()
        watchCurrentDirectory()
        preferences.lastDirectory = url
        recordVisit(url)
        onDirectoryChange?(url)
        view.window?.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        updateStatus()
    }

    /// list→column→galleryを循環する。toolbarとメニューからは直接選べる。
    @objc func toggleColumnView() {
        let modes = WorkspaceViewMode.allCases
        let index = modes.firstIndex(of: preferences.viewMode) ?? 0
        select(viewMode: modes[(index + 1) % modes.count])
    }

    // Finder binds ⌘2/⌘3/⌘4 to list/column/gallery. Cycling on a single key
    // made the fourth press the only way back, so each mode gets its own key
    // and the cycle stays available for anyone who learned it.
    @objc func selectListView() { select(viewMode: .list) }
    @objc func selectColumnView() { select(viewMode: .column) }
    @objc func selectGalleryView() { select(viewMode: .gallery) }
    @objc func selectMapView() { select(viewMode: .map) }

    /// 列見出しの右クリックに出すもの。一覧にも地図の右の一覧にも同じものを付ける。
    /// メニューは一つの見出しにしか付けられないので、都度作る。
    func makeColumnHeaderMenu() -> NSMenu {
        let menu = NSMenu(title: "列")
        let item = NSMenuItem(title: "グループ", action: #selector(toggleGroupColumn), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// 「グループ」の列を出す／隠す。列見出しの右クリックと「表示」メニューの両方から。
    @objc func toggleGroupColumn() {
        preferences.showsGroupColumn.toggle()
        applyGroupColumnVisibility()
    }

    private func applyGroupColumnVisibility() {
        let shows = preferences.showsGroupColumn
        // 地図の右の一覧も同じ設定を見る。別々に持つと、表示を替えただけで列が消える。
        mapView.setShowsGroupColumn(shows)
        guard let column = fileTable.tableColumns.first(where: { $0.identifier == Column.groups })
        else { return }
        guard column.isHidden == shows else { return }
        column.isHidden = !shows
        layoutFileColumns()
        fileTable.reloadData()
    }

    /// グループの見出しを右クリックしたときのメニュー。
    ///
    /// グループを作れるのに名前を変えたり解いたりできないと、間違えた名前を直すには
    /// JSONを手で開くしかない。作れるものは、直せて、消せるべき。
    private func groupHeaderMenu(forRow row: Int) -> NSMenu? {
        guard fileRows.indices.contains(row),
              case .header(let title, _) = fileRows[row],
              let name = title else { return nil }
        return groupMenu(named: name)
    }

    /// 束そのものへの操作。一覧の見出しからも、地図の右の見出しからも同じものを出す。
    func groupMenu(named name: String) -> NSMenu? {
        guard itemGroups?.groups.contains(where: { $0.name == name }) == true else { return nil }
        contextGroupName = name

        let menu = NSMenu(title: name)
        func add(_ label: String, _ action: Selector) {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("「\(name)」の中身を全部選択", #selector(selectGroupMembers))
        menu.addItem(.separator())
        add("名前を変更…", #selector(renameContextGroup))
        add("上へ", #selector(moveContextGroupUp))
        add("下へ", #selector(moveContextGroupDown))

        // 「A ∈ B」を作る口。自分と自分の子孫は親にできない（輪になる）。
        let nestItem = NSMenuItem(title: "このグループを入れる先", action: nil, keyEquivalent: "")
        let nestMenu = NSMenu()
        if let groups = itemGroups {
            let forbidden = Set([name] + descendants(of: name, in: groups))
            for candidate in groups.groups.map(\.name) where !forbidden.contains(candidate) {
                let item = NSMenuItem(
                    title: candidate,
                    action: #selector(nestContextGroup(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = candidate
                item.state = groups.groups.first { $0.name == name }?.parent == candidate ? .on : .off
                nestMenu.addItem(item)
            }
            if nestMenu.items.isEmpty {
                nestMenu.addItem(NSMenuItem(title: "入れられる先がありません", action: nil, keyEquivalent: ""))
            } else if groups.groups.first(where: { $0.name == name })?.parent != nil {
                nestMenu.addItem(.separator())
                let lift = NSMenuItem(
                    title: "外へ出す（最上位へ）",
                    action: #selector(unnestContextGroup),
                    keyEquivalent: ""
                )
                lift.target = self
                nestMenu.addItem(lift)
            }
        }
        nestItem.submenu = nestMenu
        menu.addItem(nestItem)

        // この束にだけ迷子が居るときに出す。地図の島の「見つからない N →」と同じことを、
        // 一覧の見出しからもできるように。
        let lost = itemGroups?.missingMembers(amongNames: presentNames)[name] ?? []
        if !lost.isEmpty {
            menu.addItem(.separator())
            add("見つからない\(lost.count)件を外す…", #selector(pruneContextGroupMissing))
        }

        menu.addItem(.separator())
        add("このグループを解除…", #selector(removeContextGroup))
        return menu
    }

    @objc private func selectGroupMembers() {
        guard let name = contextGroupName, let groups = itemGroups else { return }
        let urls = displayedItems
            .filter { groups.groupNames(for: $0.name).contains(name) }
            .map(\.url)
        restoreFlatSelection(urls)
    }

    @objc private func renameContextGroup() {
        guard let name = contextGroupName else { return }
        guard let newName = askForGroupName(
            title: "グループの名前を変更",
            message: "「\(name)」の新しい名前を入れてください。フォルダは動きません。",
            initial: name
        ) else { return }
        mutateGroups(actionName: "グループの名前を変更") { groups in
            groups.rename(name, to: newName)
        }
    }

    /// そのグループの子孫。入れ先の候補から外すために使う（輪を作らせない）。
    private func descendants(of name: String, in groups: WorkspaceItemGroups) -> [String] {
        var result: [String] = []
        var queue = groups.children(of: name)
        while let current = queue.first {
            queue.removeFirst()
            guard !result.contains(current) else { continue }
            result.append(current)
            queue.append(contentsOf: groups.children(of: current))
        }
        return result
    }

    @objc private func nestContextGroup(_ sender: NSMenuItem) {
        guard let name = contextGroupName,
              let parent = sender.representedObject as? String else { return }
        mutateGroups(actionName: "「\(name)」を「\(parent)」に入れる") { groups in
            groups.nest(name, inside: parent)
        }
    }

    @objc private func unnestContextGroup() {
        guard let name = contextGroupName else { return }
        mutateGroups(actionName: "「\(name)」を外へ出す") { groups in
            groups.nest(name, inside: nil)
        }
    }

    @objc private func moveContextGroupUp() { moveContextGroup(by: -1) }
    @objc private func moveContextGroupDown() { moveContextGroup(by: 1) }

    private func moveContextGroup(by offset: Int) {
        guard let name = contextGroupName else { return }
        mutateGroups(actionName: "グループの並びを変える") { groups in
            groups.move(name, by: offset)
        }
    }

    /// グループを解く。中のものはグループから外れるだけで、フォルダは一つも減らない。
    /// それでも確かめるのは、グループの定義そのものが手で作った資産だから。
    @objc private func removeContextGroup() {
        guard let name = contextGroupName, let groups = itemGroups else { return }
        let count = displayedItems.filter { groups.groupNames(for: $0.name).contains(name) }.count

        let alert = NSAlert()
        alert.messageText = "「\(name)」を解除しますか？"
        alert.informativeText = "このグループの\(count)項目はグループから外れるだけです。"
            + "フォルダは一つも減りません。取り消せます。"
        alert.addButton(withTitle: "解除")
        alert.addButton(withTitle: "やめる")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        mutateGroups(actionName: "「\(name)」を解除") { groups in
            groups.removeGroup(name)
        }
        collapsedGroups.remove(name)
    }

    /// 見出しを押してグループを畳む・開く。
    private func toggleGroupCollapse(at row: Int) {
        guard fileRows.indices.contains(row), case .header(let title, _) = fileRows[row] else { return }
        let name = title ?? Self.ungroupedTitle
        if collapsedGroups.contains(name) {
            collapsedGroups.remove(name)
        } else {
            collapsedGroups.insert(name)
        }
        let selection = selectedItems.map(\.url)
        rebuildFileRows()
        fileTable.reloadData()
        restoreFlatSelection(selection)
        updateStatus()
    }

    /// 「未分類だけ」を入り切りする。
    ///
    /// まだどこにも入れていないものを片付けるための眺め方。地図の「これだけ」と
    /// 同じ考えで、こちらは一覧に効く。
    @objc func toggleUngroupedOnly() {
        preferences.listUngroupedOnly.toggle()
        // 両方入れると何も残らない。相手を落とすのは、空の一覧を見せて
        // 「壊れた」と思わせないため。
        if preferences.listUngroupedOnly { preferences.listGroupedOnly = false }
        syncGroupFilterToggles()
        let selection = selectedItems.map(\.url)
        applyFilterAndSort()
        restoreFlatSelection(selection)
    }

    /// 「グループのものだけ」を入り切りする。
    ///
    /// まとめた束だけを見るための眺め方。146個が平らに並ぶ場所では、見出しがあっても
    /// 間に未分類が何十行も挟まって束として読めない。
    @objc func toggleGroupedOnly() {
        preferences.listGroupedOnly.toggle()
        if preferences.listGroupedOnly { preferences.listUngroupedOnly = false }
        syncGroupFilterToggles()
        let selection = selectedItems.map(\.url)
        applyFilterAndSort()
        restoreFlatSelection(selection)
    }

    private func syncGroupFilterToggles() {
        ungroupedOnlyToggle.state = preferences.listUngroupedOnly ? .on : .off
        groupedOnlyToggle.state = preferences.listGroupedOnly ? .on : .off
    }

    /// 一覧のグループの見出しを入り切りする。
    ///
    /// 見出しで区切ると並べ替えがグループの中だけに効く。名前順に通して眺めたいときは
    /// 切る。切っても「グループ」の列で所属は読めるので、グループが見えなくなるわけではない。
    @objc func toggleListGrouping() {
        preferences.listGrouping.toggle()
        groupingToggle.state = preferences.listGrouping ? .on : .off
        let selection = selectedItems.map(\.url)
        rebuildFileRows()
        fileTable.reloadData()
        restoreFlatSelection(selection)
        updateStatus()
    }

    /// 地図と、その前に見ていた表示を行き来する（⌘G）。
    ///
    /// 地図は「重なりを見る」ための寄り道で、作業する場所は一覧のほう。
    /// 行って戻るのが一手で済まないと、見に行く気にならない。
    @objc func toggleMapView() {
        if preferences.viewMode == .map {
            select(viewMode: modeBeforeMap)
        } else {
            modeBeforeMap = preferences.viewMode
            select(viewMode: .map)
        }
    }

    private func select(viewMode: WorkspaceViewMode) {
        let selection = selectedItems.map(\.url)
        preferences.viewMode = viewMode
        applyViewMode()
        restoreFlatSelection(selection)
    }

    @objc private func viewModeChanged() {
        guard WorkspaceViewMode.allCases.indices.contains(viewModeControl.selectedSegment) else {
            return
        }
        let selection = selectedItems.map(\.url)
        preferences.viewMode = WorkspaceViewMode.allCases[viewModeControl.selectedSegment]
        applyViewMode()
        restoreFlatSelection(selection)
    }

    private var searchHasText: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usesRecursiveSearch: Bool {
        searchHasText && searchScopeControl.selectedSegment == 1
    }

    /// Column viewは検索結果のflat listを表現できないため、検索中だけlistへ退避し、
    /// 検索を消せば保存済みcolumn modeへ自動で戻す。
    private var effectiveViewMode: WorkspaceViewMode {
        searchHasText && preferences.viewMode == .column ? .list : preferences.viewMode
    }

    /// いまの表示でキー操作を受けるべきビュー。表示を変えたらここも移す —
    /// でないとSpaceやクイックルックが前の表示に飛ぶ。
    private var firstResponderForCurrentMode: NSView {
        switch effectiveViewMode {
        case .gallery: return galleryView
        case .map: return mapView.keyboardTarget
        case .column: return columnView
        case .list: return fileTable
        }
    }

    private func applyViewMode() {
        let mode = effectiveViewMode
        columnView.isHidden = mode != .column
        listScrollView?.isHidden = mode != .list
        galleryScrollView?.isHidden = mode != .gallery
        mapView.isHidden = mode != .map
        // グループの見出しは一覧だけのもの。他の表示で出しても効かないので出さない。
        groupingToggle.isHidden = mode != .list
        ungroupedOnlyToggle.isHidden = mode != .list
        groupedOnlyToggle.isHidden = mode != .list
        viewModeControl.selectedSegment = WorkspaceViewMode.allCases.firstIndex(of: mode) ?? 0
        if mode == .column {
            columnView.show(
                directory: navigator.currentDirectory,
                showHiddenFiles: preferences.showHiddenFiles
            )
        }
        // 地図で畳んだ束が一覧にも効くように、戻ってきたら組み直す。
        if mode == .list {
            let selection = selectedItems.map(\.url)
            rebuildFileRows()
            fileTable.reloadData()
            restoreFlatSelection(selection)
        }
        // 開いたときに組み直す。地図は決定的なので、組めばそれで完成している。
        if mode == .map {
            mapView.currentDirectory = navigator.currentDirectory
            mapView.show(items: displayedItems, groups: itemGroups, presentNames: presentNames)
        }
        galleryView.reloadData()
        // キーの行き先を新しい表示へ移す。
        if view.window?.firstResponder !== firstResponderForCurrentMode {
            view.window?.makeFirstResponder(firstResponderForCurrentMode)
        }
        updateStatus()
    }

    private func makeNavigationBar() -> NSView {
        let bar = NSView()
        themePainter.register(bar, role: .frame) { IntegratedPanelTheme.header }
        configureNavigationButton(backButton, symbol: "chevron.left", action: #selector(goBack), label: "戻る")
        configureNavigationButton(forwardButton, symbol: "chevron.right", action: #selector(goForward), label: "進む")
        configureNavigationButton(upButton, symbol: "arrow.up", action: #selector(goUp), label: "親フォルダ")
        configureNavigationButton(refreshButton, symbol: "arrow.clockwise", action: #selector(refresh), label: "再読み込み")
        // The address bar's raw text breaks in a shell on spaces, parentheses
        // and quotes, so the terminal-ready form gets its own visible button
        // right next to where people were copying by hand.
        configureNavigationButton(
            copyCDButton,
            symbol: "terminal",
            action: #selector(copyCDFromButton),
            label: "“cd” コマンドをコピー — Terminalに貼るだけで移動"
        )
        configureNavigationButton(newFolderButton, symbol: "folder.badge.plus", action: #selector(createFolder), label: "新規フォルダ")
        // 選んで押すだけでグループができる導線。右クリックのメニューと地図の枠にも
        // 入口はあるが、どちらも「知っている人」しか辿れない。ここは見えている。
        configureNavigationButton(
            newGroupButton,
            symbol: "rectangle.stack.badge.plus",
            action: #selector(createGroupWithSelection),
            label: "選んだものでグループを作る"
        )

        // セグメントの並びは WorkspaceViewMode.allCases と一対一。片方だけ足すと
        // 選択の対応がずれる。
        viewModeControl.segmentCount = WorkspaceViewMode.allCases.count
        let symbols = ["list.bullet", "rectangle.split.3x1", "square.grid.2x2", "point.3.connected.trianglepath.dotted"]
        for (index, symbol) in symbols.enumerated() {
            viewModeControl.setImage(
                NSImage(systemSymbolName: symbol, accessibilityDescription: "表示モード"),
                forSegment: index
            )
            viewModeControl.setWidth(25, forSegment: index)
        }
        viewModeControl.trackingMode = .selectOne
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.toolTip = "リスト／カラム／ギャラリー／マップ"

        searchScopeControl.segmentCount = 2
        searchScopeControl.setLabel("直下", forSegment: 0)
        searchScopeControl.setLabel("配下", forSegment: 1)
        searchScopeControl.setWidth(42, forSegment: 0)
        searchScopeControl.setWidth(42, forSegment: 1)
        searchScopeControl.selectedSegment = 0
        // 検索していないときは出さない。何も打っていないのに「直下／配下」だけが
        // 帯の右端に浮いていて、何に効くのか読めなかった。Finderと同じで、
        // 範囲は探し始めてから選ぶもの。
        searchScopeControl.isHidden = true
        searchScopeControl.trackingMode = .selectOne
        searchScopeControl.target = self
        searchScopeControl.action = #selector(searchScopeChanged)
        searchScopeControl.toolTip = "検索範囲"

        // The top bar's path is a plain text address bar: always the current
        // path, selectable and copyable, and typing a new one navigates. Clicking
        // through ancestors is the bottom ribbon's job — a breadcrumb up here
        // spent two revisions fighting NSPathControl's click handling for an
        // empty-area editor that a text field gives for free.
        pathField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        pathField.delegate = self
        pathField.bezelStyle = .roundedBezel
        pathField.placeholderString = "パスを入力"
        pathField.lineBreakMode = .byTruncatingHead
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pathSlot = NSView()
        pathSlot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathSlot.addSubview(pathField)
        NSLayoutConstraint.activate([
            pathField.leadingAnchor.constraint(equalTo: pathSlot.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: pathSlot.trailingAnchor),
            pathField.centerYAnchor.constraint(equalTo: pathSlot.centerYAnchor)
        ])
        pathSlot.heightAnchor.constraint(equalToConstant: 24).isActive = true

        searchField.placeholderString = "検索"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // ボタンと検索は同じ行に置く。住所欄が自分の行を持ったので、上の行に残るのは
        // 幅を大して要らないものだけになった。狭いときは検索が縮む——ボタンは的として
        // 縮められないので、縮む役はこちらが持つ。
        configureAppearanceButton()
        configureTintButton()
        let navigationStack = NSStackView(views: [
            backButton, forwardButton, upButton, copyCDButton,
            refreshButton, newFolderButton, newGroupButton,
            appearanceButton, tintButton, viewModeControl
        ])
        navigationStack.orientation = .horizontal
        navigationStack.alignment = .centerY
        navigationStack.spacing = 7
        navigationStack.distribution = .fill

        let searchSpacer = NSView()
        searchSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let searchStack = NSStackView(views: [searchSpacer, searchScopeControl, searchField])
        searchStack.orientation = .horizontal
        searchStack.alignment = .centerY
        searchStack.spacing = 7
        searchStack.distribution = .fill

        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        searchStack.translatesAutoresizingMaskIntoConstraints = false
        pathSlot.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(navigationStack)
        bar.addSubview(searchStack)
        bar.addSubview(pathSlot)
        NSLayoutConstraint.activate([
            navigationStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            navigationStack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            navigationStack.heightAnchor.constraint(equalToConstant: 27),
            // 検索はボタンと同じ行の右端。
            navigationStack.trailingAnchor.constraint(
                equalTo: searchStack.leadingAnchor,
                constant: -10
            ),
            searchStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            searchStack.centerYAnchor.constraint(equalTo: navigationStack.centerYAnchor),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            // 住所欄は自分の行を持ち、窓の幅をそのまま使う。ボタンに挟ませていた
            // ときは、いちばん縮んでよい要素として扱われて末尾の数文字まで潰れた
            // ——実測で「...t」だけが残り、どこに居るのか読めなかった。
            pathSlot.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            pathSlot.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            pathSlot.topAnchor.constraint(equalTo: navigationStack.bottomAnchor, constant: 5),
            pathSlot.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6)
        ])
        // 検索の下限は折れる制約にする。狭い窓では検索が縮んでほしいが、縮みきって
        // なお足りないときに、制約そのものが壊れて配置が崩れては困る。
        let searchMinimum = searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        searchMinimum.priority = .defaultHigh
        searchMinimum.isActive = true
        return bar
    }

    private func configureNavigationButton(
        _ button: NSButton,
        symbol: String,
        action: Selector,
        label: String
    ) {
        button.title = ""
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.contentTintColor = IntegratedPanelTheme.text
        button.target = self
        button.action = action
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    /// Split out so the column geometry can be exercised without a window: the
    /// widths and the autoresizing style together decide whether long names
    /// truncate, and that only shows up once a table is laid out at a real size.
    static func makeFileColumns() -> [NSTableColumn] {
        let name = NSTableColumn(identifier: Column.name)
        name.title = "名前"
        name.minWidth = 220
        name.width = 430
        name.sortDescriptorPrototype = NSSortDescriptor(
            key: Column.name.rawValue,
            ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:))
        )
        let modified = NSTableColumn(identifier: Column.modified)
        modified.title = "変更日"
        modified.minWidth = 145
        modified.width = 175
        modified.sortDescriptorPrototype = NSSortDescriptor(key: Column.modified.rawValue, ascending: false)
        let size = NSTableColumn(identifier: Column.size)
        size.title = "サイズ"
        size.minWidth = 80
        size.width = 100
        size.sortDescriptorPrototype = NSSortDescriptor(key: Column.size.rawValue, ascending: true)
        let kind = NSTableColumn(identifier: Column.kind)
        kind.title = "種類"
        kind.minWidth = 110
        kind.width = 145
        kind.sortDescriptorPrototype = NSSortDescriptor(key: Column.kind.rawValue, ascending: true)
        // グループを属性の一つとして持つ。見出しで区切らなくても所属が読めるし、
        // この列で並べればグループごとにまとまる — 見出しを切るのとは違って、
        // 名前や更新日での並べ替えを捨てずに済む。
        let groups = NSTableColumn(identifier: Column.groups)
        groups.title = "グループ"
        groups.minWidth = 90
        groups.width = 150
        // 既定は隠す。常に出すと名前の幅が150pt削られ、狭い窓では横スクロールが
        // 出た。所属は見出しでも読めるので、列は要る人だけが出す。
        groups.isHidden = true
        groups.sortDescriptorPrototype = NSSortDescriptor(
            key: Column.groups.rawValue,
            ascending: true,
            selector: #selector(NSString.localizedStandardCompare(_:))
        )
        return [name, modified, size, kind, groups]
    }

    /// When the list is wider than the columns need, the leftover belongs to
    /// 名前: 種類 holds a short fixed label ("PPTX ファイル") and gains nothing
    /// from extra width, while names are what actually get truncated.
    ///
    /// This only decides who receives *surplus* width. It does nothing when the
    /// columns are too wide for the list — see `nameColumnWidth`.
    static let fileColumnAutoresizing = NSTableView.ColumnAutoresizingStyle
        .firstColumnOnlyAutoresizingStyle

    /// What 名前 should be, given everything else in the row.
    ///
    /// The autoresizing style alone is not enough: AppKit redistributes width
    /// only when a table is *resized*, so on the first layout the columns keep
    /// their authored widths. Too wide and the list opens with a horizontal
    /// scroller; too narrow and it opens with dead space past 種類. Sizing 名前
    /// explicitly on every layout removes both.
    static func nameColumnWidth(
        viewport: CGFloat,
        fixedColumnsTotal: CGFloat,
        gutters: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        max(minimum, viewport - fixedColumnsTotal - gutters)
    }

    /// Re-sized on every layout pass, so the width is only written when it
    /// actually changes — assigning a column width re-enters layout.
    private func layoutFileColumns() {
        guard let viewport = listScrollView?.contentView.bounds.width else { return }
        // 隠れている列は場所を取らない。数に入れると名前が要らぬぶん縮む。
        let columns = fileTable.tableColumns.filter { !$0.isHidden }
        guard let name = columns.first, columns.count > 1, viewport > 0 else { return }
        let target = Self.nameColumnWidth(
            viewport: viewport,
            fixedColumnsTotal: columns.dropFirst().reduce(0) { $0 + $1.width },
            gutters: fileTable.intercellSpacing.width * CGFloat(columns.count),
            minimum: name.minWidth
        )
        guard abs(name.width - target) > 0.5 else { return }
        name.width = target
    }

    private func makeFileTable() -> NSScrollView {
        Self.makeFileColumns().forEach(fileTable.addTableColumn)
        fileTable.delegate = self
        fileTable.dataSource = self
        fileTable.rowHeight = 27
        // 縞と見出しの帯は両立しない。縞のままだと見出しの地色が行番号の偶奇で変わり、
        // 同じ束がフォルダを開くたび明るくなったり暗くなったりする。
        fileTable.usesAlternatingRowBackgroundColors = false
        fileTable.backgroundColor = IntegratedPanelTheme.background
        fileTable.gridColor = IntegratedPanelTheme.border.withAlphaComponent(0.55)
        fileTable.allowsMultipleSelection = true
        fileTable.allowsEmptySelection = true
        fileTable.columnAutoresizingStyle = Self.fileColumnAutoresizing
        fileTable.target = self
        fileTable.doubleAction = #selector(openSelection)
        fileTable.registerForDraggedTypes([.fileURL])
        WorkspaceDragDrop.configureDragSource(fileTable)
        // 列見出しの右クリックで列を出し入れする（Finderと同じ場所）。
        fileTable.headerView?.menu = makeColumnHeaderMenu()

        fileTable.onOpen = { [weak self] in self?.openSelection() }
        fileTable.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        fileTable.isHeaderRow = { [weak self] row in self?.isHeaderRow(row) ?? false }
        fileTable.onHeaderClicked = { [weak self] row in self?.toggleGroupCollapse(at: row) }
        fileTable.groupMenuProvider = { [weak self] row in self?.groupHeaderMenu(forRow: row) }
        fileTable.onRenameRequested = { [weak self] row in
            self?.beginListRename(at: row)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = IntegratedPanelTheme.background
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = fileTable
        return scroll
    }


    private func configureContextMenu() {
        let menu = NSMenu(title: "ファイル操作")
        menu.delegate = self
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        add("開く", #selector(openSelection))
        // Populated in menuWillOpen: the list depends on what is selected.
        openWithItem = NSMenuItem(title: "このアプリケーションで開く", action: nil, keyEquivalent: "")
        openWithItem.submenu = NSMenu()
        menu.addItem(openWithItem)
        add("クイックルック", #selector(toggleQuickLook))
        menu.addItem(.separator())

        add("情報を見る", #selector(showInfo))
        add("Finderで表示", #selector(revealSelectionInFinder))
        add("サイドバーにピン留め", #selector(togglePin))
        // Populated in menuWillOpen: どのグループがあるかはフォルダごとに違う。
        addToGroupItem = NSMenuItem(title: "グループに入れる", action: nil, keyEquivalent: "")
        addToGroupItem.submenu = NSMenu()
        menu.addItem(addToGroupItem)
        removeFromGroupItem = NSMenuItem(title: "グループから外す", action: nil, keyEquivalent: "")
        removeFromGroupItem.submenu = NSMenu()
        menu.addItem(removeFromGroupItem)
        add("見つからない項目を整理…", #selector(pruneMissingGroupMembers))
        menu.addItem(.separator())

        add("カット", #selector(cutSelection))
        add("コピー", #selector(copySelection))
        add("パス名をコピー", #selector(copyCurrentPath))
        add("ペースト", #selector(pasteIntoCurrentFolder))
        add("複製", #selector(duplicateSelection))
        add("エイリアスを作成", #selector(makeAliasForSelection))
        add("圧縮", #selector(compressSelection))
        menu.addItem(.separator())

        // The system fills these in; we only say where they go.
        shareItem = NSMenuItem(title: "共有", action: nil, keyEquivalent: "")
        shareItem.submenu = NSMenu()
        menu.addItem(shareItem)
        let services = NSMenuItem(title: "サービス", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())

        add("名前を変更", #selector(renameSelection))
        add("新規フォルダ", #selector(createFolder))
        menu.addItem(.separator())
        add("ゴミ箱に入れる…", #selector(trashSelection))

        fileTable.menu = menu
        galleryView.menu = menu
        configureSidebarContextMenu()
    }

    private var pasteboardHasFiles: Bool {
        fileClipboard.canPaste(into: navigator.currentDirectory)
    }

    /// Rebuilt per open because the candidate apps depend on the file's type, and
    /// a multi-selection of mixed types has no single answer.
    private func rebuildOpenWithSubmenu(for urls: [URL]) {
        let submenu = NSMenu()
        defer { openWithItem.submenu = submenu }

        guard urls.count == 1, let url = urls.first, !url.hasDirectoryPath else {
            openWithItem.isEnabled = false
            return
        }
        openWithItem.isEnabled = true

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        openWithURL = url

        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path)
            let title = app == defaultApp ? "\(name)（デフォルト）" : name
            let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        if apps.isEmpty {
            submenu.addItem(NSMenuItem(title: "対応アプリがありません", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, let url = openWithURL else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// The system supplies the services; we only place them.
    private func rebuildShareSubmenu(for urls: [URL]) {
        let submenu = NSMenu()
        defer { shareItem.submenu = submenu }
        guard !urls.isEmpty else {
            shareItem.isEnabled = false
            return
        }
        shareItem.isEnabled = true
        shareURLs = urls

        for service in NSSharingService.sharingServices(forItems: urls) {
            let item = NSMenuItem(title: service.title, action: #selector(share(_:)), keyEquivalent: "")
            item.target = self
            item.image = service.image
            item.representedObject = service
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            submenu.addItem(NSMenuItem(title: "共有できる相手がありません", action: nil, keyEquivalent: ""))
        }
    }

    @objc private func share(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService else { return }
        service.perform(withItems: shareURLs)
    }

    private func configureSidebarContextMenu() {
        let menu = NSMenu(title: "サイドバー")
        menu.delegate = self
        let unpin = NSMenuItem(
            title: "ピン留めを解除",
            action: #selector(unpinClickedSidebarRow),
            keyEquivalent: ""
        )
        unpin.target = self
        menu.addItem(unpin)
        let reveal = NSMenuItem(
            title: "Finderで表示",
            action: #selector(revealClickedSidebarRow),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)
        sidebarTable.menu = menu
    }

    private var clickedSidebarItem: WorkspaceSidebarModel.Item? {
        let row = sidebarTable.clickedRow
        guard sidebarRows.indices.contains(row),
              case .item(let item) = sidebarRows[row] else { return nil }
        return item
    }

    @objc private func unpinClickedSidebarRow() {
        guard let item = clickedSidebarItem else { return }
        var pins = preferences.pins
        pins.unpin(item.url)
        preferences.pins = pins
        rebuildSidebar()
    }

    @objc private func revealClickedSidebarRow() {
        guard let item = clickedSidebarItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Rebuilds the sidebar from what is currently known.
    ///
    /// Pure and synchronous: everything that reaches the filesystem (Finder's
    /// favourites, mounted volumes) is loaded elsewhere and only handed in here,
    /// so this stays safe to call from the launch path.
    private func rebuildSidebar() {
        let pins = preferences.pins
        let log = preferences.visitLog
        let claimed = Set(
            pins.storedPaths
                + finderFavorites.map(\.path)
                + volumes.map(\.path)
        )

        let sections = WorkspaceSidebarModel.sections(
            .init(
                pins: pins.urls,
                favorites: finderFavorites.isEmpty
                    ? WorkspaceSidebarModel.fallbackFavorites(home: Self.homeDirectory)
                    : finderFavorites,
                volumes: volumes,
                frequent: log.frequent(limit: 5, excluding: claimed),
                recent: log.recent(limit: 5, excluding: claimed)
            ),
            home: Self.homeDirectory
        )

        sidebarRows = sections.flatMap { section in
            [SidebarRow.header(section.title)] + section.items.map(SidebarRow.item)
        }
        sidebarTable.reloadData()
        updateSidebarSelection()
    }

    /// Loads the two sources that touch the filesystem.
    ///
    /// Both are off the main thread on purpose. Resolving Finder's bookmarks
    /// reaches TCC, and `mountedVolumeURLs` waits on network volumes — the user
    /// has NAS shares mounted, and either would freeze the window on the launch
    /// path exactly as `pathControl.url` used to.
    private func loadSidebarSources() {
        sidebarLoadTask?.cancel()
        sidebarLoadTask = Task.detached(priority: .utility) { [weak self] in
            let favorites = FinderFavorites.directories()
            let volumes = Self.mountedVolumes()
            guard !Task.isCancelled else { return }
            await self?.applySidebarSources(favorites: favorites, volumes: volumes)
        }
    }

    private func applySidebarSources(favorites: [URL], volumes: [URL]) {
        guard finderFavorites != favorites || self.volumes != volumes else { return }
        finderFavorites = favorites
        self.volumes = volumes
        rebuildSidebar()
    }

    private nonisolated static func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]
        )?.filter { url in
            // Non-browsable volumes are things like the sealed system snapshot;
            // Finder does not offer them either.
            (try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]))?
                .volumeIsBrowsable ?? false
        }.map(\.standardizedFileURL) ?? []
    }

    private func updateSidebarSelection() {
        let current = navigator.currentDirectory.path
        let index = sidebarRows.firstIndex { row in
            if case .item(let item) = row { return item.url.path == current }
            return false
        }
        if let index {
            sidebarTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            sidebarTable.deselectAll(nil)
        }
    }

    /// Moves to `url` as if the user had clicked it, history included.
    func navigate(to url: URL) {
        navigate(to: url, addHistory: true)
    }

    /// 入れ物のフォルダを開いて、その1つを選んだ状態にする。外から
    /// ファイルを渡されたときの着地点。読み込みは非同期なので、選ぶのは
    /// 一覧が揃ってから（`selectPendingItemIfNeeded`が拾う）。
    func reveal(_ url: URL) {
        let target = url.standardizedFileURL
        pendingSelectionURL = target
        navigate(to: target.deletingLastPathComponent())
    }

    private func navigate(to url: URL, addHistory: Bool) {
        if addHistory { navigator.navigate(to: url) }
        let directory = navigator.currentDirectory
        searchField.stringValue = ""
        recursiveSearchTask?.cancel()
        recursiveSearchTask = nil
        recursiveSearchGeneration &+= 1
        recursiveSearchIsTruncated = false
        recursiveSearchErrorShown = false
        applyViewMode()
        updateNavigationUI()
        reloadContents()
        // The column view keeps its own columns; this is for navigation that did
        // not originate there (sidebar, breadcrumb, back/forward, path bar).
        if preferences.usesColumnView, isViewLoaded {
            columnView.show(directory: directory, showHiddenFiles: preferences.showHiddenFiles)
        }
        watchCurrentDirectory()
        preferences.lastDirectory = directory
        recordVisit(directory)
        onDirectoryChange?(directory)
        view.window?.title = directory.lastPathComponent.isEmpty
            ? directory.path
            : directory.lastPathComponent
    }

    /// Rebuilds the sidebar only when the ranking actually moved, so navigating
    /// does not reload the table on every single folder change.
    private func recordVisit(_ directory: URL) {
        var log = preferences.visitLog
        let before = sidebarRows
        log.record(directory, now: Date())
        preferences.visitLog = log

        rebuildSidebar()
        if sidebarRows == before { return }
        updateSidebarSelection()
    }

    private func watchCurrentDirectory() {
        watcher.start(url: navigator.currentDirectory) { [weak self] event in
            guard let self else { return }
            switch event {
            case .contentsChanged:
                // The folder changed underneath us; refresh without disturbing
                // the user's selection or scroll position more than necessary.
                let selected = self.selectedItems.first?.url
                self.pendingSelectionURL = selected
                self.reloadContents()
            case .relocated(let source, let destination):
                self.followDisplayedDirectory(from: source, to: destination)
            case .disappeared(let url):
                self.retreatFromDeletedDirectory(url)
            }
        }
    }

    /// The folder on screen was moved or renamed outside the app — in the real
    /// Finder or from a shell. Follow it the same way an in-app rename does:
    /// current path, history and window title all move to the new location.
    private func followDisplayedDirectory(from source: URL, to destination: URL) {
        guard navigator.relocatePathPrefix(from: source, to: destination) else { return }
        pendingSelectionURL = nil
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    /// The folder on screen was deleted or trashed outside the app. Retreating
    /// to the nearest surviving ancestor keeps the window usable instead of
    /// leaving a dead listing; going through history keeps Back as the record of
    /// where the user actually was.
    private func retreatFromDeletedDirectory(_ deleted: URL) {
        guard deleted == navigator.currentDirectory else { return }
        var candidate = deleted.deletingLastPathComponent().standardizedFileURL
        while candidate.pathComponents.count > 1,
              !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = candidate.deletingLastPathComponent().standardizedFileURL
        }
        navigate(to: candidate)
    }

    private func updateNavigationUI() {
        backButton.isEnabled = navigator.canGoBack
        forwardButton.isEnabled = navigator.canGoForward
        upButton.isEnabled = navigator.canGoUp
        updatePathControl(for: navigator.currentDirectory)
        updateSidebarSelection()
    }

    /// Builds the breadcrumb without letting AppKit resolve it.
    ///
    /// `pathControl.url = ...` looks up a display name and icon for every path
    /// component through a *synchronous* XPC round-trip. On a TCC-protected
    /// folder that call blocks the main thread until the permission dialog is
    /// answered — clicking Desktop or Downloads froze the whole app with the
    /// spinner still turning. A stack sample showed 100% of main-thread time in
    /// `xpc_connection_send_message_with_reply_sync` under this one assignment.
    ///
    /// Setting `pathItems` ourselves keeps it to string and icon work we already
    /// have, so nothing on this path can block.
    private func updatePathControl(for directory: URL) {
        let crumbs = WorkspaceBreadcrumb.crumbs(for: directory)
        // `NSPathControlItem.url` is read-only, so the click target is recovered
        // by index instead.
        pathComponentURLs = crumbs.map(\.url)
        func items() -> [NSPathControlItem] {
            crumbs.map { crumb in
                let item = NSPathControlItem()
                item.title = crumb.title
                item.image = Self.pathComponentIcon
                return item
            }
        }
        ribbonPath.pathItems = items()
        // Never clobber a path the user is mid-typing: navigation triggered from
        // elsewhere (sidebar, ribbon) while the field is being edited would
        // silently discard their input. `currentEditor()` is non-nil exactly
        // while an edit session is active — comparing responders instead left
        // the field permanently empty, because nil === nil counted as "editing"
        // before the window ever existed.
        if pathField.currentEditor() == nil {
            // People copy this text straight into `cd`; the Finder form
            // without the trailing slash is what they expect to travel.
            pathField.stringValue = Self.plainPath(for: directory)
        }
    }

    /// One generic folder icon for every breadcrumb component: per-path icons are
    /// what made the breadcrumb reach the filesystem in the first place.
    private static let pathComponentIcon: NSImage = {
        let image = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: "フォルダ"
        ) ?? NSImage()
        image.size = NSSize(width: 14, height: 14)
        return image
    }()

    /// The stored task is the detached one so that `cancel()` reaches the
    /// enumeration itself. Wrapping a detached task inside a `Task` would leave the
    /// listing running after cancellation and let rapid navigation pile up
    /// concurrent enumerations on the same volume.
    private func reloadContents() {
        listingTask?.cancel()
        cloudStatusTask?.cancel()
        recursiveSearchTask?.cancel()
        recursiveSearchTask = nil
        recursiveSearchGeneration &+= 1
        recursiveSearchIsTruncated = false
        let directory = navigator.currentDirectory
        let showHidden = preferences.showHiddenFiles
        beginLoadingIndicator()

        listingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let items = try WorkspaceDirectoryListing.contents(
                    of: directory,
                    showHiddenFiles: showHidden
                )
                // グループの定義は一覧と同じ往復で読む。小さなローカルファイルなので、
                // クラウドキーと違って一覧を待たせない。
                let groups = Result { try WorkspaceItemGroups.load(from: directory) }
                let presentNames = WorkspaceDirectoryListing.namesIncludingHidden(of: directory)
                // A folder can look empty because every item carries the
                // hidden flag (desktop-cleanup tools do this to ~/Desktop).
                // Count what is really there — only for empty results, so the
                // extra enumeration costs nothing on the normal path.
                let hiddenCount = items.isEmpty && !showHidden
                    ? WorkspaceDirectoryListing.itemCountIncludingHidden(of: directory)
                    : 0
                guard !Task.isCancelled else { return }
                await self?.applyListing(
                    items,
                    for: directory,
                    hiddenItemCount: hiddenCount,
                    groups: groups,
                    presentNames: presentNames
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.applyListingFailure(error, for: directory)
            }
        }
    }

    private func applyListing(
        _ items: [WorkspaceItem],
        for directory: URL,
        hiddenItemCount: Int = 0,
        groups: Result<WorkspaceItemGroups?, any Error> = .success(nil),
        presentNames: Set<String> = []
    ) {
        guard navigator.currentDirectory == directory else { return }
        endLoadingIndicator()
        recursiveSearchErrorShown = false
        self.presentNames = presentNames

        // 読めなかった定義は「グループが無い」ことにしない。見出しは出せないが、
        // 出せなかったことは状態行に残す — 黙って消えると、書いたグループが
        // 失われたのか自分の書き方が悪いのか分からない。
        switch groups {
        case .success(let loaded):
            itemGroups = loaded
            itemGroupsError = nil
        case .failure(let error):
            itemGroups = nil
            itemGroupsError = "\(WorkspaceItemGroups.fileName) を読めません: \(error.localizedDescription)"
        }
        followExternalRenames(in: directory)

        allItems = items
        updateSearchResults()
        selectPendingItemIfNeeded()

        // 「空に見えるが実は全部隠しファイル」を無言の空リストにしない。
        // Silence here was reported as a bug twice (issue #2, then again after
        // v1.1.0); the folder must say why it shows nothing.
        let allHidden = items.isEmpty && hiddenItemCount > 0
        listingErrorLabel.stringValue = allHidden
            ? "このフォルダの\(hiddenItemCount)個の項目はすべて非表示（隠しファイル）です。"
            : ""
        listingErrorLabel.isHidden = !allHidden
        showHiddenButton.isHidden = !allHidden
        openSettingsButton.isHidden = true
        startCloudStatusRefresh(for: items, in: directory)
    }

    /// クラウドバッジは一覧を出したあとで埋める。File Provider配下（OneDrive等）
    /// では`ubiquitousItem*`の取得がプロバイダのデーモンとの往復になり、一覧の
    /// プリフェッチに混ぜると~/Documents/GitHubで最大62秒フォルダが出てこなかった。
    /// バッジは「いま無い」ことを伝える装飾で、一覧そのものより後でよい。
    private func startCloudStatusRefresh(for items: [WorkspaceItem], in directory: URL) {
        cloudStatusTask?.cancel()
        guard !items.isEmpty else { return }
        let urls = items.map(\.url)
        cloudStatusTask = Task.detached(priority: .utility) { [weak self] in
            guard let statuses = try? WorkspaceDirectoryListing.cloudStatuses(for: urls),
                  !statuses.isEmpty,
                  !Task.isCancelled else { return }
            await self?.applyCloudStatuses(statuses, for: directory)
        }
    }

    /// バッジが付く行だけを描き直す。`reloadData`は選択とスクロール位置を巻き戻す
    /// ので、あとから届く装飾には使わない — 一覧を読んでいる最中に足元が動く。
    private func applyCloudStatuses(
        _ statuses: [URL: WorkspaceCloudStatus],
        for directory: URL
    ) {
        guard navigator.currentDirectory == directory else { return }
        allItems = allItems.map { statuses[$0.url].map($0.withCloudStatus) ?? $0 }

        var changedRows = IndexSet()
        displayedItems = displayedItems.enumerated().map { index, item in
            guard let status = statuses[item.url] else { return item }
            changedRows.insert(index)
            return item.withCloudStatus(status)
        }
        guard !changedRows.isEmpty else { return }

        let nameColumn = fileTable.column(withIdentifier: Column.name)
        if nameColumn >= 0 {
            fileTable.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: nameColumn)
            )
        }
        galleryView.reloadItems(at: Set(changedRows.map { IndexPath(item: $0, section: 0) }))
    }

    /// The failure lives *in* the list, not in a transient alert. An alert is
    /// dismissed once and forgotten; what remained on screen was an empty list
    /// with no explanation — reported as "デスクトップのフォルダが何も表示され
    /// ない" (issue #2).
    private func applyListingFailure(_ error: any Error, for directory: URL) {
        guard navigator.currentDirectory == directory else { return }
        endLoadingIndicator()
        recursiveSearchErrorShown = false
        allItems = []
        updateSearchResults()

        let nsError = error as NSError
        let isPermission = nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileReadNoPermissionError
        listingErrorLabel.stringValue = isPermission
            ? "“\(directory.lastPathComponent)”を読む権限がありません。\nシステム設定 > プライバシーとセキュリティ で許可してください。"
            : "フォルダを読み込めません: \(error.localizedDescription)"
        listingErrorLabel.isHidden = false
        openSettingsButton.isHidden = !isPermission
        showHiddenButton.isHidden = true
    }

    private func configureListingErrorState() {
        listingErrorLabel.font = .systemFont(ofSize: 12)
        listingErrorLabel.textColor = IntegratedPanelTheme.secondaryText
        listingErrorLabel.alignment = .center
        listingErrorLabel.isHidden = true

        openSettingsButton.title = "システム設定を開く"
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.controlSize = .small
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openPrivacySettings)
        openSettingsButton.isHidden = true

        showHiddenButton.title = "隠しファイルを表示 (⇧⌘.)"
        showHiddenButton.bezelStyle = .rounded
        showHiddenButton.controlSize = .small
        showHiddenButton.target = self
        showHiddenButton.action = #selector(toggleHiddenFiles)
        showHiddenButton.isHidden = true

        let stack = NSStackView(views: [listingErrorLabel, openSettingsButton, showHiddenButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        fileArea.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: fileArea.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: fileArea.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: fileArea.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fileArea.trailingAnchor, constant: -24)
        ])
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// A local listing finishes in single-digit milliseconds, so showing the
    /// spinner immediately only produces a flash that reads as slowness. Delay it
    /// past the point where the wait is actually perceptible.
    private func beginLoadingIndicator() {
        loadingIndicatorTask?.cancel()
        loadingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.progress.startAnimation(nil)
            self.statusLabel.stringValue = "読み込み中…"
        }
    }

    private func endLoadingIndicator() {
        loadingIndicatorTask?.cancel()
        loadingIndicatorTask = nil
        progress.stopAnimation(nil)
    }

    @objc private func searchScopeChanged() {
        updateSearchResults()
    }

    private func updateSearchResults() {
        applyViewMode()
        if usesRecursiveSearch {
            startRecursiveSearch()
        } else {
            if recursiveSearchTask != nil {
                recursiveSearchTask?.cancel()
                endLoadingIndicator()
            }
            recursiveSearchTask = nil
            recursiveSearchGeneration &+= 1
            recursiveSearchIsTruncated = false
            applyFilterAndSort()
            if recursiveSearchErrorShown || !allItems.isEmpty {
                listingErrorLabel.isHidden = true
                openSettingsButton.isHidden = true
                showHiddenButton.isHidden = true
                recursiveSearchErrorShown = false
            }
        }
    }

    private func startRecursiveSearch() {
        recursiveSearchTask?.cancel()
        recursiveSearchGeneration &+= 1
        let generation = recursiveSearchGeneration
        let root = navigator.currentDirectory
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let showHidden = preferences.showHiddenFiles
        guard !query.isEmpty else { return }
        displayedItems = []
        fileTable.deselectAll(nil)
        galleryView.selectionIndexPaths = []
        reloadResultViews()
        updateStatus()
        beginLoadingIndicator()
        recursiveSearchTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try WorkspaceDirectoryListing.recursiveSearch(
                    in: root,
                    query: query,
                    showHiddenFiles: showHidden
                )
                guard !Task.isCancelled else { return }
                await self?.applyRecursiveSearch(
                    result,
                    root: root,
                    query: query,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.applyRecursiveSearchFailure(
                    error,
                    root: root,
                    query: query,
                    generation: generation
                )
            }
        }
    }

    private func applyRecursiveSearch(
        _ result: WorkspaceSearchResult,
        root: URL,
        query: String,
        generation: UInt
    ) {
        guard recursiveSearchGeneration == generation,
              navigator.currentDirectory == root,
              usesRecursiveSearch,
              searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else { return }
        endLoadingIndicator()
        recursiveSearchTask = nil
        recursiveSearchIsTruncated = result.isTruncated
        recursiveSearchErrorShown = false
        displayedItems = sortedItems(result.items)
        fileTable.deselectAll(nil)
        galleryView.selectionIndexPaths = []
        reloadResultViews()
        listingErrorLabel.isHidden = true
        openSettingsButton.isHidden = true
        showHiddenButton.isHidden = true
        updateStatus()
    }

    private func applyRecursiveSearchFailure(
        _ error: any Error,
        root: URL,
        query: String,
        generation: UInt
    ) {
        guard recursiveSearchGeneration == generation,
              navigator.currentDirectory == root,
              usesRecursiveSearch,
              searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else { return }
        endLoadingIndicator()
        recursiveSearchTask = nil
        recursiveSearchIsTruncated = false
        recursiveSearchErrorShown = true
        displayedItems = []
        fileTable.deselectAll(nil)
        galleryView.selectionIndexPaths = []
        reloadResultViews()
        listingErrorLabel.stringValue = "配下を検索できません: \(error.localizedDescription)"
        listingErrorLabel.isHidden = false
        openSettingsButton.isHidden = true
        showHiddenButton.isHidden = true
        updateStatus()
    }

    /// 見出しを挟んだ行の並びを組み直す。
    ///
    /// グループが定義されていなければ行と添字は一対一で、既存の一覧とまったく同じ形になる。
    /// 配下検索の結果にも見出しを出さない — 別の階層から集まった項目が並んでいて、
    /// 「このフォルダの中をどうまとめたか」とは無関係だから。
    private func rebuildFileRows() {
        guard preferences.listGrouping,
              let groups = itemGroups,
              !groups.groups.isEmpty,
              !usesRecursiveSearch else {
            fileRows = displayedItems.indices.map { .item(index: $0, otherGroups: []) }
            rowSections = Array(repeating: nil, count: fileRows.count)
            return
        }

        var indexByURL: [URL: Int] = [:]
        indexByURL.reserveCapacity(displayedItems.count)
        for (index, item) in displayedItems.enumerated() { indexByURL[item.url] = index }

        var rows: [FileRow] = []
        // 行がどの束の中に居るか。`FileRow.item`は「他の所属」しか持っていないので、
        // レールを引くにはこれが要る。行と同じ長さで並走させる。
        var sections: [SectionPlacement?] = []
        for section in groups.sections(for: displayedItems) {
            rows.append(.header(section.name, depth: section.depth))
            sections.append(nil)
            let collapsed = collapsedGroups.contains(section.name ?? Self.ungroupedTitle)
            for item in section.items where !collapsed {
                guard let index = indexByURL[item.url] else { continue }
                // 未分類の行に他所属は出ない。どこにも属していないからそこに居る。
                let others = section.name == nil
                    ? []
                    : groups.groupNames(for: item.name).filter { $0 != section.name }
                rows.append(.item(index: index, otherGroups: others))
                sections.append(section.name.map { SectionPlacement(name: $0, depth: section.depth) })
            }
        }
        fileRows = rows
        rowSections = sections
    }

    /// 名前セルの字下げ。見出しの三角の位置に項目のアイコンを揃える。
    ///
    /// 見出しが一本も無い一覧（グループでまとめないとき）では字下げしない。
    /// 束が無いのに左を空けても、名前の幅が減るだけ。
    private func nameIndent(atRow row: Int) -> CGFloat {
        guard rowSections.contains(where: { $0 != nil }) else { return 6 }
        let level = rowSections.indices.contains(row) ? (rowSections[row]?.depth ?? 0) : 0
        return WorkspaceGroupRail.x(atLevel: level) + WorkspaceGroupRail.width + 9
    }

    /// そのグループの親の色。外側から順。見出しのレールに使う。
    private func ancestorColors(ofGroup name: String?) -> [NSColor] {
        guard let name, let groups = itemGroups else { return [] }
        let colors = WorkspaceGroupPalette.colors(for: groups)
        return groups.ancestors(of: name).reversed().compactMap { colors[$0] }
    }

    /// その行のレールの色。親（外側）から順の色と、自分の束の色。
    ///
    /// 自分の束が複数あるのは、その項目が他のグループにも属しているとき。
    /// レールが縦に割れて、複数所属が色を読まずに形で分かる。
    private func rails(atRow row: Int) -> (ancestors: [NSColor], own: [NSColor]) {
        guard rowSections.indices.contains(row),
              let placement = rowSections[row],
              let groups = itemGroups else { return ([], []) }
        let colors = WorkspaceGroupPalette.colors(for: groups)
        // `ancestors(of:)`は近い順。レールは外側から並べるので裏返す。
        let ancestors = groups.ancestors(of: placement.name)
            .reversed()
            .compactMap { colors[$0] }
            .suffix(min(placement.depth, 4))
        let own = ([placement.name] + otherGroups(atRow: row)).compactMap { colors[$0] }
        return (Array(ancestors), own)
    }

    /// 行番号から項目を引く。見出しの行はnil。
    private func item(atRow row: Int) -> WorkspaceItem? {
        guard fileRows.indices.contains(row),
              case .item(let index, _) = fileRows[row] else { return nil }
        return displayedItems.indices.contains(index) ? displayedItems[index] : nil
    }

    /// この行が居るグループ以外の所属先。見出しの無い一覧では常に空。
    private func otherGroups(atRow row: Int) -> [String] {
        guard fileRows.indices.contains(row),
              case .item(_, let others) = fileRows[row] else { return [] }
        return others
    }

    /// 畳んであるグループの中身の数。行が無いので定義と一覧から数える。
    private func collapsedCount(of group: String?) -> Int {
        guard let groups = itemGroups else { return 0 }
        guard let group else {
            // 未分類は、どのグループにも属さないものの数。
            return displayedItems.filter { groups.groupNames(for: $0.name).isEmpty }.count
        }
        return displayedItems.filter { groups.groupNames(for: $0.name).contains(group) }.count
    }

    /// その見出しの下に何行続くか。見出しに数を出すために数える。
    private func fileRowCount(ofSectionStartingAt row: Int) -> Int {
        var count = 0
        var index = row + 1
        while index < fileRows.count, case .item = fileRows[index] {
            count += 1
            index += 1
        }
        return count
    }

    private func isHeaderRow(_ row: Int) -> Bool {
        guard fileRows.indices.contains(row), case .header = fileRows[row] else { return false }
        return true
    }

    /// その行の見出しの名前（未分類は`nil`）。
    private func headerName(atRow row: Int) -> String? {
        guard fileRows.indices.contains(row), case .header(let title, _) = fileRows[row] else {
            return nil
        }
        return title
    }

    /// 複数のグループに属する項目は複数の行にいるので、URLひとつが複数の行番号を返しうる。
    private func fileRowIndexes(matching urls: Set<URL>) -> IndexSet {
        IndexSet(fileRows.indices.filter { row in
            guard let item = item(atRow: row) else { return false }
            return urls.contains(item.url)
        })
    }

    /// グループに入れられるのは、いま開いているフォルダの直下にあるものだけ。メンバーを
    /// 相対名で持っているので、別の階層のものを入れても指せない。一つでも外から来て
    /// いれば`nil` — 半分だけ受け取ると、落とした本人には何が入ったか分からない。
    private func linkableNames(from sources: [URL]) -> [String]? {
        guard !sources.isEmpty else { return nil }
        let parent = navigator.currentDirectory.standardizedFileURL
        let names = sources.compactMap { url -> String? in
            let url = url.standardizedFileURL
            return url.deletingLastPathComponent() == parent ? url.lastPathComponent : nil
        }
        return names.count == sources.count ? names : nil
    }

    /// グループの定義を書き換えて保存する。
    ///
    /// 読めない定義があるときは断る。壊れたJSONの上から正常なJSONを書くと、
    /// 手で書いたグループが完全に消える — しかも「保存できた」ように見える。
    @discardableResult
    private func mutateGroups(
        actionName: String,
        _ change: (inout WorkspaceItemGroups) -> Void
    ) -> Bool {
        guard itemGroupsError == nil else {
            presentError(
                title: "グループを変更できません",
                message: "\(WorkspaceItemGroups.fileName) が読めない状態です。"
                    + "上書きすると、そこに書かれているグループが失われます。先にファイルを直してください。"
            )
            return false
        }
        var groups = itemGroups ?? WorkspaceItemGroups()
        change(&groups)
        return applyGroups(groups, actionName: actionName)
    }

    /// 定義を差し替えて画面に反映する。`nil`は「定義そのものが無い状態」で、
    /// グループを初めて作る操作を取り消したときにここへ戻る。
    @discardableResult
    private func applyGroups(_ groups: WorkspaceItemGroups?, actionName: String) -> Bool {
        let directory = navigator.currentDirectory
        let previous = itemGroups
        do {
            if let groups {
                try groups.save(to: directory)
            } else {
                let url = WorkspaceItemGroups.definitionURL(in: directory)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            presentError(title: "グループを保存できません", message: error.localizedDescription)
            return false
        }

        itemGroups = groups
        itemGroupsError = nil
        workspaceUndoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.applyGroups(previous, actionName: actionName) }
        }
        workspaceUndoManager?.setActionName(actionName)
        refreshRowsPreservingSelection()
        return true
    }

    /// グループだけが変わったときの再描画。一覧の中身は同じなので読み直さない。
    private func refreshRowsPreservingSelection() {
        let selected = selectedItems.map(\.url)
        rebuildFileRows()
        fileTable.reloadData()
        restoreFlatSelection(selected)
        updateStatus()
    }

    /// グループのメニューを、いまのフォルダの定義と選択に合わせて組み直す。
    ///
    /// ドラッグだけだと最初の一つを作れない — 落とす先の見出しがまだ無いので。
    /// 「新しいグループ…」がその入口で、ここから作ればJSONを手で書かずに始められる。
    private func rebuildGroupSubmenus(for selection: [WorkspaceItem]) {
        let names = linkableNames(from: selection.map(\.url))
        let canEdit = names != nil && itemGroupsError == nil
        let existing = itemGroups?.groups.map(\.name) ?? []

        addToGroupItem.isEnabled = canEdit
        let addMenu = NSMenu()
        for name in existing {
            // すでに全員が入っているグループは、選んでも何も起きない。
            let allInside = names?.allSatisfy { member in
                itemGroups?.groupNames(for: member).contains(name) == true
            } ?? false
            let item = NSMenuItem(title: name, action: #selector(addSelectionToGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.isEnabled = canEdit && !allInside
            item.state = allInside ? .on : .off
            addMenu.addItem(item)
        }
        if !existing.isEmpty { addMenu.addItem(.separator()) }
        let newGroup = NSMenuItem(title: "新しいグループ…", action: #selector(createGroupWithSelection), keyEquivalent: "")
        newGroup.target = self
        newGroup.isEnabled = canEdit
        addMenu.addItem(newGroup)
        addToGroupItem.submenu = addMenu

        // 外せるグループは、選んだものが実際に入っているグループだけ。
        let joined = names.map { members in
            existing.filter { name in
                members.contains { itemGroups?.groupNames(for: $0).contains(name) == true }
            }
        } ?? []
        removeFromGroupItem.isEnabled = canEdit && !joined.isEmpty
        let removeMenu = NSMenu()
        for name in joined {
            let item = NSMenuItem(
                title: name,
                action: #selector(removeSelectionFromGroup(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = name
            removeMenu.addItem(item)
        }
        if joined.count > 1 {
            removeMenu.addItem(.separator())
            let all = NSMenuItem(
                title: "すべてのグループから外す",
                action: #selector(removeSelectionFromAllGroups),
                keyEquivalent: ""
            )
            all.target = self
            removeMenu.addItem(all)
        }
        removeFromGroupItem.submenu = removeMenu
    }

    @objc private func addSelectionToGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        mutateGroups(actionName: "「\(name)」に入れる") { groups in
            members.forEach { groups.add($0, to: name) }
        }
    }

    @objc private func removeSelectionFromGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        mutateGroups(actionName: "「\(name)」から外す") { groups in
            members.forEach { groups.remove($0, from: name) }
        }
    }

    @objc private func removeSelectionFromAllGroups() {
        guard let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        mutateGroups(actionName: "すべてのグループから外す") { groups in
            members.forEach { groups.removeFromAllGroups($0) }
        }
    }

    /// 定義に残っているが実物が無いメンバーを、まとめて外す。
    ///
    /// 見出しを組むときは黙って落としている。それは別のマシンにしか無いフォルダの
    /// 定義を守るためだが、**消したフォルダ**の名前も同じように落ちるので、定義に
    /// ゴミが残り続けても気づけない。かといって勝手に消すのも危ない — 向こうの
    /// マシンではまだ使っている。数を島に出して気づけるようにし、外すかどうかは
    /// 一覧を見せてから本人に決めてもらう。
    @objc func pruneMissingGroupMembers() {
        pruneMissingMembers(in: nil)
    }

    /// - Parameter groupName: 名前を渡すとその束だけ。`nil`なら全部の束。
    ///   地図の島の「見つからない N →」は、押した島のことを聞いている。
    func pruneMissingMembers(in groupName: String?) {
        guard itemGroupsError == nil else { return }
        var missing = itemGroups?.missingMembers(amongNames: presentNames) ?? [:]
        if let groupName {
            missing = missing.filter { $0.key == groupName }
        }
        guard !missing.isEmpty else { return }

        let total = missing.values.reduce(0) { $0 + $1.count }
        let detail = missing.keys.sorted().map { name in
            "「\(name)」 " + (missing[name] ?? []).joined(separator: "、")
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = groupName.map { "「\($0)」の見つからない\(total)件を外しますか？" }
            ?? "見つからない\(total)件を、すべてのグループから外しますか？"
        alert.informativeText = "定義に名前は残っていますが、このフォルダに実物がありません。"
            + "移動したか、消したか、別のマシンにしか無いかのどれかです。"
            + "別のマシンにあるものを外すと、そちらでもグループから消えます。\n\n"
            + detail
        alert.addButton(withTitle: "外す")
        alert.addButton(withTitle: "残す")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let names = presentNames
        let actionName = groupName.map { "「\($0)」の見つからない項目を外す" } ?? "見つからない項目を外す"
        mutateGroups(actionName: actionName) { groups in
            groups.pruneMissingMembers(amongNames: names, in: groupName)
        }
    }

    @objc private func pruneContextGroupMissing() {
        guard let name = contextGroupName else { return }
        pruneMissingMembers(in: name)
    }

    @objc func createGroupWithSelection() {
        guard let members = linkableNames(from: selectedItems.map(\.url)) else { return }
        guard let name = askForGroupName() else { return }
        mutateGroups(actionName: "「\(name)」を作る") { groups in
            members.forEach { groups.add($0, to: name) }
        }
    }

    /// グループの名前を聞く。空白だけの名前と、すでにある名前は断る — 同じ名前のグループが
    /// 二つあると、どちらの見出しに落としたのか区別できない。
    private func askForGroupName(
        title: String = "新しいグループ",
        message: String = "選んだものをまとめる名前を入れてください。フォルダは動きません。",
        initial: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: initial.isEmpty ? "作成" : "変更")
        alert.addButton(withTitle: "キャンセル")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "ツール開発"
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // 名前を変えないまま確定したときは、何もしないのが正しい。
        guard name != initial else { return nil }
        guard itemGroups?.groups.contains(where: { $0.name == name }) != true else {
            presentError(
                title: "同じ名前のグループがあります",
                message: "「\(name)」はすでにあります。黙って一つにまとめると元に戻せません。"
            )
            return nil
        }
        return name
    }

    /// 見出しに落とされたものをグループに紐づける。ファイルは動かない。
    private func linkSources(_ sources: [URL], toGroupAtRow row: Int) -> Bool {
        guard fileRows.indices.contains(row),
              case .header(let title, _) = fileRows[row],
              let names = linkableNames(from: sources) else { return false }

        // 未分類はグループではなく「どのグループにも居ない場所」。そこへ落とすのは外す操作。
        guard let title else {
            return mutateGroups(actionName: "グループから外す") { groups in
                names.forEach { groups.removeFromAllGroups($0) }
            }
        }
        return mutateGroups(actionName: "「\(title)」に入れる") { groups in
            names.forEach { groups.add($0, to: title) }
        }
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = query.isEmpty
            ? allItems
            : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
        // 「未分類だけ」。まだどこにも入れていないものを片付けるための眺め方。
        if preferences.listUngroupedOnly, let groups = itemGroups {
            items = items.filter { groups.groupNames(for: $0.name).isEmpty }
        }
        // 「グループのものだけ」。定義が読めていないときは絞らない — 読めないことと
        // 「どれも属していない」ことは違うのに、絞ると後者に見えてしまう。
        if preferences.listGroupedOnly, itemGroupsError == nil {
            let groups = itemGroups
            items = items.filter { !(groups?.groupNames(for: $0.name).isEmpty ?? true) }
        }
        displayedItems = sortedItems(items)
        reloadResultViews()
        updateStatus()
    }

    private func sortedItems(_ source: [WorkspaceItem]) -> [WorkspaceItem] {
        var items = source
        items.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch sortIdentifier {
            case Column.modified:
                comparison = (lhs.modifiedAt ?? .distantPast).compare(rhs.modifiedAt ?? .distantPast)
            case Column.size:
                let left = lhs.fileSize ?? 0
                let right = rhs.fileSize ?? 0
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case Column.kind:
                comparison = (lhs.typeDescription ?? "").localizedStandardCompare(rhs.typeDescription ?? "")
            case Column.groups:
                // どこにも属さないものは末尾へ。空文字は先頭に来てしまう。
                let left = itemGroups?.groupNames(for: lhs.name).joined(separator: ", ") ?? ""
                let right = itemGroups?.groupNames(for: rhs.name).joined(separator: ", ") ?? ""
                comparison = (left.isEmpty ? "\u{10FFFF}" : left)
                    .localizedStandardCompare(right.isEmpty ? "\u{10FFFF}" : right)
            default:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            }
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return items
    }

    private func reloadResultViews() {
        fileTable.reloadData()
        galleryView.reloadData()
        // 地図は値を渡して組む方式なので、ここで渡し直さないと空のままになる。
        // `updateSearchResults`は`applyViewMode`を先に呼び、`displayedItems`が
        // 入るのはそのあと — 開いた直後の地図が空だったのはそれが理由だった。
        if effectiveViewMode == .map {
            mapView.currentDirectory = navigator.currentDirectory
            mapView.show(items: displayedItems, groups: itemGroups, presentNames: presentNames)
        }
    }

    /// グループを作れるのは、いまのフォルダの直下を選んでいるときだけ。
    /// 押せない理由が見えないので、押せないことを見せる。
    private func updateNewGroupButton() {
        newGroupButton.isEnabled = canEditGroupsForSelection
    }

    private func updateStatus() {
        updateNewGroupButton()
        let selectedCount = selectedItems.count
        let prefix = usesRecursiveSearch ? "配下検索: " : ""
        let truncation = recursiveSearchIsTruncated ? "（上限5,000件）" : ""
        let warning = itemGroupsError.map { " ⚠︎ \($0)" } ?? ""
        statusLabel.stringValue = selectedCount > 0
            ? "\(prefix)\(displayedItems.count)項目\(truncation) — \(selectedCount)項目を選択\(warning)"
            : "\(prefix)\(displayedItems.count)項目\(truncation)\(warning)"
    }

    private var selectedItems: [WorkspaceItem] {
        switch effectiveViewMode {
        case .column:
            return columnView.selectedItems
        case .gallery:
            return galleryView.selectionIndexPaths
                .sorted { $0.item < $1.item }
                .compactMap { indexPath in
                displayedItems.indices.contains(indexPath.item)
                    ? displayedItems[indexPath.item]
                    : nil
            }
        case .map:
            return mapView.selectedItems
        case .list:
            break
        }
        // 同じ項目が複数のグループに並ぶので、行をそのまま集めると同じものが二度入る。
        var seen: Set<URL> = []
        return fileTable.selectedRowIndexes.compactMap { row in
            guard let item = item(atRow: row), seen.insert(item.url).inserted else { return nil }
            return item
        }
    }

    /// Listとgalleryは同じflatな結果集合なので、表示を替えても選択を失わない。
    /// Columnの深い階層から来た項目は現在の結果に無ければ安全に無視する。
    private func restoreFlatSelection(_ urls: [URL]) {
        let wanted = Set(urls)
        // listは見出しの分だけ行がずれ、複数のグループに属する項目は複数の行にいる。
        // galleryは見出しを持たないので添字のまま。
        fileTable.selectRowIndexes(fileRowIndexes(matching: wanted), byExtendingSelection: false)
        galleryView.selectionIndexPaths = Set(
            displayedItems.indices
                .filter { wanted.contains(displayedItems[$0].url) }
                .map { IndexPath(item: $0, section: 0) }
        )
        mapView.select(urls: urls)
        updateStatus()
    }

    private func selectPendingItemIfNeeded() {
        guard let pendingSelectionURL,
              let index = displayedItems.firstIndex(where: { $0.url == pendingSelectionURL }) else {
            self.pendingSelectionURL = nil
            return
        }
        fileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        fileTable.scrollRowToVisible(index)
        galleryView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        galleryView.scrollToItems(
            at: [IndexPath(item: index, section: 0)],
            scrollPosition: .nearestVerticalEdge
        )
        self.pendingSelectionURL = nil
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

    @objc func goBack() {
        guard navigator.goBack() != nil else { return }
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    @objc func goForward() {
        guard navigator.goForward() != nil else { return }
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    @objc func goUp() {
        guard navigator.goUp() != nil else { return }
        navigate(to: navigator.currentDirectory, addHistory: false)
    }

    @objc func refresh() {
        reloadContents()
        if preferences.usesColumnView { columnView.reloadCurrent() }
    }

    @objc func openFolderChooser() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = navigator.currentDirectory
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.navigate(to: url)
        }
    }

    @objc func openSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        for item in items {
            if item.isDirectory {
                navigate(to: item.url)
                break
            }
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc func revealSelectionInFinder() {
        let urls = selectedItems.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [navigator.currentDirectory] : urls)
    }

    private var workspaceUndoManager: UndoManager? { view.window?.undoManager }

    @objc func createFolder() {
        do {
            let created = try fileService.createFolder(in: navigator.currentDirectory)
            // Undoing a creation trashes it rather than deleting outright, so a
            // mistaken undo is still recoverable from the Finder trash.
            workspaceUndoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    try? target.fileService.moveToTrash([created])
                    target.reloadContents()
                }
            }
            workspaceUndoManager?.setActionName("新規フォルダ")
            searchField.stringValue = ""
            pendingSelectionURL = created
            reloadContents()
        } catch {
            presentError(title: "フォルダを作成できません", message: error.localizedDescription)
        }
    }

    /// Renaming registers its own inverse, so undo and redo are the same code path.
    private func renameItem(at source: URL, to newName: String) {
        let originalName = source.lastPathComponent
        do {
            let renamed = try fileService.rename(source, to: newName)
            guard renamed != source else { return }
            // 束はメンバーを**名前**で持っている。名前を変えたら定義も付いていく。
            // 付いていかないと、束に入れたフォルダの名前を変えただけで
            // 「見つからない」に化ける（実体を動かさずにまとめる、という約束に反する）。
            followRenameInGroups(from: source, to: renamed)
            workspaceUndoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.renameItem(at: renamed, to: originalName)
                }
            }
            workspaceUndoManager?.setActionName("名前の変更")
            searchField.stringValue = ""
            if navigator.relocatePathPrefix(from: source, to: renamed) {
                pendingSelectionURL = nil
                navigate(to: navigator.currentDirectory, addHistory: false)
            } else {
                pendingSelectionURL = renamed
                reloadContents()
                if preferences.usesColumnView {
                    columnView.reloadAfterRename(from: source, to: renamed)
                }
            }
        } catch {
            presentError(title: "名前を変更できません", message: error.localizedDescription)
        }
    }

    /// 名前を変えた項目を、グループの定義でも書き換える。
    ///
    /// いまのフォルダの直下のものだけ。定義は相対名で持つので、別の階層のものは
    /// 指せない（そこを触ると、名前が同じ別のものを巻き込む）。
    /// 外（Finderやシェル）で名前を変えられたとき、束の定義を追わせる。
    ///
    /// 推測では結ばない。アプリがその一覧を一度見ていれば、消えた名前が持っていた
    /// ファイルの同一性を覚えていられる。増えた名前がそれと**一致したときだけ**
    /// 書き換える（`WorkspaceRenameTracker`）。追えないものは「見つからない」に残す。
    private func followExternalRenames(in directory: URL) {
        guard itemGroupsError == nil, var groups = itemGroups, !groups.groups.isEmpty else { return }
        let renames = renameTracker.follow(
            directory: directory.standardizedFileURL,
            present: presentNames,
            members: Set(groups.groups.flatMap(\.members)),
            identity: { Self.fileIdentity(of: directory.appendingPathComponent($0)) }
        )
        guard !renames.isEmpty else { return }
        for rename in renames { groups.renameMember(rename.from, to: rename.to) }
        do {
            try groups.save(to: directory)
            itemGroups = groups
        } catch {
            itemGroupsError = "\(WorkspaceItemGroups.fileName) を保存できません: \(error.localizedDescription)"
        }
    }

    /// ファイルの同一性。ボリューム・inode・作成時刻。
    ///
    /// inode だけでは足りない — 消したあとに作られたものが同じ番号を貰うことがある。
    /// 作成時刻まで揃うことは偶然では起きないので、二つ合わせて「同じもの」と言える。
    static func fileIdentity(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? UInt64,
              let device = attributes[.systemNumber] as? Int else { return nil }
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(device):\(inode):\(created)"
    }

    private func followRenameInGroups(from source: URL, to renamed: URL) {
        guard itemGroupsError == nil, var groups = itemGroups else { return }
        let parent = source.deletingLastPathComponent().standardizedFileURL
        guard parent == navigator.currentDirectory.standardizedFileURL else { return }
        let oldName = source.lastPathComponent
        let newName = renamed.lastPathComponent
        guard !groups.groupNames(for: oldName).isEmpty else { return }
        groups.renameMember(oldName, to: newName)
        do {
            try groups.save(to: navigator.currentDirectory)
            itemGroups = groups
        } catch {
            // 実体の名前は既に変わっている。定義だけ古いまま黙って進むと、
            // 束から落ちた理由が分からなくなる。
            itemGroupsError = "\(WorkspaceItemGroups.fileName) を保存できません: \(error.localizedDescription)"
        }
    }

    private func beginListRename(at row: Int) {
        guard let item = item(atRow: row),
              fileTable.selectedRowIndexes == IndexSet(integer: row) else { return }
        fileTable.scrollRowToVisible(row)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.item(atRow: row)?.url == item.url,
                  let nameColumn = self.fileTable.tableColumns.firstIndex(
                    where: { $0.identifier == Column.name }
                  ),
                  let cell = self.fileTable.view(
                    atColumn: nameColumn,
                    row: row,
                    makeIfNecessary: true
                  ) as? WorkspaceNameCellView else { return }
            cell.beginRenaming(name: item.name, isDirectory: item.isDirectory) { [weak self] name in
                self?.renameItem(at: item.url, to: name)
            }
        }
    }

    private func beginGalleryRename(at indexPath: IndexPath) {
        guard displayedItems.indices.contains(indexPath.item),
              galleryView.selectionIndexPaths == [indexPath] else { return }
        let item = displayedItems[indexPath.item]
        galleryView.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.displayedItems.indices.contains(indexPath.item),
                  self.displayedItems[indexPath.item].url == item.url,
                  let galleryItem = self.galleryView.item(at: indexPath) as? WorkspaceGalleryItem
            else { return }
            galleryItem.beginRenaming(
                name: item.name,
                isDirectory: item.isDirectory
            ) { [weak self] name in
                self?.renameItem(at: item.url, to: name)
            }
        }
    }

    @discardableResult
    private func transferItems(
        _ sources: [URL],
        to destination: URL,
        copy: Bool
    ) -> [(source: URL, destination: URL)]? {
        do {
            let results = try fileService.transfer(sources, to: destination, copy: copy)
            registerTransferUndo(results, copy: copy)
            reloadContents()
            return results
        } catch {
            presentError(
                title: copy ? "ファイルをコピーできません" : "ファイルを移動できません",
                message: error.localizedDescription
            )
            return nil
        }
    }

    private func registerTransferUndo(
        _ results: [(source: URL, destination: URL)],
        copy: Bool
    ) {
        guard let undoManager = workspaceUndoManager, !results.isEmpty else { return }
        if copy {
            // The originals were untouched, so undo only has to remove the copies.
            let copies = results.map(\.destination)
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    try? target.fileService.moveToTrash(copies)
                    target.reloadContents()
                }
            }
            undoManager.setActionName("コピー")
        } else {
            // Sources may come from several folders, so each item is returned to
            // its own parent. Grouping keeps that a single undo/redo step.
            let moves = results.map {
                (current: $0.destination, parent: $0.source.deletingLastPathComponent())
            }
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.undoMoves(moves)
                }
            }
            undoManager.setActionName("移動")
        }
    }

    private func undoMoves(_ moves: [(current: URL, parent: URL)]) {
        workspaceUndoManager?.beginUndoGrouping()
        for move in moves {
            transferItems([move.current], to: move.parent, copy: false)
        }
        workspaceUndoManager?.endUndoGrouping()
    }

    @objc func renameSelection() {
        guard selectedItems.count == 1 else { return }
        switch effectiveViewMode {
        case .column:
            columnView.beginRenamingSelection()
        case .gallery:
            guard let indexPath = galleryView.selectionIndexPaths.first else { return }
            beginGalleryRename(at: indexPath)
        case .list:
            beginListRename(at: fileTable.selectedRow)
        case .map:
            // 地図の点の脇のラベルは表示であって入力欄ではない。右の一覧には
            // フォルダの全部が出ているので、そちらの同じ行で書き換える。
            _ = mapView.beginRenameFromKeyboard()
        }
    }

    @objc func trashSelection() {
        let items = selectedItems
        guard !items.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? "“\(items[0].name)”をゴミ箱に入れますか？"
            : "\(items.count)項目をゴミ箱に入れますか？"
        alert.informativeText = "完全削除ではありません。Finderのゴミ箱から戻せます。"
        alert.addButton(withTitle: "ゴミ箱に入れる")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.fileService.moveToTrash(items.map(\.url))
                self.reloadContents()
            } catch {
                self.presentError(title: "ゴミ箱へ移動できません", message: error.localizedDescription)
            }
        }
    }

    /// The bottom ribbon's crumbs: same URLs, own control.
    @objc func ribbonComponentClicked() {
        guard let clicked = ribbonPath.clickedPathItem,
              let index = ribbonPath.pathItems.firstIndex(of: clicked),
              pathComponentURLs.indices.contains(index) else { return }
        navigate(to: pathComponentURLs[index])
    }

    @objc func toggleTerminal() {
        onToggleTerminal?()
    }

    /// Pins the selected folders, or the current one when nothing is selected —
    /// the folder you are looking at is the one you usually mean.
    @objc func togglePin() {
        let targets = selectedItems.filter(\.isDirectory).map(\.url)
        let urls = targets.isEmpty ? [navigator.currentDirectory] : targets
        var pins = preferences.pins

        // Mixed selections would make a toggle ambiguous, so the first item
        // decides: if it is pinned this unpins, otherwise it pins.
        let shouldUnpin = urls.first.map(pins.contains) ?? false
        var refused: [String] = []
        for url in urls {
            if shouldUnpin {
                pins.unpin(url)
            } else if !pins.pin(url), !pins.contains(url) {
                refused.append(url.lastPathComponent)
            }
        }
        preferences.pins = pins
        rebuildSidebar()

        guard !refused.isEmpty else { return }
        presentError(
            title: "ピン留めできません",
            message: "ピン留めは\(WorkspacePins.capacity)件までです。"
                + "サイドバーで不要なものを解除してください。"
        )
    }

    @objc func showInfo() {
        let targets = selectedItems.map(\.url)
        for url in (targets.isEmpty ? [navigator.currentDirectory] : targets) {
            WorkspaceInfoWindowController.show(for: url)
        }
    }

    @objc func copySelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        fileClipboard.write(urls, operation: .copy)
    }

    @objc func cutSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        fileClipboard.write(urls, operation: .move)
    }

    /// Reads ordinary file URLs, so Finder copies paste here. A cut created by
    /// this running FinderAI instance moves instead and is consumed after use.
    @objc func pasteIntoCurrentFolder() {
        guard let contents = fileClipboard.read(),
              fileClipboard.canPaste(into: navigator.currentDirectory) else { return }
        let copy = contents.operation == .copy
        guard let results = transferItems(
            contents.urls,
            to: navigator.currentDirectory,
            copy: copy
        ) else { return }
        if !copy {
            fileClipboard.finishMove(with: results.map(\.destination))
        }
    }

    // Standard edit actions. Keeping these on the responder chain means an
    // active text editor or Terminal receives ⌘X/⌘C/⌘V before the browser does.
    @objc func copy(_ sender: Any?) { copySelection() }
    @objc func cut(_ sender: Any?) { cutSelection() }
    @objc func paste(_ sender: Any?) { pasteIntoCurrentFolder() }

    @objc func duplicateSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            var created: [URL] = []
            for url in urls { created.append(try fileService.duplicate(url)) }
            registerTrashUndo(created, actionName: "複製")
            pendingSelectionURL = created.first
            reloadContents()
        } catch {
            presentError(title: "複製できません", message: error.localizedDescription)
        }
    }

    @objc func makeAliasForSelection() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            var created: [URL] = []
            for url in urls { created.append(try fileService.makeAlias(for: url)) }
            registerTrashUndo(created, actionName: "エイリアスを作成")
            pendingSelectionURL = created.first
            reloadContents()
        } catch {
            presentError(title: "エイリアスを作成できません", message: error.localizedDescription)
        }
    }

    /// Zipping a big folder takes real time, so it runs off the main actor and the
    /// spinner is left to say so.
    @objc func compressSelection() {
        let urls = selectedItems.map(\.url)
        let targets = urls.isEmpty ? [navigator.currentDirectory] : urls
        let directory = navigator.currentDirectory
        beginLoadingIndicator()

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try WorkspaceArchiver.archive(targets, in: directory) }
            }.value
            guard let self else { return }
            self.endLoadingIndicator()
            switch result {
            case .success(let archive):
                self.registerTrashUndo([archive], actionName: "圧縮")
                self.pendingSelectionURL = archive
                self.reloadContents()
            case .failure(let error):
                self.presentError(title: "圧縮できません", message: error.localizedDescription)
            }
        }
    }

    /// Undo for anything that creates files: put them in the trash, so a mistaken
    /// undo is still recoverable.
    private func registerTrashUndo(_ created: [URL], actionName: String) {
        guard let undoManager = workspaceUndoManager, !created.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                try? target.fileService.moveToTrash(created)
                target.reloadContents()
            }
        }
        undoManager.setActionName(actionName)
    }

    @objc func toggleHiddenFiles() {
        preferences.showHiddenFiles.toggle()
        reloadContents()
        if preferences.usesColumnView {
            columnView.show(
                directory: navigator.currentDirectory,
                showHiddenFiles: preferences.showHiddenFiles
            )
        }
    }

    @objc func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    /// ⌘L, or a click on the breadcrumb's empty space. Shows the real path,
    /// selected, so it can be copied or replaced outright.
    /// ⌘L: focus the address bar with the whole path selected, ready to copy
    /// or replace.
    @objc func beginPathEditing() {
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    /// The field is permanent; ending an edit restores the truth and hands
    /// focus back to the list.
    private func endPathEditing() {
        pathField.stringValue = Self.plainPath(for: navigator.currentDirectory)
        view.window?.makeFirstResponder(firstResponderForCurrentMode)
    }

    /// Accepts what a user actually pastes: `~`, a trailing slash, surrounding
    /// quotes or spaces from a copied path, and a `file://` URL.
    private func commitPathEditing() {
        guard let candidate = WorkspacePathInput.parse(pathField.stringValue) else {
            endPathEditing()
            return
        }
        endPathEditing()

        // A path pointing at a file opens it and stays put; that is what typing
        // one means, and navigating to its parent instead would be a guess.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            presentError(
                title: "その場所が見つかりません",
                message: "“\(candidate.path(percentEncoded: false))”は存在しません。"
            )
            return
        }
        if isDirectory.boolValue {
            navigate(to: candidate)
        } else {
            NSWorkspace.shared.open(candidate)
        }
    }

    /// Finder's ⌥⌘C: the selection's path names, or the folder's when nothing
    /// is selected.
    @objc func copyCurrentPath() {
        let urls = selectedItems.isEmpty
            ? [navigator.currentDirectory]
            : selectedItems.map(\.url)
        copyToPasteboard(urls.map(Self.plainPath(for:)).joined(separator: "\n"))
    }

    /// The path-bar variant always means the folder on screen, regardless of
    /// what happens to be selected in the listing.
    @objc func copyCurrentFolderPath() {
        copyToPasteboard(Self.plainPath(for: navigator.currentDirectory))
    }

    /// Pasting a bare path after a typed `cd ` breaks on spaces and quotes, so
    /// this hands over the whole command already escaped — moving a shell to
    /// the folder on screen becomes copy, paste, return.
    @objc func copyChangeDirectoryCommand() {
        copyToPasteboard(
            ShellQuoting.changeDirectoryCommand(
                forPath: Self.plainPath(for: navigator.currentDirectory)
            )
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The toolbar button confirms itself: a silent copy leaves the user
    /// wondering whether anything reached the clipboard.
    @objc private func copyCDFromButton() {
        copyChangeDirectoryCommand()
        copyCDButton.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "コピーしました"
        )
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.copyCDButton.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "“cd” コマンドをコピー"
            )
        }
    }

    /// Directory URLs render with a trailing slash; people expect the Finder
    /// form without one everywhere a path is copied.
    private static func plainPath(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Jumps to the folder the real Finder's front window is showing — the
    /// bridge in the opposite direction of 「Finderで表示」.
    @objc func openFinderLocation() {
        Task { [weak self] in
            let result = await FinderFrontWindow.currentFolder()
            guard let self else { return }
            switch result {
            case .success(let url):
                self.navigate(to: url)
            case .failure(.noWindow):
                self.presentError(
                    title: "Finderの現在地を開けません",
                    message: "macOS Finderのウインドウが開いていません。"
                )
            case .failure(.notAuthorized):
                self.presentError(
                    title: "Finderの現在地を開けません",
                    message: "システム設定 > プライバシーとセキュリティ > オートメーション で、"
                        + "FinderAIからFinderへの制御を許可してください。"
                )
            case .failure(.failed(let message)):
                self.presentError(
                    title: "Finderの現在地を開けません",
                    message: message.isEmpty ? "Finderの場所を取得できませんでした。" : message
                )
            }
        }
    }

    @objc func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Quick Look

extension WorkspaceBrowserViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !selectedItems.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookURLs = selectedItems.map(\.url)
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookURLs = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs.indices.contains(index) ? quickLookURLs[index] as NSURL : nil
    }

    /// Lets the preview panel forward arrow keys back to the table so the user can
    /// keep moving through the list while previewing.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if effectiveViewMode == .gallery {
            galleryView.keyDown(with: event)
        } else {
            fileTable.keyDown(with: event)
        }
        return true
    }
}

extension WorkspaceBrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebarTable ? sidebarRows.count : fileRows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === sidebarTable else { return isHeaderRow(row) }
        guard sidebarRows.indices.contains(row) else { return false }
        if case .header = sidebarRows[row] { return true }
        return false
    }

    /// Headers are labels, not destinations.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    /// 行の左端にレールを引くための行ビュー。一覧だけ差し替える。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView === fileTable else { return nil }
        let view = tableView.makeView(
            withIdentifier: WorkspaceGroupedRowView.id,
            owner: self
        ) as? WorkspaceGroupedRowView ?? {
            let created = WorkspaceGroupedRowView()
            created.identifier = WorkspaceGroupedRowView.id
            return created
        }()
        let rails = rails(atRow: row)
        view.show(ancestors: rails.ancestors, own: rails.own)
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === sidebarTable else {
            // 見出しは本文より5pt高い。26pt対27ptでは段差にならず、見出しが
            // 「束の始まり」ではなく「ただの行」に見えていた。
            return self.tableView(tableView, isGroupRow: row) ? 32 : 27
        }
        // 詰めた行高: よく使うフォルダをスクロールなしで一覧できる数が優先。
        return self.tableView(tableView, isGroupRow: row) ? 20 : 23
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === sidebarTable {
            guard sidebarRows.indices.contains(row) else { return nil }
            switch sidebarRows[row] {
            case .header(let title):
                let cell = tableView.makeView(
                    withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceSidebarHeader"),
                    owner: self
                ) as? WorkspaceSidebarHeaderView ?? WorkspaceSidebarHeaderView()
                cell.configure(title: title)
                return cell
            case .item(let item):
                let cell = tableView.makeView(
                    withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceSidebarCell"),
                    owner: self
                ) as? WorkspaceSidebarCellView ?? WorkspaceSidebarCellView()
                cell.configure(title: item.title, symbol: item.symbol)
                cell.toolTip = item.url.path(percentEncoded: false)
                return cell
            }
        }

        // グループの見出し。名前列を持たない一行で、列の途中から始まると見出しに見えない。
        if fileRows.indices.contains(row), case .header(let title, let depth) = fileRows[row] {
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceGroupHeader"),
                owner: self
            ) as? WorkspaceGroupHeaderView ?? WorkspaceGroupHeaderView()
            let name = title ?? Self.ungroupedTitle
            let collapsed = collapsedGroups.contains(name)
            cell.configure(
                title: name,
                // 畳んでいるときは行が無いので、定義から数える。
                count: collapsed
                    ? collapsedCount(of: title)
                    : fileRowCount(ofSectionStartingAt: row),
                color: title.flatMap { WorkspaceGroupPalette.color(for: $0, in: itemGroups) },
                isCollapsed: collapsed,
                depth: depth,
                ancestorColors: ancestorColors(ofGroup: title),
                inChildren: title.map {
                    itemGroups?.descendantMemberCount(of: $0, among: presentNames) ?? 0
                } ?? 0
            )
            return cell
        }

        guard let item = item(atRow: row), let tableColumn else { return nil }
        if tableColumn.identifier == Column.name {
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceNameCell"),
                owner: self
            ) as? WorkspaceNameCellView ?? WorkspaceNameCellView()
            cell.representedURL = item.url
            let others = otherGroups(atRow: row)
            let colors = WorkspaceGroupPalette.colors(for: itemGroups)
            cell.configure(
                name: item.relativePath ?? item.name,
                image: WorkspaceIconProvider.shared.quickIcon(for: item),
                cloud: item.cloudStatus,
                otherGroups: others,
                otherColors: others.compactMap { colors[$0] },
                indent: nameIndent(atRow: row)
            )
            WorkspaceIconProvider.shared.resolveIcon(for: item) { [weak cell] image in
                guard let cell, cell.representedURL == item.url else { return }
                cell.updateIcon(image)
            }
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("WorkspaceTextCell-\(tableColumn.identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = IntegratedPanelTheme.secondaryText
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        switch tableColumn.identifier {
        case Column.modified:
            cell.textField?.stringValue = item.modifiedAt.map(Self.dateFormatter.string) ?? "—"
        case Column.size:
            cell.textField?.stringValue = item.isDirectory
                ? "—"
                : item.fileSize.map(Self.byteFormatter.string(fromByteCount:)) ?? "—"
        case Column.kind:
            cell.textField?.stringValue = item.typeDescription ?? "—"
        case Column.groups:
            let names = itemGroups?.groupNames(for: item.name) ?? []
            cell.textField?.stringValue = names.isEmpty ? "—" : names.joined(separator: ", ")
            cell.toolTip = names.isEmpty ? nil : names.joined(separator: "、")
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === fileTable else {
            guard let row = sidebarTable.selectedRowIndexes.first,
                  sidebarRows.indices.contains(row),
                  case .item(let item) = sidebarRows[row],
                  item.url != navigator.currentDirectory else { return }
            navigate(to: item.url)
            return
        }
        updateStatus()
        refreshQuickLookIfVisible()
    }

    private func refreshQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible,
              panel.dataSource === self else { return }
        quickLookURLs = selectedItems.map(\.url)
        panel.reloadData()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === fileTable, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        applySort(NSUserInterfaceItemIdentifier(key), ascending: descriptor.ascending)
    }

    /// 並べ替えを決める。一覧の列見出しからも、地図の右の一覧の列見出しからも
    /// ここへ来る。**順序は一つ**で、表示を替えても並びが変わらない。
    func applySort(_ identifier: NSUserInterfaceItemIdentifier, ascending: Bool) {
        guard sortIdentifier != identifier || sortAscending != ascending else { return }
        sortIdentifier = identifier
        sortAscending = ascending
        preferences.sortColumn = identifier.rawValue
        preferences.sortAscending = ascending
        fileTable.sortDescriptors = [
            NSSortDescriptor(key: identifier.rawValue, ascending: ascending)
        ]
        if usesRecursiveSearch {
            displayedItems = sortedItems(displayedItems)
            reloadResultViews()
            updateStatus()
        } else {
            applyFilterAndSort()
        }
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard tableView === fileTable, let item = item(atRow: row) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: item.url)
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        if tableView === fileTable { fileTable.draggingSessionWillBegin() }
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        if tableView === sidebarTable {
            guard let destination = sidebarDropDestination(at: row) else { return [] }
            let operation = dragOperation(for: info, sources: sources, destination: destination)
            guard !operation.isEmpty else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            return operation
        }

        guard tableView === fileTable else { return [] }
        // 見出しへのドロップはグループへの紐づけ。ファイルは動かないので.link — 見た目にも
        // 移動やコピーと違う矢印が出て、手が滑ってファイルを動かしたのではないと分かる。
        if isHeaderRow(row) {
            guard itemGroupsError == nil, linkableNames(from: sources) != nil else { return [] }
            tableView.setDropRow(row, dropOperation: .on)
            return .link
        }
        let destination: URL
        if let item = item(atRow: row), item.isDirectory {
            destination = item.url
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            destination = navigator.currentDirectory
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return dragOperation(for: info, sources: sources, destination: destination)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let sources = WorkspaceDragDrop.fileURLs(from: info.draggingPasteboard)
        let destination: URL
        if tableView === sidebarTable {
            guard let sidebarDestination = sidebarDropDestination(at: row) else { return false }
            destination = sidebarDestination
        } else if tableView === fileTable {
            if isHeaderRow(row), dropOperation == .on {
                return linkSources(sources, toGroupAtRow: row)
            }
            let target = item(atRow: row)
            destination = target?.isDirectory == true
                ? (target?.url ?? navigator.currentDirectory)
                : navigator.currentDirectory
        } else {
            return false
        }
        let operation = dragOperation(for: info, sources: sources, destination: destination)
        guard !operation.isEmpty else { return false }
        transferItems(sources, to: destination, copy: operation == .copy)
        return true
    }

    private func dragOperation(
        for info: any NSDraggingInfo,
        sources: [URL],
        destination: URL
    ) -> NSDragOperation {
        let operation = WorkspaceDragDrop.operation(
            allowedOperations: info.draggingSourceOperationMask,
            optionKeyPressed: NSEvent.modifierFlags.contains(.option)
        )
        return WorkspaceDragDrop.allows(
            sources: sources,
            destination: destination,
            operation: operation
        ) ? operation : []
    }

    private func sidebarDropDestination(at row: Int) -> URL? {
        guard sidebarRows.indices.contains(row),
              case .item(let item) = sidebarRows[row] else { return nil }
        return item.url
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter
    }()
}

extension WorkspaceBrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        displayedItems.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: WorkspaceGalleryItem.identifier,
            for: indexPath
        )
        guard let galleryItem = item as? WorkspaceGalleryItem,
              displayedItems.indices.contains(indexPath.item) else { return item }
        galleryItem.configure(with: displayedItems[indexPath.item])
        return galleryItem
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard displayedItems.indices.contains(indexPath.item) else { return nil }
        return WorkspaceDragDrop.pasteboardWriter(for: displayedItems[indexPath.item].url)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItemsAt indexPaths: Set<IndexPath>
    ) {
        galleryView.draggingSessionWillBegin()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let indexPath = proposedDropIndexPath.pointee as IndexPath
        let destination: URL
        if displayedItems.indices.contains(indexPath.item),
           displayedItems[indexPath.item].isDirectory {
            destination = displayedItems[indexPath.item].url
            proposedDropOperation.pointee = .on
        } else {
            destination = navigator.currentDirectory
            proposedDropOperation.pointee = .before
        }
        let sources = WorkspaceDragDrop.fileURLs(from: draggingInfo.draggingPasteboard)
        return dragOperation(for: draggingInfo, sources: sources, destination: destination)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let destination = dropOperation == .on
            && displayedItems.indices.contains(indexPath.item)
            && displayedItems[indexPath.item].isDirectory
            ? displayedItems[indexPath.item].url
            : navigator.currentDirectory
        let sources = WorkspaceDragDrop.fileURLs(from: draggingInfo.draggingPasteboard)
        let operation = dragOperation(
            for: draggingInfo,
            sources: sources,
            destination: destination
        )
        guard !operation.isEmpty else { return false }
        transferItems(sources, to: destination, copy: operation == .copy)
        return true
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        updateStatus()
        refreshQuickLookIfVisible()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        updateStatus()
        refreshQuickLookIfVisible()
    }
}

extension WorkspaceBrowserViewController: NSSearchFieldDelegate {
    /// Return commits the path, Escape abandons it. Both fields share this
    /// delegate, so the path field has to be told apart from the search field.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        guard control === pathField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitPathEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endPathEditing()
            return true
        default:
            return false
        }
    }

    /// Filtering re-sorts every item, so running it per keystroke makes typing lag
    /// in large folders. Coalesce bursts; a lone keystroke still lands quickly.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField !== pathField else { return }
        searchScopeControl.isHidden = !searchHasText
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.updateSearchResults()
        }
    }
}

extension WorkspaceBrowserViewController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === fileTable.headerView?.menu {
            menu.item(withTitle: "グループ")?.state = preferences.showsGroupColumn ? .on : .off
            return
        }

        if menu === sidebarTable.menu {
            let item = clickedSidebarItem
            let pins = preferences.pins
            menu.item(withTitle: "ピン留めを解除")?.isEnabled =
                item.map { pins.contains($0.url) } ?? false
            menu.item(withTitle: "Finderで表示")?.isEnabled = item != nil
            return
        }

        if effectiveViewMode == .list {
            let clickedRow = fileTable.clickedRow
            if item(atRow: clickedRow) != nil,
               !fileTable.selectedRowIndexes.contains(clickedRow) {
                fileTable.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
        }
        let selection = selectedItems
        let selectionCount = selection.count
        menu.item(withTitle: "開く")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "クイックルック")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "Finderで表示")?.isEnabled = true
        menu.item(withTitle: "情報を見る")?.isEnabled = true
        menu.item(withTitle: "カット")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "コピー")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "複製")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "エイリアスを作成")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "圧縮")?.isEnabled = true
        menu.item(withTitle: "名前を変更")?.isEnabled = selectionCount == 1
        menu.item(withTitle: "ゴミ箱に入れる…")?.isEnabled = selectionCount > 0
        menu.item(withTitle: "ペースト")?.isEnabled = pasteboardHasFiles
        rebuildOpenWithSubmenu(for: selection.map(\.url))
        rebuildShareSubmenu(for: selection.map(\.url))
        rebuildGroupSubmenus(for: selection)

        // Pinning targets folders; with nothing selected it means the folder on
        // screen, which is always a folder.
        let folders = selectedItems.filter(\.isDirectory).map(\.url)
        let target = folders.first ?? navigator.currentDirectory
        let pinItem = menu.item(withTitle: "サイドバーにピン留め")
            ?? menu.item(withTitle: "サイドバーのピン留めを解除")
        pinItem?.isEnabled = selectedItems.isEmpty || !folders.isEmpty
        pinItem?.title = preferences.pins.contains(target)
            ? "サイドバーのピン留めを解除"
            : "サイドバーにピン留め"
    }
}

extension WorkspaceBrowserViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !selectedItems.isEmpty
        case #selector(paste(_:)):
            return fileClipboard.canPaste(into: navigator.currentDirectory)
        // These no-op on an empty selection, so they must not look available.
        // 情報を見る and 圧縮 deliberately stay enabled: both fall back to the
        // current folder.
        case #selector(duplicateSelection), #selector(makeAliasForSelection):
            return !selectedItems.isEmpty
        case #selector(renameSelection):
            return selectedItems.count == 1
        // グループの操作は、いまのフォルダの直下を選んでいるときだけ。相対名で持つので
        // 別の階層のものは指せない。定義が読めていないときも触らせない。
        case #selector(createGroupWithSelection), #selector(removeSelectionFromAllGroups):
            return canEditGroupsForSelection
        // 迷子がいなければ整理するものが無い。押せるように見せない。
        case #selector(toggleGroupColumn):
            menuItem.state = preferences.showsGroupColumn ? .on : .off
            return true
        case #selector(toggleListGrouping):
            menuItem.state = preferences.listGrouping ? .on : .off
            return true
        case #selector(toggleUngroupedOnly):
            menuItem.state = preferences.listUngroupedOnly ? .on : .off
            return true
        case #selector(toggleGroupedOnly):
            menuItem.state = preferences.listGroupedOnly ? .on : .off
            return true
        case #selector(pruneMissingGroupMembers):
            guard itemGroupsError == nil else { return false }
            return !(itemGroups?.missingMembers(amongNames: presentNames).isEmpty ?? true)
        case #selector(addSelectionToGroup(_:)):
            guard canEditGroupsForSelection,
                  let members = linkableNames(from: selectedItems.map(\.url)),
                  let name = menuItem.representedObject as? String else { return false }
            // 全員がもう入っているグループは、選んでも何も起きない。
            return !members.allSatisfy { itemGroups?.groupNames(for: $0).contains(name) == true }
        case #selector(removeSelectionFromGroup(_:)):
            guard canEditGroupsForSelection,
                  let members = linkableNames(from: selectedItems.map(\.url)),
                  let name = menuItem.representedObject as? String else { return false }
            return members.contains { itemGroups?.groupNames(for: $0).contains(name) == true }
        default:
            return true
        }
    }

    private var canEditGroupsForSelection: Bool {
        itemGroupsError == nil && linkableNames(from: selectedItems.map(\.url)) != nil
    }
}

extension WorkspaceBrowserViewController: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard showsSidebar, didSetInitialSidebarPosition,
              let sidebar = splitView.arrangedSubviews.first else { return }
        let width = sidebar.frame.width
        // 窓を広げると、サイドバーも一緒に太る。上限(360)は引くときにしか効かないので、
        // 実測で460pt——窓幅の三割——まで育っていた。育ったら押し戻す。
        //
        // 押し戻すと`splitViewDidResizeSubviews`がもう一度飛んでくるので、印を立てて
        // 二度目は素通りする（立てないまま`setPosition`を呼ぶと再入が止まらない）。
        if width > 360, !isClampingSidebar, splitView.bounds.width > 761 {
            isClampingSidebar = true
            splitView.setPosition(360, ofDividerAt: 0)
            isClampingSidebar = false
            return
        }
        // 引いて決められる幅と同じ範囲に収めてから覚える。ここで素通ししていたので、
        // 上限を超えた幅が設定に残っていた。幅0は覚えない — 畳んだ状態を覚えると、
        // 次に開いたときサイドバーが無いまま出る。
        guard width > 1 else { return }
        preferences.sidebarWidth = min(max(width, 160), 360)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        dividerIndex == 0 ? 160 : proposedMinimumPosition
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMaximumPosition }
        return min(360, max(160, splitView.bounds.width - 600))
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
