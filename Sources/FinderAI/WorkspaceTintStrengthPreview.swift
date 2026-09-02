import AppKit
import FinderAICore

/// 濃さのスライダーに添える見本。6色を、いまの濃さで額縁に敷いた姿で並べる。
///
/// 数字（45%）だけでは決められない。「どれくらい色が付くか」は見ないと分からず、
/// 見るために毎回スライダーを動かして窓を確かめるのでは、行ったり来たりになる。
/// 手元に答えを置く。
///
/// 一枚ずつが小さな窓の形をしているのは、実際に色が乗る面の比率——上の帯、
/// 左のサイドバー、右のファイル一覧——をそのまま写すため。**ファイル一覧の
/// ぶんは色が付かない**ことも、ここで分かる。
@MainActor
final class WorkspaceTintStrengthPreview: NSView {
    var strength: Double = WorkspaceWindowTint.defaultStrength {
        didSet {
            guard strength != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tints = WorkspaceWindowTint.allCases
        guard !tints.isEmpty else { return }
        let isDark = effectiveAppearance.isDark
        let gap: CGFloat = 4
        let cellWidth = (bounds.width - gap * CGFloat(tints.count - 1)) / CGFloat(tints.count)
        guard cellWidth > 0 else { return }

        for (index, tint) in tints.enumerated() {
            let cell = NSRect(
                x: CGFloat(index) * (cellWidth + gap),
                y: 0,
                width: cellWidth,
                height: bounds.height
            )
            draw(tint: tint, in: cell, isDark: isDark)
        }
    }

    private func draw(tint: WorkspaceWindowTint, in cell: NSRect, isDark: Bool) {
        let radius: CGFloat = 3
        let clip = NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()

        // ファイル一覧の地。ここには色を敷かない。
        ThemedLayerPainter
            .blend(nil, into: IntegratedPanelTheme.background, isDark: isDark)
            .setFill()
        cell.fill()

        let framed = { (color: NSColor) in
            ThemedLayerPainter.blend(tint, into: color, isDark: isDark, strength: self.strength)
        }
        // 上の見出し（タイトルバーとツールバーのぶん）
        framed(IntegratedPanelTheme.header).setFill()
        NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.height * 0.42).fill()
        // 左のサイドバー
        framed(IntegratedPanelTheme.sidebar).setFill()
        NSRect(
            x: cell.minX,
            y: cell.minY + cell.height * 0.42,
            width: cell.width * 0.34,
            height: cell.height * 0.58
        ).fill()
        // 上端の帯。混ぜない一色なので濃さでは変わらない。
        WorkspaceWindowTintPalette.color(for: tint).setFill()
        NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: 2.5).fill()

        NSGraphicsContext.restoreGraphicsState()
        IntegratedPanelTheme.border.setStroke()
        clip.lineWidth = 1
        clip.stroke()
    }

    /// 画面に触らずに見た目を確かめるための口。
    func renderForTesting(size: NSSize) -> NSBitmapImageRep? {
        frame = NSRect(origin: .zero, size: size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
}
