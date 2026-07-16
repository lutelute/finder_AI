import AppKit
import FinderAICore
import UniformTypeIdentifiers

/// Hands cells a file icon without letting Launch Services block the main
/// thread.
///
/// `NSWorkspace.icon(forFile:)` is a synchronous XPC round-trip. The list and
/// column views used to pay it per visible cell on every navigation and every
/// scroll — tens of milliseconds of main-thread stall per folder, which is
/// what「読み込みがやや遅い」was. Cells now get an icon synchronously from
/// cache (exact if this file was seen before, otherwise generic for its type)
/// and the exact icon — custom folder images, app bundles, badges — arrives
/// asynchronously.
///
/// Cached images are shared instances; nothing may mutate them (`image.size`
/// included). Views scale via their own constraints instead.
@MainActor
final class WorkspaceIconProvider {
    static let shared = WorkspaceIconProvider()

    private let exactIcons = NSCache<NSString, NSImage>()
    private let genericIcons = NSCache<NSString, NSImage>()
    /// Callbacks waiting on a path already being resolved, so a fast scroll
    /// does not queue the same Launch Services lookup dozens of times.
    private var pendingCallbacks: [String: [@MainActor (NSImage) -> Void]] = [:]

    init() {
        exactIcons.countLimit = 4096
    }

    /// Never blocks: the exact icon when cached, a per-type stand-in otherwise.
    func quickIcon(for item: WorkspaceItem) -> NSImage {
        if let cached = exactIcons.object(forKey: item.url.path as NSString) {
            return cached
        }
        return genericIcon(for: item)
    }

    /// Resolves the file's real icon off the main thread. The completion runs
    /// on the main actor, and not at all when the exact icon was already
    /// cached — `quickIcon` already returned it in that case.
    func resolveIcon(
        for item: WorkspaceItem,
        completion: @escaping @MainActor (NSImage) -> Void
    ) {
        let path = item.url.path
        guard exactIcons.object(forKey: path as NSString) == nil else { return }
        if pendingCallbacks[path] != nil {
            pendingCallbacks[path]?.append(completion)
            return
        }
        pendingCallbacks[path] = [completion]
        Task.detached(priority: .userInitiated) {
            let image = NSWorkspace.shared.icon(forFile: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.exactIcons.setObject(image, forKey: path as NSString)
                for callback in self.pendingCallbacks.removeValue(forKey: path) ?? [] {
                    callback(image)
                }
            }
        }
    }

    private func genericIcon(for item: WorkspaceItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : item.url.pathExtension.lowercased()
        if let cached = genericIcons.object(forKey: key as NSString) {
            return cached
        }
        let type: UTType = item.isDirectory
            ? .folder
            : UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        genericIcons.setObject(image, forKey: key as NSString)
        return image
    }
}
