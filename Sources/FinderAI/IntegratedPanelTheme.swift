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

extension TerminalSessionKind {
    /// タブに出す記号。読まずに種類を見分けるための的。
    var symbolName: String {
        switch self {
        case .shell: "terminal.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        }
    }

    /// 種類ごとの色。名前を落として記号だけにしても、色で区別が残る。
    /// 選択や強調に使う青とは別の色にして、「今どれを見ているか」と
    /// 「これは何か」が混ざらないようにする。
    var tint: NSColor {
        switch self {
        case .shell: NSColor(srgbRed: 0.55, green: 0.60, blue: 0.67, alpha: 1)
        case .codex: NSColor(srgbRed: 0.36, green: 0.72, blue: 0.51, alpha: 1)
        case .claude: NSColor(srgbRed: 0.85, green: 0.52, blue: 0.35, alpha: 1)
        }
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
    /// その面が額縁か中身か。ウインドウごとの色は**額縁にだけ**混ぜる。
    ///
    /// 色を引く側（`IntegratedPanelTheme`）には手を入れない。あちらは
    /// 「画面のどこであれ同じ意味の色」を返す場所で、ウインドウごとに答えが
    /// 変わってはいけない。窓の色は塗る側の事情なので、ここで混ぜる。
    enum SurfaceRole {
        /// タイトルバー・ツールバー・サイドバー・下帯・ターミナルの見出し。
        case frame
        /// ファイル一覧とターミナルの地。名前を読む場所なので色を敷かない。
        case content
    }

    /// この区画に掛けてある外観。
    ///
    /// ビューの`effectiveAppearance`を見に行くと、まだ画面へ入れる前は親が
    /// 決まっておらず、システムの明るさが返る。作りながら塗る場面ではそれが
    /// ほとんどで、暗く選んだはずの区画が明るいまま固まった。
    var appearance: NSAppearance?

    /// このウインドウの目印の色。`nil`なら従来どおりの灰。
    var tint: WorkspaceWindowTint?
    /// 地に混ぜる割合。設定で動かせる。
    var tintStrength: Double = WorkspaceWindowTint.defaultStrength

    private var entries: [(view: NSView, role: SurfaceRole, color: @MainActor () -> NSColor)] = []

    func register(
        _ view: NSView,
        role: SurfaceRole = .content,
        _ color: @escaping @MainActor () -> NSColor
    ) {
        view.wantsLayer = true
        entries.append((view, role, color))
        paint(view, role, color)
    }

    func repaint() {
        // 画面から外れたものは捨てる。控えを持ち続けても塗る先がない。
        entries.removeAll { $0.view.superview == nil && $0.view.window == nil }
        for entry in entries { paint(entry.view, entry.role, entry.color) }
    }

    private func paint(_ view: NSView, _ role: SurfaceRole, _ color: @MainActor () -> NSColor) {
        let appearance = self.appearance ?? view.effectiveAppearance
        // そのビューの外観で色を解いてから固める。ここを外すと、暗い側の値が
        // 明るい画面にも塗られる。
        appearance.performAsCurrentDrawingAppearance {
            let base = color()
            let painted = role == .frame
                ? Self.blend(tint, into: base, isDark: appearance.isDark, strength: tintStrength)
                : base
            view.layer?.backgroundColor = painted.cgColor
        }
    }

    /// 地に窓の色を混ぜる。`tint`が無ければ地をそのまま返す。
    ///
    /// 呼ぶ側が`performAsCurrentDrawingAppearance`の中に居ることが前提。
    /// 動的色は、そこを外れると別の明るさで解ける。
    static func blend(
        _ tint: WorkspaceWindowTint?,
        into base: NSColor,
        isDark: Bool,
        strength: Double = WorkspaceWindowTint.defaultStrength
    ) -> NSColor {
        guard let tint else { return base }
        let amount = CGFloat(WorkspaceWindowTint.clampedStrength(strength))
        let hex = isDark ? tint.darkHex : tint.lightHex
        guard let ground = base.usingColorSpace(.sRGB) else { return base }
        let top = rgb(hex)
        return NSColor(
            srgbRed: top.r * amount + ground.redComponent * (1 - amount),
            green: top.g * amount + ground.greenComponent * (1 - amount),
            blue: top.b * amount + ground.blueComponent * (1 - amount),
            alpha: 1
        )
    }

    private static func rgb(_ hex: UInt32) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (
            CGFloat((hex >> 16) & 0xFF) / 255.0,
            CGFloat((hex >> 8) & 0xFF) / 255.0,
            CGFloat(hex & 0xFF) / 255.0
        )
    }
}

/// 外観が変わったことを教えてくれるだけのビュー。
///
/// 明るさはウインドウの一部にだけ掛けるので、変わり目を知りたいのは
/// その区画の根。
@MainActor
final class ThemedRootView: NSView {
    var onAppearanceChanged: (() -> Void)?

    /// ターミナルより先に鍵を見るための口。
    ///
    /// `performKeyEquivalent`は親から子へ降りるので、ここで拾えばターミナルが
    /// 自分宛ての入力として食べる前に済む。⌃Tabも⌘⌥矢印も、素直にメニューへ
    /// 任せると届かなかった（実機で確認）——ターミナルを内に抱えた画面では、
    /// 鍵の取り合いに勝てるのは中身より外側だけ。
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}
