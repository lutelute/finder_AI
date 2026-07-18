import AppKit
import FinderAICore

/// ⌘,の設定ウインドウ。設定の実体はこれまでどおり`WorkspacePreferences`で、
/// ここはそれを見せる場所にすぎない。表示メニューに直置きしていたトグルは
/// ここへ移した：メニューは動作の場所で、状態の置き場ではないから。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let sessionManager: any TerminalSessionManaging
    private let preferences: WorkspacePreferences

    private let persistCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let persistCaption = NSTextField(wrappingLabelWithString: "")
    private let loggingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loggingCaption = NSTextField(wrappingLabelWithString: "")

    init(
        sessionManager: any TerminalSessionManaging,
        preferences: WorkspacePreferences
    ) {
        self.sessionManager = sessionManager
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 0),
            styleMask: [.titled, .closable],
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
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 開くたびに実体から読み直す。設定はここ以外（将来のメニューやコード）からも
    /// 変わり得る前提で、このウインドウは真実を写すだけにする。
    private func refresh() {
        let tmuxAvailable = sessionManager.persistenceAvailable
        persistCheckbox.state = sessionManager.persistenceEnabled ? .on : .off
        persistCheckbox.isEnabled = tmuxAvailable
        persistCaption.stringValue = tmuxAvailable
            ? "FinderAIが落ちたり終了しても、以降に開始したセッションはtmux内で生き続け、同じフォルダから再接続できます。"
            : "tmuxが見つかりません。Homebrewなら `brew install tmux` で導入すると有効にできます。"
        loggingCheckbox.state = preferences.sessionLogging ? .on : .off
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "Terminal")
        title.font = .boldSystemFont(ofSize: 13)

        persistCheckbox.title = "セッションを永続化（tmux）"
        persistCheckbox.target = self
        persistCheckbox.action = #selector(togglePersistence)

        loggingCheckbox.title = "出力をログに保存"
        loggingCheckbox.target = self
        loggingCheckbox.action = #selector(toggleLogging)
        loggingCaption.stringValue = "これ以降に開始するセッションの出力（コマンドと表示内容を含む）をローカルに保存し、14日で自動削除します。クラッシュ直前の状況を後から読むための保険です。"

        [persistCaption, loggingCaption].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .secondaryLabelColor
            $0.preferredMaxLayoutWidth = 400
        }

        let openLogs = NSButton(
            title: "ログフォルダを開く",
            target: self,
            action: #selector(openLogFolder)
        )
        openLogs.bezelStyle = .rounded
        openLogs.controlSize = .small

        let stack = NSStackView(views: [
            title,
            persistCheckbox, indented(persistCaption),
            loggingCheckbox, indented(loggingCaption), indented(openLogs)
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(16, after: indentedViews[persistCaption] ?? persistCaption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
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
}
