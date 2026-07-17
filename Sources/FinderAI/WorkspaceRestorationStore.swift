import FinderAICore
import Foundation

/// クラッシュ検出と構成スナップショットの置き場。
///
/// 検出は「起動時にdirtyへ倒し、正常終了だけがcleanへ戻す」方式。次の起動で
/// dirtyのままなら、前回は`applicationWillTerminate`に到達しなかった＝クラッシュか
/// 強制終了と判断する。スナップショット自体は毎回の変更で上書きされ続けるので、
/// dirtyのときに残っているのは落ちる直前の構成になる。
@MainActor
struct WorkspaceRestorationStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let snapshot = "workspace.restorationSnapshot"
        static let cleanShutdown = "workspace.cleanShutdown"
    }

    /// キーが無い＝初回起動はクラッシュ扱いにしない。
    var previousRunEndedCleanly: Bool {
        guard defaults.object(forKey: Key.cleanShutdown) != nil else { return true }
        return defaults.bool(forKey: Key.cleanShutdown)
    }

    func beginRun() {
        defaults.set(false, forKey: Key.cleanShutdown)
    }

    func markCleanShutdown() {
        defaults.set(true, forKey: Key.cleanShutdown)
    }

    var snapshot: WorkspaceRestorationSnapshot? {
        get {
            defaults.data(forKey: Key.snapshot)
                .flatMap(WorkspaceRestorationSnapshot.decoded(from:))
        }
        nonmutating set {
            guard let data = newValue?.encoded() else {
                defaults.removeObject(forKey: Key.snapshot)
                return
            }
            defaults.set(data, forKey: Key.snapshot)
        }
    }
}
