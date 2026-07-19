import AppKit
import Darwin
import FinderAICore
import Foundation
@preconcurrency import SwiftTerm

/// SwiftTerm 1.14の`LocalProcess.terminate()`はprocess monitorを先にcancelするため、
/// SIGTERMを無視するinteractive shellが後から終了すると`waitpid`されずzombieになる。
/// FinderAI所有のPTY process groupへHUPを送り、猶予後はKILLして必ず回収する。
@MainActor
enum OwnedProcessTerminator {
    private static let reaperQueue = DispatchQueue(
        label: "com.shigenoburyuto.finderai.terminal-reaper",
        qos: .utility
    )

    static func terminate(_ process: LocalProcess) {
        let pid = process.shellPid
        process.terminate()
        guard pid > 1 else { return }

        reaperQueue.async {
            signalProcessGroupAndLeader(pid: pid, signal: SIGHUP)
            var status: Int32 = 0
            for _ in 0..<50 {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) { return }
                if result == -1 && errno != EINTR { return }
                usleep(10_000)
            }

            signalProcessGroupAndLeader(pid: pid, signal: SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    private nonisolated static func signalProcessGroupAndLeader(
        pid: pid_t,
        signal: Int32
    ) {
        _ = Darwin.kill(-pid, signal)
        _ = Darwin.kill(pid, signal)
    }
}

/// ホストからの生バイトをターミナルへ流す前にログへ複製する。SwiftTerm組み込みの
/// `setHostLogging`は読み取りチャンクごとに別ファイルを作るデバッグ機構で、
/// 1本の追記ログにはならないため使わない。
@MainActor
final class LoggingTerminalView: LocalProcessTerminalView {
    var outputLog: SessionOutputLog?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        outputLog?.append(Array(slice))
        super.dataReceived(slice: slice)
    }
}

@MainActor
final class TerminalSession: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let key: TerminalSessionKey
    let directoryURL: URL
    let kind: TerminalSessionKind
    let persistence: TerminalSessionPersistence?
    let terminalView: LocalProcessTerminalView
    private let outputLog: SessionOutputLog?

    var onChange: (() -> Void)?
    private(set) var lifecycle: SessionLifecycle = .starting {
        didSet { onChange?() }
    }
    private(set) var terminalTitle: String?

    var isRunning: Bool {
        terminalView.process.running
    }

    init(
        directoryURL: URL,
        kind: TerminalSessionKind,
        executableURL: URL?,
        persistence: TerminalSessionPersistence?,
        logsOutput: Bool
    ) throws {
        self.directoryURL = directoryURL.standardizedFileURL
        self.kind = kind
        self.key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
        self.persistence = persistence
        let view = LoggingTerminalView(frame: .zero)
        self.terminalView = view

        guard let plan = TerminalLaunchPlanner.plan(
            kind: kind,
            commandURL: executableURL,
            persistence: persistence,
            directoryPath: self.directoryURL.path
        ) else {
            throw SessionCreationError.executableNotFound(kind.displayName)
        }

        // ログはオプトイン。作れなくてもセッションは開始する — 検死ログは保険で
        // あって前提ではない。
        let log: SessionOutputLog?
        if logsOutput {
            log = SessionOutputLog(
                directory: SessionLogStore.directory,
                fileName: SessionLogStore.fileName(kind: kind, directoryURL: self.directoryURL),
                header: SessionLogStore.header(kind: kind, directoryURL: self.directoryURL)
            )
        } else {
            log = nil
        }
        self.outputLog = log
        view.outputLog = log
        super.init()

        terminalView.processDelegate = self
        terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = IntegratedPanelTheme.terminalBackground
        terminalView.nativeForegroundColor = IntegratedPanelTheme.text
        terminalView.caretColor = IntegratedPanelTheme.accent
        terminalView.setHostLogging(directory: nil)

        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: Self.childEnvironment(
                directoryURL: self.directoryURL,
                persistent: persistence != nil
            ),
            currentDirectory: self.directoryURL.path
        )
        guard terminalView.process.running else {
            lifecycle = .failed(message: "PTYプロセスを開始できませんでした。")
            outputLog?.close()
            throw SessionCreationError.processStartFailed
        }
        lifecycle = .running
    }

    func terminate() {
        guard isRunning else { return }
        OwnedProcessTerminator.terminate(terminalView.process)
    }

    func transcriptData() -> Data? {
        guard terminalView.terminal != nil else { return nil }
        return terminalView.terminal.getBufferAsData(kind: .active)
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
        outputLog?.appendLine("# FinderAI: process exited (code: \(exitCode.map(String.init) ?? "nil"))")
        outputLog?.close()
    }

    private static func childEnvironment(
        directoryURL: URL,
        persistent: Bool
    ) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ExecutableLocator.augmentedPath(environment: environment)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "FinderAI"
        environment["SHELL"] = "/bin/zsh"
        environment["PWD"] = directoryURL.path
        if persistent {
            // TMUXが残っているとtmuxはネスト起動とみなして拒否する。FinderAI自身が
            // tmux内から起動された場合でも、子のtmuxクライアントは独立させる。
            environment.removeValue(forKey: "TMUX")
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
