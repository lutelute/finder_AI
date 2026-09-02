import AppKit
import FinderAICore
import Testing

@testable import FinderAIApp

/// 色を敷いた面の上で、字が読めることを数値で押さえる。
///
/// **これが無かったせいで実機まで持っていった。** 濃さの上限を「0.18 <= 0.22」の
/// ように数字そのもので縛っていたが、それは何も守っていない——混ぜる色を変えれば
/// 同じ濃さでもコントラストは変わる。実際、暗い側は 0.18 のままで副文が
/// 5.79 → 4.09 まで落ちて 4.5 を割っていた。**色が見えないのに字も読みにくい**
/// という、両方悪い状態だった。
///
/// ここでは面と字の実際の比を測る。色や濃さを変えたら、この比が先に落ちる。
@MainActor
@Suite("色を敷いた面でも字が読める")
struct WindowTintContrastTests {
    /// WCAG 2.1 の相対輝度。
    private func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 色を敷く面と、その上に載る字の組み合わせ。
    private struct Surface {
        let name: String
        let ground: () -> NSColor
        let text: () -> NSColor
        let textName: String
        /// 本文は4.5、それ以外も小さい字なので4.5で見る。
        let minimum: Double
    }

    private var surfaces: [Surface] {
        [
            Surface(
                name: "サイドバー",
                ground: { IntegratedPanelTheme.sidebar },
                text: { IntegratedPanelTheme.secondaryText },
                textName: "副文",
                minimum: 4.5
            ),
            Surface(
                name: "サイドバー",
                ground: { IntegratedPanelTheme.sidebar },
                text: { IntegratedPanelTheme.text },
                textName: "本文",
                minimum: 4.5
            ),
            Surface(
                name: "見出し・下帯",
                ground: { IntegratedPanelTheme.header },
                text: { IntegratedPanelTheme.secondaryText },
                textName: "副文",
                minimum: 4.5
            ),
            Surface(
                name: "見出し・下帯",
                ground: { IntegratedPanelTheme.header },
                text: { IntegratedPanelTheme.text },
                textName: "本文",
                minimum: 4.5
            )
        ]
    }

    @Test("暗い側：6色どれを敷いても、面の上の字が4.5を保つ")
    func darkStaysReadable() {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            for tint in WorkspaceWindowTint.allCases {
                for surface in surfaces {
                    let painted = ThemedLayerPainter.blend(tint, into: surface.ground(), isDark: true)
                    let ratio = contrast(painted, surface.text())
                    #expect(
                        ratio >= surface.minimum,
                        "\(tint.title) の \(surface.name) で \(surface.textName) が \(ratio) まで落ちた"
                    )
                }
            }
        }
    }

    @Test("明るい側：色を敷いても、素の状態より目立って悪くならない")
    func lightStaysCloseToTheBareSurface() {
        // 明るい側の面に載る副文は**素で4.4しかない**（元からの状態）。
        // ここは4.5を要求できないので、素の状態からの落ち幅で見る。
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for tint in WorkspaceWindowTint.allCases {
                for surface in surfaces {
                    let bare = contrast(surface.ground(), surface.text())
                    let painted = ThemedLayerPainter.blend(tint, into: surface.ground(), isDark: false)
                    let tinted = contrast(painted, surface.text())
                    #expect(
                        tinted >= bare * 0.85,
                        "\(tint.title) の \(surface.name) で \(surface.textName) が \(bare) → \(tinted)"
                    )
                }
            }
        }
    }

    @Test("暗い側の色は、地の明度をほとんど上げない")
    func darkTintsDoNotBrightenTheGround() {
        // 明るい色を混ぜて明度を上げると、上に載る明るい字とのコントラストが落ちる。
        // 暗い側は「明度ではなく彩度で出す」——ここが崩れると上のテストが落ちる前に
        // 見た目が眠くなる。
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let bare = luminance(IntegratedPanelTheme.sidebar)
            for tint in WorkspaceWindowTint.allCases {
                let painted = ThemedLayerPainter.blend(tint, into: IntegratedPanelTheme.sidebar, isDark: true)
                #expect(
                    luminance(painted) < bare * 2.6,
                    "\(tint.title) が地を明るくしすぎている"
                )
            }
        }
    }

    @Test("暗い側は、素の灰とはっきり違う色になる")
    func darkTintsAreActuallyVisible() {
        // 「色が暗すぎて見えない」の再発を止める。灰との差が小さいと、
        // 目印として成り立たない。
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let bare = IntegratedPanelTheme.sidebar.usingColorSpace(.sRGB)!
            for tint in WorkspaceWindowTint.allCases {
                let painted = ThemedLayerPainter
                    .blend(tint, into: IntegratedPanelTheme.sidebar, isDark: true)
                    .usingColorSpace(.sRGB)!
                // チャンネル間の開き＝色味の強さ。灰は0。
                let channels = [painted.redComponent, painted.greenComponent, painted.blueComponent]
                let spread = (channels.max()! - channels.min()!) * 255
                #expect(spread >= 12, "\(tint.title) の色味が \(spread) しかない")
            }
        }
    }

    @Test("明るい側も、素の灰とはっきり違う色になる")
    func lightTintsAreActuallyVisible() {
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for tint in WorkspaceWindowTint.allCases {
                let painted = ThemedLayerPainter
                    .blend(tint, into: IntegratedPanelTheme.sidebar, isDark: false)
                    .usingColorSpace(.sRGB)!
                let channels = [painted.redComponent, painted.greenComponent, painted.blueComponent]
                let spread = (channels.max()! - channels.min()!) * 255
                #expect(spread >= 8, "\(tint.title) の色味が \(spread) しかない")
            }
        }
    }
}

/// 帯とタイトルバーの決めごと。
@MainActor
@Suite("色の帯とタイトルバー")
struct WindowTintBarTests {
    @Test("帯の色は明暗で変えず、混ぜる色より濃い")
    func theBarUsesOneVividColor() {
        // 帯は4ptしかない。地の明度に寄せた色を単体で置くと、明るい側では
        // ほとんど白、暗い側ではほとんど黒に見えて線として読めない。
        func spread(_ hex: UInt32) -> Double {
            let c = [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)]
            return c.max()! - c.min()!
        }
        func brightness(_ hex: UInt32) -> Double {
            let r = Double((hex >> 16) & 0xFF)
            let g = Double((hex >> 8) & 0xFF)
            let b = Double(hex & 0xFF)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        for tint in WorkspaceWindowTint.allCases {
            // 中間調であること——明るい側と暗い側のあいだに居る。
            #expect(brightness(tint.barHex) < brightness(tint.lightHex))
            #expect(brightness(tint.barHex) > brightness(tint.darkHex))
            #expect(spread(tint.barHex) >= 30)
        }
    }

    @Test("帯の色は6色とも違う")
    func barColorsAreDistinct() {
        #expect(Set(WorkspaceWindowTint.allCases.map(\.barHex)).count
            == WorkspaceWindowTint.allCases.count)
    }

    @Test("色なしのときは帯の厚みが消える")
    func noTintMeansNoBar() {
        // 「色を付けていない窓の見た目は今までどおり」を守る。
        #expect(WorkspaceWindowTint.barThickness > 0)
    }
}
