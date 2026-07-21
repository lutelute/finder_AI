import AppKit
import Foundation

/// Shared Finder-style drag/drop policy for list, column, gallery, and sidebar.
enum WorkspaceDragDrop {
    /// FinderAI folders can negotiate move or copy with each other. External
    /// shelves such as Dropover should only ever receive a copy operation; they
    /// are collecting a reference, not authorizing FinderAI to move the source.
    static let localSourceOperations: NSDragOperation = [.copy, .move]
    static let externalSourceOperations: NSDragOperation = [.copy]

    static func pasteboardWriter(for url: URL) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        guard item.setString(
            url.standardizedFileURL.absoluteString,
            forType: .fileURL
        ) else { return nil }
        return item
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL] ?? []
        return objects.map { ($0 as URL).standardizedFileURL }
    }

    /// Option means copy. Without Option, prefer move and fall back to copy for
    /// external sources that do not permit moving.
    static func operation(
        allowedOperations: NSDragOperation,
        optionKeyPressed: Bool
    ) -> NSDragOperation {
        if optionKeyPressed, allowedOperations.contains(.copy) { return .copy }
        if allowedOperations.contains(.move) { return .move }
        if allowedOperations.contains(.copy) { return .copy }
        return []
    }

    static func allows(
        sources: [URL],
        destination: URL,
        operation: NSDragOperation
    ) -> Bool {
        guard !sources.isEmpty, operation == .move || operation == .copy else { return false }
        let destination = destination.standardizedFileURL
        for source in sources.map(\.standardizedFileURL) {
            // A folder cannot be placed on itself. File service performs the
            // symlink-aware descendant check again before changing the disk.
            if source == destination { return false }
            // Moving to the current parent is a no-op. Option-copy is allowed;
            // it creates Finder-style "のコピー" names.
            if operation == .move,
               source.deletingLastPathComponent().standardizedFileURL == destination {
                return false
            }
        }
        return true
    }
}
