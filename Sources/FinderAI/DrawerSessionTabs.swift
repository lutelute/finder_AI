import Foundation

/// One row per drawer tab. The strip always carries every presented session —
/// not just the current folder's — because a claude running in another folder
/// silently vanishing from view on navigation was the drawer's biggest usability
/// hole. Sessions from other folders stay visible and say where they live via a
/// folder suffix, so the folder↔terminal binding is readable in the strip itself
/// instead of only inside the binding menu.
struct DrawerSessionTab: Equatable {
    let id: UUID
    let title: String
    let tooltip: String
    let isRunning: Bool
    let isActive: Bool
    let belongsToCurrentFolder: Bool
}

enum DrawerSessionTabs {
    struct Source: Equatable {
        let id: UUID
        let kindName: String
        let directoryURL: URL
        let isRunning: Bool
        let isAnchored: Bool

        init(
            id: UUID,
            kindName: String,
            directoryURL: URL,
            isRunning: Bool,
            isAnchored: Bool = false
        ) {
            self.id = id
            self.kindName = kindName
            self.directoryURL = directoryURL
            self.isRunning = isRunning
            self.isAnchored = isAnchored
        }
    }

    static func rows(
        sources: [Source],
        currentDirectory: URL?,
        activeID: UUID?
    ) -> [DrawerSessionTab] {
        let current = currentDirectory?.standardizedFileURL
        return sources.map { source in
            let directory = source.directoryURL.standardizedFileURL
            let belongsToCurrentFolder = directory == current
            let folder = directory.lastPathComponent.isEmpty
                ? directory.path(percentEncoded: false)
                : directory.lastPathComponent
            var name = source.isRunning ? "●  \(source.kindName)" : source.kindName
            // An anchored shell deliberately stays put; the pin says "this one
            // does not follow you" right on the tab.
            if source.isAnchored { name = "📌 \(name)" }
            return DrawerSessionTab(
                id: source.id,
                title: belongsToCurrentFolder ? name : "\(name) · \(folder)",
                tooltip: "\(source.kindName) — \(directory.path(percentEncoded: false))",
                isRunning: source.isRunning,
                isActive: source.id == activeID,
                belongsToCurrentFolder: belongsToCurrentFolder
            )
        }
    }
}
