import AppKit
import FinderAICore
import Foundation
@preconcurrency import SwiftTerm

@MainActor
final class TerminalSession: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let key: TerminalSessionKey
    let directoryURL: URL
    let kind: TerminalSessionKind
    let terminalView: LocalProcessTerminalView

    var onChange: (() -> Void)?
    private(set) var lifecycle: SessionLifecycle = .starting {
        didSet { onChange?() }
    }
    private(set) var terminalTitle: String?

    /// tmux経由のときのセッション名。PTYクライアントが死んでもこの名前の
    /// セッションはtmux側で生きている、というのが永続化の仕組み。
    let tmuxSessionName: String?

    var isRunning: Bool {
        terminalView.process.running
    }

    init(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        tmuxURL: URL?
    ) throws {
        self.directoryURL = directoryURL.standardizedFileURL
        self.kind = kind
        let key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
        self.key = key
        self.terminalView = LocalProcessTerminalView(frame: .zero)

        if kind.commandName != nil, executableURL == nil {
            throw SessionCreationError.executableNotFound(kind.displayName)
        }
        let launch = TmuxLaunchPlan.plan(
            kind: kind,
            directoryKey: key.directoryKey,
            commandPath: executableURL?.path,
            tmuxPath: tmuxURL?.path
        )
        self.tmuxSessionName = launch.tmuxSessionName
        super.init()

        terminalView.processDelegate = self
        terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = IntegratedPanelTheme.terminalBackground
        terminalView.nativeForegroundColor = IntegratedPanelTheme.text
        terminalView.caretColor = IntegratedPanelTheme.accent
        terminalView.setHostLogging(directory: nil)

        terminalView.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: Self.childEnvironment(directoryURL: self.directoryURL),
            currentDirectory: self.directoryURL.path
        )
        guard terminalView.process.running else {
            lifecycle = .failed(message: "PTYプロセスを開始できませんでした。")
            throw SessionCreationError.processStartFailed
        }
        lifecycle = .running
    }

    func terminate() {
        guard isRunning else { return }
        terminalView.terminate()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = String(title.prefix(80))
        onChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // The shell may report OSC 7, but FinderAI intentionally never uses it
        // to mutate the Finder/session association.
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        lifecycle = .exited(code: exitCode)
    }

    static func childEnvironment(
        directoryURL: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var environment = base
        environment["PATH"] = ExecutableLocator.augmentedPath(environment: environment)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "FinderAI"
        environment["SHELL"] = "/bin/zsh"
        environment["PWD"] = directoryURL.path
        if environment["LANG"] == nil, environment["LC_ALL"] == nil, environment["LC_CTYPE"] == nil {
            // Finder/Dockから起動したGUIアプリはロケールを持たない。素のままだと
            // tmuxが非UTF-8モードで立ち上がり、日本語のパスや出力が化ける。
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
    }
}

extension TerminalSession: ManagedTerminalSession {
    var contentView: NSView { terminalView }
}

enum SessionCreationError: LocalizedError {
    case executableNotFound(String)
    case processStartFailed

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "\(name)コマンドが見つかりません。FinderAIは自動インストールしません。"
        case .processStartFailed:
            "PTYプロセスを開始できませんでした。"
        }
    }
}
