import AppKit
import FinderAICore
import ScreenCaptureKit

/// 一覧の行に触れたとき、そのウインドウの位置に重ねる枠。
///
/// ウインドウ自体は動かさない。前面へ浮かせると探しているあいだじゅう他のアプリ
/// が覆われるが、枠なら重なりに一切触らずに「どれのことか」だけ伝わる。
///
/// クリックは通す。枠は見せるためだけのもので、その下にあるものを触れなくして
/// しまっては本末転倒。
@MainActor
final class WindowPeekOutline {
    private let panel: NSPanel
    private let outline = OutlineView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.contentView = outline
    }

    var isVisible: Bool { panel.isVisible }

    func show(around frame: CGRect) {
        // 枠は線の太さぶん外側へ回す。ウインドウの縁に重ねると、角の丸みの
        // ぶんだけ食い込んで見える。
        panel.setFrame(frame.insetBy(dx: -5, dy: -5), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        // 薄く塗ってから縁取る。線だけだと、模様の多い画面では枠が溶ける。
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 5
        path.stroke()
    }
}

/// 一覧の横に出す、そのウインドウの中身の縮小。
///
/// 画面収録の許可が要る。許可がないと真っ黒な板が出るだけなので、取れていない
/// ときは何も出さず、枠のほうへ任せる。
@MainActor
final class WindowPeekThumbnail {
    private let panel: NSPanel
    private let imageView = NSImageView()

    /// 縮小の長辺。これ以上大きくすると、覗くだけのつもりが画面を占める。
    private static let maxSide: CGFloat = 360
    private static let padding: CGFloat = 8

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        let backdrop = ThumbnailBackdrop()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Self.padding),
            imageView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Self.padding),
            imageView.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: Self.padding),
            imageView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -Self.padding)
        ])
        panel.contentView = backdrop
    }

    var isVisible: Bool { panel.isVisible }

    /// 画面収録の許可があるか。求めはしない——覗いただけで許可を訊かれるのは
    /// 唐突なので、確認は設定でこの見せ方を選んだときに行う。
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// そのウインドウの中身を撮る。撮れなければnil。
    ///
    /// `CGWindowListCreateImage`は使えなくなったので`ScreenCaptureKit`で撮る。
    /// 非同期なので、返るころには別の行へ移っているかもしれない——呼ぶ側で
    /// 取り消せるようにしてある。
    static func snapshot(of window: NSWindow) async -> NSImage? {
        let id = CGWindowID(window.windowNumber)
        guard id != 0 else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ), let target = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width)
        configuration.height = Int(target.frame.height)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target),
            configuration: configuration
        ), image.width > 1, image.height > 1 else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// 一覧の横へ、縦横比を保って出す。
    func show(_ image: NSImage, besides anchor: CGRect, edge: WorkspaceScreenEdge, on screen: CGRect) {
        imageView.image = image
        let ratio = image.size.height / max(image.size.width, 1)
        var width = Self.maxSide
        var height = width * ratio
        if height > Self.maxSide {
            height = Self.maxSide
            width = height / max(ratio, 0.01)
        }
        let size = NSSize(width: width + Self.padding * 2, height: height + Self.padding * 2)

        // 一覧が画面の右寄りにあるなら左へ、左寄りなら右へ置く。一覧の上に
        // 重ねてしまうと、次の行へ移れない。
        let gap: CGFloat = 8
        var x = edge == .right ? anchor.minX - size.width - gap : anchor.maxX + gap
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        var y = anchor.maxY - size.height
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)

        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        imageView.image = nil
    }
}

private final class ThumbnailBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        IntegratedPanelTheme.background.setFill()
        path.fill()
        IntegratedPanelTheme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
