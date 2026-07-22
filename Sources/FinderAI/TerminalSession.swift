import AppKit
import Darwin
import FinderAICore
import Foundation
@preconcurrency import SwiftTerm

/// SwiftTerm 1.14の`LocalProcess.terminate()`はprocess monitorを先にcancelするため、
/// SIGTERMを無視するinteractive shellが後から終了すると`waitpid`されずzombieになる。
/// FinderAI所有のPTY process groupへTERMを送り、十分な終了猶予を置く。それでも
/// 残った場合だけKILLし、必ず回収する。
@MainActor
enum OwnedProcessTerminator {
    private static let reaperQueue = DispatchQueue(
        label: "com.shigenoburyuto.finderai.terminal-reaper",
        qos: .utility
    )

    static func terminate(
        _ process: LocalProcess,
        gracePeriod: TimeInterval = 3
    ) {
        let pid = process.shellPid
        process.terminate()
        guard pid > 1 else { return }

        reaperQueue.async {
            signalProcessGroupAndLeader(pid: pid, signal: SIGTERM)
            var status: Int32 = 0
            let interval: useconds_t = 20_000
            let attempts = max(1, Int((max(0, gracePeriod) * 1_000_000) / Double(interval)))
            for _ in 0..<attempts {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) { return }
                if result == -1 && errno != EINTR { return }
                usleep(interval)
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
    private(set) var key: TerminalSessionKey
    private(set) var directoryURL: URL
    let kind: TerminalSessionKind

    /// An anchored shell stays in its folder instead of following browser
    /// navigation. AI sessions never follow regardless — this flag only
    /// matters for plain shells.
    var isAnchored = false {
        didSet { onChange?() }
    }
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

    /// True only while a plain, app-owned shell sits at its prompt: the
    /// foreground process group on the PTY is the shell itself. Commands,
    /// full-screen TUIs and tmux clients all fail this gate, so nothing is
    /// ever typed into them.
    var isShellIdleAtPrompt: Bool {
        guard kind == .shell, persistence == nil, isRunning,
              let process = terminalView.process else { return false }
        let descriptor = process.childfd
        let shellPid = process.shellPid
        guard descriptor >= 0, shellPid > 0 else { return false }
        let foreground = tcgetpgrp(descriptor)
        guard foreground > 0, foreground == getpgid(shellPid) else { return false }
        // The line editor draws its prompt in raw mode (ICANON off); a shell
        // that is still starting up sits in the default cooked mode with its
        // SIGINT handler not yet installed — our ^C would kill it outright
        // (measured, not theory). Cooked mode with the shell in the foreground
        // also covers `read`: input meant for it must never be ours.
        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else { return false }
        return attributes.c_lflag & UInt(ICANON) == 0
    }

    /// The shell's real working directory, straight from the kernel.
    var shellWorkingDirectoryPath: String? {
        guard isRunning, let process = terminalView.process else { return nil }
        return ProcessWorkingDirectory.path(for: process.shellPid)
    }

    /// Sends a follow-`cd` when — and only when — that is safe. Every guard
    /// for injecting bytes into the PTY lives here.
    func followDirectory(to url: URL) -> Bool {
        guard isShellIdleAtPrompt else { return false }
        let target = url.standardizedFileURL.path
        // The kernel answers /private/var/… where Foundation says /var/…;
        // normalize through URL so "already there" is recognized either way.
        if let current = shellWorkingDirectoryPath,
           URL(fileURLWithPath: current).standardizedFileURL.path == target {
            return true
        }
        terminalView.send(txt: ShellFollow.command(forPath: target))
        return true
    }

    /// Re-homes the session after a successful follow. The manager owns the
    /// key-indexed dictionaries; this only updates the session's own identity.
    func rebind(to url: URL) {
        directoryURL = url.standardizedFileURL
        key = TerminalSessionKey(directoryURL: directoryURL, kind: kind)
        onChange?()
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
