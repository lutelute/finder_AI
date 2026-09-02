import AppKit
import FinderAICore
import Testing

@testable import FinderAIApp

/// 色が載る面と載らない面を固定する。
///
/// 「額縁だけ」を選んだので、ファイル一覧の地が色付きになったらそれは退行。
/// 見た目の話に見えるが、一覧の地に色を敷くと副文のコントラストが落ちるので、
/// 読めるかどうかの話でもある。
@MainActor
@Suite("窓の色は額縁にだけ載る")
struct WindowTintPaintingTests {
    private func rgb(_ color: CGColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB)
        return (c?.redComponent ?? 0, c?.greenComponent ?? 0, c?.blueComponent ?? 0)
    }

    private func isGrey(_ color: CGColor) -> Bool {
        let c = rgb(color)
        return abs(c.r - c.g) < 0.002 && abs(c.g - c.b) < 0.002
    }

    @Test("額縁の面は色が付き、中身の面は灰のまま")
    func onlyFrameSurfacesTakeTheTint() {
        let painter = ThemedLayerPainter()
        painter.appearance = NSAppearance(named: .aqua)

        let frame = NSView()
        let content = NSView()
        let host = NSView()
        host.addSubview(frame)
        host.addSubview(content)

        painter.register(frame, role: .frame) { IntegratedPanelTheme.sidebar }
        painter.register(content) { IntegratedPanelTheme.background }

        // 色なしのうちは、どちらも灰。
        #expect(isGrey(frame.layer?.backgroundColor ?? .clear))
        #expect(isGrey(content.layer?.backgroundColor ?? .clear))

        painter.tint = .teal
        painter.repaint()

        #expect(!isGrey(frame.layer?.backgroundColor ?? .clear))
        #expect(isGrey(content.layer?.backgroundColor ?? .clear))
    }

    @Test("色を外すと額縁も灰へ戻る")
    func clearingTheTintRestoresGrey() {
        let painter = ThemedLayerPainter()
        painter.appearance = NSAppearance(named: .aqua)
        let frame = NSView()
        NSView().addSubview(frame)
        painter.register(frame, role: .frame) { IntegratedPanelTheme.sidebar }

        painter.tint = .azuki
        painter.repaint()
        #expect(!isGrey(frame.layer?.backgroundColor ?? .clear))

        painter.tint = nil
        painter.repaint()
        #expect(isGrey(frame.layer?.backgroundColor ?? .clear))
    }

    @Test("混ぜても地の側が勝っている")
    func theGroundStillDominates() {
        // 目印であって塗り替えではない。混ぜた色が元の地より、混ぜる色に
        // 近くなってしまうと、6枚並べたときにどれも「色の窓」になって
        // フォルダの中身より色のほうが目立つ。
        let appearance = NSAppearance(named: .aqua)!
        var mixed: NSColor = .black
        var ground: NSColor = .black
        appearance.performAsCurrentDrawingAppearance {
            ground = IntegratedPanelTheme.sidebar.usingColorSpace(.sRGB) ?? .black
            mixed = ThemedLayerPainter.blend(.teal, into: IntegratedPanelTheme.sidebar, isDark: false)
        }
        let m = mixed.usingColorSpace(.sRGB)!
        let toGround = abs(m.redComponent - ground.redComponent)
            + abs(m.greenComponent - ground.greenComponent)
            + abs(m.blueComponent - ground.blueComponent)
        // 純色そのもの（0x3F7F8C）との距離
        let pure = NSColor(srgbRed: 0x3F / 255.0, green: 0x7F / 255.0, blue: 0x8C / 255.0, alpha: 1)
        let toPure = abs(m.redComponent - pure.redComponent)
            + abs(m.greenComponent - pure.greenComponent)
            + abs(m.blueComponent - pure.blueComponent)
        #expect(toGround < toPure)
    }

    @Test("色なしの blend は地をそのまま返す")
    func blendWithoutTintIsIdentity() {
        let appearance = NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let base = IntegratedPanelTheme.header
            let out = ThemedLayerPainter.blend(nil, into: base, isDark: false)
            #expect(out == base)
        }
    }

    @Test("明暗で混ざる結果が変わる")
    func lightAndDarkDiffer() {
        // 同じ色・同じ地の名前でも、解ける地の明るさが違えば結果は別。
        // ここが同じになるなら、動的色が片方の明るさで固まっている。
        var light: NSColor = .black
        var dark: NSColor = .black
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            light = ThemedLayerPainter.blend(.moss, into: IntegratedPanelTheme.sidebar, isDark: false)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = ThemedLayerPainter.blend(.moss, into: IntegratedPanelTheme.sidebar, isDark: true)
        }
        #expect(light.usingColorSpace(.sRGB)!.brightnessComponent
            > dark.usingColorSpace(.sRGB)!.brightnessComponent)
    }

    @Test("6色それぞれが、同じ地の上で違う色になる")
    func everyTintPaintsADistinctSurface() {
        // メニューで選び分けられても、混ぜた後に見分けが付かなければ意味がない。
        var painted: Set<String> = []
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for tint in WorkspaceWindowTint.allCases {
                let c = ThemedLayerPainter
                    .blend(tint, into: IntegratedPanelTheme.sidebar, isDark: false)
                    .usingColorSpace(.sRGB)!
                painted.insert(String(
                    format: "%.3f-%.3f-%.3f",
                    c.redComponent, c.greenComponent, c.blueComponent
                ))
            }
        }
        #expect(painted.count == WorkspaceWindowTint.allCases.count)
    }
}
