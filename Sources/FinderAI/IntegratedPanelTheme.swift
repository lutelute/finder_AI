import AppKit
import FinderAICore

extension Notification.Name {
    /// 明るさを選び直した。開いている全部のウインドウへ配る。
    static let workspaceAppearanceDidChange = Notification.Name("workspaceAppearanceDidChange")
}

/// 画面のどこであれ同じ意味の色を引くための一覧。
///
/// 固定のダーク配色から、外観に追い付く色へ変えた。ファイル一覧とターミナルで
/// 別々に明るさを選べるようにしたので、同じ`background`でも場所によって明るさが
/// 違う——`NSColor(name:dynamicProvider:)`なら、塗る側は「どちらか」を気にせず
/// 引くだけで済む。
///
/// レイヤーの背景色に使うときだけ注意が要る。`cgColor`はその瞬間の外観で固まる
/// ので、外観が変わったら塗り直しがいる（`ThemedBackgroundView`がそれをやる）。
@MainActor
enum IntegratedPanelTheme {
    static let background = dynamic(dark: 24, light: 246)
    static let header = dynamic(dark: 31, light: 237)
    static let terminalBackground = dynamic(dark: 18, light: 252)
    static let activeTab = dynamic(dark: 44, light: 255)
    /// サイドバー。本文より一段沈める。
    static let sidebar = dynamic(dark: 37, light: 232)
    static let border = dynamic(dark: 62, light: 208)
    static let text = dynamic(dark: 215, light: 30)
    static let secondaryText = dynamic(dark: 153, light: 110)
    /// 選択や強調。明るさによらず同じ青のままにする——ここまで変えると、
    /// 明るさを切り替えただけで別のアプリに見える。
    static let accent = NSColor(
        srgbRed: 0.0 / 255.0,
        green: 122.0 / 255.0,
        blue: 204.0 / 255.0,
        alpha: 1
    )

    /// 灰の濃さだけで決まる色。0〜255で書く。
    private static func dynamic(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let level = appearance.isDark ? dark : light
            return NSColor(
                srgbRed: level / 255.0,
                green: level / 255.0,
                blue: level / 255.0,
                alpha: 1
            )
        }
    }
}

extension NSAppearance {
    /// 暗いほうの外観か。
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension WorkspaceAppearance {
    /// AppKitに渡す外観。システムに合わせるときはnil（親から受け継ぐ）。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// レイヤーの背景を、外観が変わっても塗り直すための控え。
///
/// `layer?.backgroundColor`に直に入れると、`cgColor`へ変えた時点でその瞬間の
/// 外観に固まる。明るさを切り替えても塗り直されず、暗いままの帯が残る。
/// どのビューをどの色で塗ったかを覚えておいて、変わり目にまとめて塗り直す。
///
/// ビューの型を変えずに済ませたいのでこの形にした。背景を持つビューは、
/// 見出し・区切り・本文と種類が多く、それぞれに専用の親クラスを当てると
/// 既存の作りを広く触ることになる。
@MainActor
final class ThemedLayerPainter {
    /// この区画に掛けてある外観。
    ///
    /// ビューの`effectiveAppearance`を見に行くと、まだ画面へ入れる前は親が
    /// 決まっておらず、システムの明るさが返る。作りながら塗る場面ではそれが
    /// ほとんどで、暗く選んだはずの区画が明るいまま固まった。
    var appearance: NSAppearance?

    private var entries: [(view: NSView, color: @MainActor () -> NSColor)] = []

    func register(_ view: NSView, _ color: @escaping @MainActor () -> NSColor) {
        view.wantsLayer = true
        entries.append((view, color))
        paint(view, color)
    }

    func repaint() {
        // 画面から外れたものは捨てる。控えを持ち続けても塗る先がない。
        entries.removeAll { $0.view.superview == nil && $0.view.window == nil }
        for entry in entries { paint(entry.view, entry.color) }
    }

    private func paint(_ view: NSView, _ color: @MainActor () -> NSColor) {
        // そのビューの外観で色を解いてから固める。ここを外すと、暗い側の値が
        // 明るい画面にも塗られる。
        (appearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = color().cgColor
        }
    }
}

/// 外観が変わったことを教えてくれるだけのビュー。
///
/// 明るさはウインドウの一部にだけ掛けるので、変わり目を知りたいのは
/// その区画の根。
@MainActor
final class ThemedRootView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}
