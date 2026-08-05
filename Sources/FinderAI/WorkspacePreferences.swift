import FinderAICore
import Foundation

enum WorkspaceViewMode: String, CaseIterable {
    case list
    case column
    case gallery
}

/// Durable UI state. Everything here is a convenience the user re-establishes by
/// hand otherwise, so a missing or corrupt value must fall back to the shipped
/// default rather than surface an error.
@MainActor
struct WorkspacePreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let sidebarWidth = "workspace.sidebarWidth"
        static let sortColumn = "workspace.sortColumn"
        static let sortAscending = "workspace.sortAscending"
        static let showHiddenFiles = "workspace.showHiddenFiles"
        static let terminalHeight = "workspace.terminalHeight"
        static let terminalWidth = "workspace.terminalWidth"
        static let terminalEdge = "workspace.terminalEdge"
        static let terminalExpanded = "workspace.terminalExpanded"
        static let lastDirectory = "workspace.lastDirectory"
        static let pins = "workspace.pins"
        static let visits = "workspace.visits"
        static let columnView = "workspace.columnView"
        static let viewMode = "workspace.viewMode"
        static let splitEnabled = "workspace.splitEnabled"
        static let splitRatio = "workspace.splitRatio"
        static let secondDirectory = "workspace.secondDirectory"
        static let persistentSessions = "workspace.persistentSessions"
        static let sessionLogging = "workspace.sessionLogging"
        static let edgeTabs = "workspace.edgeTabs"
        static let edgeTabsEnabled = "workspace.edgeTabsEnabled"
        static let edgeTabsEdge = "workspace.edgeTabsEdge"
        static let edgeTabsAutoHide = "workspace.edgeTabsAutoHide"
        static let edgeTabsOpensOnHover = "workspace.edgeTabsOpensOnHover"
        static let edgeTabsIconView = "workspace.edgeTabsIconView"
        static let edgeTabsSortColumn = "workspace.edgeTabsSortColumn"
        static let edgeTabsSortAscending = "workspace.edgeTabsSortAscending"
        static let edgeTabsPreview = "workspace.edgeTabsPreview"
        static let edgeTabsUsesFinderWindows = "workspace.edgeTabsUsesFinderWindows"
        static let restoresWindows = "workspace.restoresWindows"
    }

    /// 前回開いていたウインドウを、起動時にそのまま開き直すか。既定はオン。
    ///
    /// 何十枚も開いて使う道具なので、終了のたびに1枚へ戻るのは「閉じた覚えの
    /// ないものが消える」に等しい。
    var restoresWindows: Bool {
        get {
            guard defaults.object(forKey: Key.restoresWindows) != nil else { return true }
            return defaults.bool(forKey: Key.restoresWindows)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.restoresWindows) }
    }

    /// 選んだものの中身を一覧の下に見せるか。既定はオン——開くかどうかを、開く前に
    /// 決められるのがこの画面の値打ちなので。
    var edgeTabsShowsPreview: Bool {
        get {
            guard defaults.object(forKey: Key.edgeTabsPreview) != nil else { return true }
            return defaults.bool(forKey: Key.edgeTabsPreview)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.edgeTabsPreview) }
    }

    /// 「開く」で、macOS標準のFinderがすでに開いているウインドウも探すか。
    /// 既定はオン。Finderを何枚も開いて使う人にとっては、そちらが本命の窓。
    var edgeTabsUsesFinderWindows: Bool {
        get {
            guard defaults.object(forKey: Key.edgeTabsUsesFinderWindows) != nil else { return true }
            return defaults.bool(forKey: Key.edgeTabsUsesFinderWindows)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.edgeTabsUsesFinderWindows) }
    }

    /// タブに触れただけで開くか。既定はオフ——クリックで開く方が、通りすがりに
    /// 勝手に開かれない。触れるだけで開いてほしい人が選ぶ。
    var edgeTabsOpensOnHover: Bool {
        get { defaults.bool(forKey: Key.edgeTabsOpensOnHover) }
        nonmutating set { defaults.set(newValue, forKey: Key.edgeTabsOpensOnHover) }
    }

    /// 一覧をアイコンで並べるか、行で並べるか。
    var edgeTabsUsesIconView: Bool {
        get { defaults.bool(forKey: Key.edgeTabsIconView) }
        nonmutating set { defaults.set(newValue, forKey: Key.edgeTabsIconView) }
    }

    var edgeTabsSort: WorkspaceEdgeTabSort {
        get {
            guard let raw = defaults.string(forKey: Key.edgeTabsSortColumn),
                  let sort = WorkspaceEdgeTabSort(rawValue: raw) else { return .name }
            return sort
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.edgeTabsSortColumn) }
    }

    var edgeTabsSortAscending: Bool {
        get {
            guard defaults.object(forKey: Key.edgeTabsSortAscending) != nil else { return true }
            return defaults.bool(forKey: Key.edgeTabsSortAscending)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.edgeTabsSortAscending) }
    }

    // MARK: - Edge tabs

    /// 画面端に出しっぱなしにするフォルダ。ピンと同じくパス文字列で持つ
    /// （`lastDirectory`の経緯を参照——bookmarkの解決は起動経路で高くつく）。
    var edgeTabs: WorkspaceEdgeTabs {
        get { WorkspaceEdgeTabs(paths: defaults.stringArray(forKey: Key.edgeTabs) ?? []) }
        nonmutating set { defaults.set(newValue.storedPaths, forKey: Key.edgeTabs) }
    }

    /// 既定はオフ。画面に常駐するUIを、選んでいない人の視界に勝手に置かない。
    var edgeTabsEnabled: Bool {
        get { defaults.bool(forKey: Key.edgeTabsEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.edgeTabsEnabled) }
    }

    /// 既定はオフ（常に見えている）。隠れているものは思い出せないので、
    /// 「そこにある」から始めて、邪魔だと思った人が隠す。
    var edgeTabsAutoHide: Bool {
        get { defaults.bool(forKey: Key.edgeTabsAutoHide) }
        nonmutating set { defaults.set(newValue, forKey: Key.edgeTabsAutoHide) }
    }

    var edgeTabsEdge: WorkspaceScreenEdge {
        get {
            guard let raw = defaults.string(forKey: Key.edgeTabsEdge),
                  let edge = WorkspaceScreenEdge(rawValue: raw) else { return .right }
            return edge
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.edgeTabsEdge) }
    }

    // MARK: - Crash resilience

    /// tmuxでセッションを生存させるか。既定はオフ：tmuxという外部依存を、
    /// ユーザーが選んでいないのに背負わせない。
    var persistentSessions: Bool {
        get { defaults.bool(forKey: Key.persistentSessions) }
        nonmutating set { defaults.set(newValue, forKey: Key.persistentSessions) }
    }

    /// Terminal出力をディスクへ残すか。既定はオフ：「Terminal内容を保存しない」が
    /// このアプリのプライバシー方針で、クラッシュ検死ログはそれを破る側の機能。
    /// ユーザーが明示的に選んだときだけ有効になる。
    var sessionLogging: Bool {
        get { defaults.bool(forKey: Key.sessionLogging) }
        nonmutating set { defaults.set(newValue, forKey: Key.sessionLogging) }
    }

    // MARK: - View mode

    var viewMode: WorkspaceViewMode {
        get {
            if let raw = defaults.string(forKey: Key.viewMode),
               let mode = WorkspaceViewMode(rawValue: raw) {
                return mode
            }
            // v1.6以前のbooleanを一度だけ読み替える。
            return defaults.bool(forKey: Key.columnView) ? .column : .list
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.viewMode)
            defaults.set(newValue == .column, forKey: Key.columnView)
        }
    }

    var usesColumnView: Bool {
        get { viewMode == .column }
        nonmutating set { viewMode = newValue ? .column : .list }
    }

    // MARK: - Split view

    var splitEnabled: Bool {
        get { defaults.bool(forKey: Key.splitEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.splitEnabled) }
    }

    /// Left pane's share of the width. Clamped so a restored value can never hide
    /// a pane outright.
    var splitRatio: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.splitRatio)
            guard stored > 0 else { return 0.5 }
            return min(max(CGFloat(stored), 0.2), 0.8)
        }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.splitRatio) }
    }

    /// Plain path, for the same reason as `lastDirectory`.
    var secondDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.secondDirectory),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.secondDirectory)
                return
            }
            defaults.set(newValue.standardizedFileURL.path, forKey: Key.secondDirectory)
        }
    }

    // MARK: - Sidebar

    /// Paths, not bookmarks — see `lastDirectory` for why.
    var pins: WorkspacePins {
        get { WorkspacePins(paths: defaults.stringArray(forKey: Key.pins) ?? []) }
        nonmutating set { defaults.set(newValue.storedPaths, forKey: Key.pins) }
    }

    /// A corrupt log costs the user nothing to rebuild, so a decode failure starts
    /// over instead of surfacing.
    var visitLog: WorkspaceVisitLog {
        get {
            guard let data = defaults.data(forKey: Key.visits),
                  let visits = try? JSONDecoder().decode(
                      [WorkspaceVisitLog.Visit].self,
                      from: data
                  ) else { return WorkspaceVisitLog() }
            return WorkspaceVisitLog(visits: visits)
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue.all) else { return }
            defaults.set(data, forKey: Key.visits)
        }
    }

    // MARK: - Sidebar

    var sidebarWidth: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.sidebarWidth)
            guard stored > 0 else { return 210 }
            return min(max(CGFloat(stored), 160), 360)
        }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.sidebarWidth) }
    }

    // MARK: - Sorting

    var sortColumn: String {
        get { defaults.string(forKey: Key.sortColumn) ?? "name" }
        nonmutating set { defaults.set(newValue, forKey: Key.sortColumn) }
    }

    var sortAscending: Bool {
        get {
            guard defaults.object(forKey: Key.sortAscending) != nil else { return true }
            return defaults.bool(forKey: Key.sortAscending)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.sortAscending) }
    }

    // MARK: - Listing

    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: Key.showHiddenFiles) }
        nonmutating set { defaults.set(newValue, forKey: Key.showHiddenFiles) }
    }

    // MARK: - Terminal

    var terminalHeight: CGFloat {
        get { thickness(forKey: Key.terminalHeight, edge: .bottom) }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.terminalHeight) }
    }

    /// 右辺に置いたときの幅。高さとは別のキーに持つ——下と右を行き来しても、
    /// それぞれで決めた大きさがそのまま戻ってくるほうが「置き場所を変えた」だけの
    /// 操作として素直だから。
    var terminalWidth: CGFloat {
        get { thickness(forKey: Key.terminalWidth, edge: .right) }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.terminalWidth) }
    }

    var terminalEdge: TerminalPanelEdge {
        get {
            guard let raw = defaults.string(forKey: Key.terminalEdge),
                  let edge = TerminalPanelEdge(rawValue: raw) else { return .bottom }
            return edge
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.terminalEdge) }
    }

    /// 辺を意識せず読み書きするための入口。ウインドウ側はこちらだけを使う。
    func terminalThickness(for edge: TerminalPanelEdge) -> CGFloat {
        edge == .bottom ? terminalHeight : terminalWidth
    }

    func setTerminalThickness(_ value: CGFloat, for edge: TerminalPanelEdge) {
        switch edge {
        case .bottom: terminalHeight = value
        case .right: terminalWidth = value
        }
    }

    private func thickness(forKey key: String, edge: TerminalPanelEdge) -> CGFloat {
        let stored = defaults.double(forKey: key)
        guard stored > 0 else { return TerminalPanelLayout.defaultThickness(for: edge) }
        return min(
            max(CGFloat(stored), TerminalPanelLayout.minimumThickness(for: edge)),
            TerminalPanelLayout.maximumThickness(for: edge)
        )
    }

    var terminalExpanded: Bool {
        get { defaults.bool(forKey: Key.terminalExpanded) }
        nonmutating set { defaults.set(newValue, forKey: Key.terminalExpanded) }
    }

    // MARK: - Last directory

    /// A plain path, and deliberately not a bookmark: resolving a bookmark to a
    /// protected folder took ~15s before the first window could appear, because
    /// it reaches the filesystem and TCC. This getter touches nothing but
    /// `UserDefaults`, so it is safe on the launch path — whether the folder
    /// still exists is the caller's problem, checked off the main thread.
    ///
    /// The trade-off is that a folder moved between launches is not followed;
    /// that is worth 15 seconds.
    var lastDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastDirectory),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.lastDirectory)
                return
            }
            defaults.set(newValue.standardizedFileURL.path, forKey: Key.lastDirectory)
        }
    }
}
