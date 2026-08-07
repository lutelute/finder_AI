import AppKit
import FinderAICore
import SwiftTerm
import Testing

@testable import FinderAIApp

/// SwiftTermがOSC 10/11（前景・背景色の照会）へ返す内部RGBは、
/// `nativeForegroundColor`/`nativeBackgroundColor`を代入した瞬間に固定される。
/// ここがビューへ掛けた外観とずれると、claudeのようなTUIが逆の明るさの
/// 配色を選び、文字が見えなくなる。外観どおりに解決されることを確かめる。
@MainActor
struct TerminalThemeColorReportingTests {
    /// `IntegratedPanelTheme`の灰レベル（0〜255）を、SwiftTermが
    /// `getTerminalColor()`で作る16bit成分と同じ式で写す。
    private func component(_ level: CGFloat) -> UInt16 {
        UInt16(level / 255.0 * 65535.0)
    }

    private func makeView(appearance: NSAppearance.Name) -> LoggingTerminalView {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.appearance = NSAppearance(named: appearance)
        view.resolveThemeColors()
        return view
    }

    @Test func darkAppearanceReportsDarkColors() {
        let view = makeView(appearance: .darkAqua)
        #expect(view.terminal.backgroundColor.red == component(18))
        #expect(view.terminal.foregroundColor.red == component(215))
    }

    @Test func lightAppearanceReportsLightColors() {
        let view = makeView(appearance: .aqua)
        #expect(view.terminal.backgroundColor.red == component(252))
        #expect(view.terminal.foregroundColor.red == component(30))
    }

    /// 明るさを切り替えたら、照会への答えも新しい外観で解き直される。
    @Test func appearanceChangeReResolvesReportedColors() {
        let view = makeView(appearance: .aqua)
        view.appearance = NSAppearance(named: .darkAqua)
        #expect(view.terminal.backgroundColor.red == component(18))
        #expect(view.terminal.foregroundColor.red == component(215))
    }
}
