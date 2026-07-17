import FinderAICore
import Foundation

/// ユーザーのtmuxサーバーに対する問い合わせと後始末。どの呼び出しも短命な
/// `tmux`プロセス1回分だけブロックする（数ms〜十数ms）。呼ばれるのは
/// アプリのアクティブ化・セッションの明示的な破棄・終了時に限られ、
/// フォルダ移動のたびに走ることはない。
protocol TmuxControlling: Sendable {
    /// nilはtmuxを起動できなかったとき。サーバーが居ない（=セッションゼロ）は
    /// 失敗ではなく空集合として返る。
    func liveSessionNames(tmuxPath: String) -> Set<String>?
    func killSession(named name: String, tmuxPath: String)
}

struct SystemTmuxController: TmuxControlling {
    func liveSessionNames(tmuxPath: String) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_name}"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    func killSession(named name: String, tmuxPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        // "=" で完全一致を強制する。素の -t は前方一致で、似た名前の
        // セッションを巻き添えにし得る。
        process.arguments = ["kill-session", "-t", "=\(name)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}

/// FinderAIが開始したtmuxセッションの台帳。tmux側の生死は
/// `TmuxControlling`で照合するので、ここは「どのフォルダの何だったか」を
/// 覚えるだけでよい。
@MainActor
protocol SessionRegistryStoring: AnyObject {
    var records: [PersistedSessionRecord] { get set }
}

@MainActor
final class UserDefaultsSessionRegistry: SessionRegistryStoring {
    private static let key = "workspace.tmuxSessions"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var records: [PersistedSessionRecord] {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(
                      [PersistedSessionRecord].self,
                      from: data
                  ) else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }
}
