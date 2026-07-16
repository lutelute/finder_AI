import AppKit
import FinderAICore

/// Our own "情報を見る" panel.
///
/// Finder's Get Info window belongs to Finder and cannot be opened for it, so
/// this shows the same facts from `URLResourceValues`.
///
/// Folder sizes are the reason this has an async path: Finder computes them by
/// walking the tree, which on a large folder or a network volume takes long
/// enough to freeze a window if done inline.
@MainActor
final class WorkspaceInfoWindowController: NSWindowController {
    private let url: URL
    private let sizeLabel = NSTextField(labelWithString: "計算中…")
    private var sizeTask: Task<Void, Never>?

    /// One panel per file, so ⌘I twice brings the same one forward instead of
    /// stacking duplicates.
    private static var open: [String: WorkspaceInfoWindowController] = [:]

    static func show(for url: URL) {
        let key = url.standardizedFileURL.path
        if let existing = open[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = WorkspaceInfoWindowController(url: url)
        open[key] = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL) {
        self.url = url.standardizedFileURL
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "\(self.url.lastPathComponent) の情報"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeContent() -> NSView {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .localizedTypeDescriptionKey, .isHiddenKey
        ])
        let isDirectory = values?.isDirectory ?? url.hasDirectoryPath

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        let iconView = NSImageView(image: icon)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle

        if let size = values?.fileSize, !isDirectory {
            sizeLabel.stringValue = Self.byteFormatter.string(fromByteCount: Int64(size))
        } else if !isDirectory {
            sizeLabel.stringValue = "—"
        } else {
            startFolderSizeCalculation()
        }

        let rows: [(String, String)] = [
            ("種類", values?.localizedTypeDescription ?? (isDirectory ? "フォルダ" : "ファイル")),
            ("作成日", values?.creationDate.map(Self.dateFormatter.string) ?? "—"),
            ("変更日", values?.contentModificationDate.map(Self.dateFormatter.string) ?? "—"),
            ("場所", url.deletingLastPathComponent().path(percentEncoded: false)),
            ("タグ", WorkspaceFileService().tags(of: url).joined(separator: ", ").ifEmpty("—"))
        ]

        let grid = NSGridView(views: [[label("サイズ"), sizeLabel]]
            + rows.map { [label($0.0), value($0.1)] })
        grid.columnSpacing = 10
        grid.rowSpacing = 7
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 200

        let stack = NSStackView(views: [iconView, name, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = IntegratedPanelTheme.background.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)
        ])
        return root
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = IntegratedPanelTheme.secondaryText
        return field
    }

    private func value(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = IntegratedPanelTheme.text
        field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = true
        return field
    }

    /// Walking a folder can take a long time on a big tree or a network volume,
    /// so it stays off the main actor and the panel opens with "計算中…".
    private func startFolderSizeCalculation() {
        let url = url
        sizeTask = Task { [weak self] in
            let bytes = await Self.folderSize(of: url)
            guard !Task.isCancelled else { return }
            self?.sizeLabel.stringValue = bytes.map {
                Self.byteFormatter.string(fromByteCount: $0)
            } ?? "—"
        }
    }

    private nonisolated static func folderSize(of url: URL) async -> Int64? {
        await Task.detached(priority: .utility) {
            // The walk itself is synchronous: `FileManager`'s enumerator cannot be
            // iterated from an async context.
            sumRegularFiles(under: url, isCancelled: { Task.isCancelled })
        }.value
    }

    private nonisolated static func sumRegularFiles(
        under url: URL,
        isCancelled: () -> Bool
    ) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return nil }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            // A deep tree can run long; abandoning it when the panel closes keeps
            // a closed window from pinning a core.
            if isCancelled() { return nil }
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

extension WorkspaceInfoWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        sizeTask?.cancel()
        Self.open.removeValue(forKey: url.path)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
