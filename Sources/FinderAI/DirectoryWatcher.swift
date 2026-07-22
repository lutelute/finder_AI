import Foundation

/// Watches one directory for content changes and reports them on the main actor.
///
/// Uses vnode sources on open descriptors rather than FSEvents: only one
/// directory is ever observed, no subtree recursion is wanted, and this keeps the
/// app free of the FSEvents run-loop lifecycle.
///
/// An open descriptor keeps tracking its vnode across moves, so when the watched
/// directory — or any ancestor — is renamed or moved, `F_GETPATH` on the
/// directory's own descriptor recovers the new location and the watch re-arms
/// there. Ancestors carry descriptors purely as rename triggers, because a
/// vnode rename event never fires on a child whose parent moved.
///
/// Editors write via create-temp/rename/delete, which fires several events for one
/// logical change, so content callbacks are coalesced and delivered after a quiet
/// period. Relocation and deletion are delivered immediately: they invalidate the
/// path on screen, and a debounce would only widen the window in which the UI
/// shows a folder that no longer exists.
@MainActor
final class DirectoryWatcher {
    enum Event: Equatable {
        /// Something inside the directory changed; the path is still valid.
        case contentsChanged
        /// The directory (or an ancestor) was moved or renamed and now lives at
        /// `to`. The watcher has already re-armed itself at the new location.
        case relocated(from: URL, to: URL)
        /// The directory was deleted, trashed, or its volume went away.
        case disappeared(URL)
    }

    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var directoryDescriptor: CInt = -1
    private var ancestorSources: [any DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?
    private let debounce: Duration
    private var handler: (@MainActor (Event) -> Void)?

    private(set) var watchedURL: URL?

    init(debounce: Duration = .milliseconds(200)) {
        self.debounce = debounce
    }

    deinit {
        // Sources own their descriptors via their cancel handlers; cancelling
        // from a nonisolated deinit is safe because DispatchSource is thread-safe.
        directorySource?.cancel()
        for source in ancestorSources { source.cancel() }
    }

    /// Starts watching `url`, replacing any previous watch. Passing the currently
    /// watched URL only refreshes the handler so navigation churn does not thrash
    /// descriptors.
    func start(url: URL, onEvent: @escaping @MainActor (Event) -> Void) {
        let url = url.standardizedFileURL
        handler = onEvent
        guard watchedURL != url else { return }
        arm(at: url)
    }

    func stop() {
        disarm()
        handler = nil
    }

    // MARK: - Arming

    private func arm(at url: URL) {
        disarm()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        directorySource = makeSource(descriptor: fd, mask: [.write, .rename, .delete, .revoke]) {
            [weak self] flags in
            self?.handleDirectoryEvent(flags)
        }
        directoryDescriptor = fd
        watchedURL = url

        // Ancestor descriptors are triggers only; path recovery always goes
        // through the directory's own descriptor, which follows the move no
        // matter which level of the hierarchy was dragged. An unopenable
        // ancestor just loses that one trigger.
        for ancestor in Self.ancestors(of: url) {
            let ancestorFD = open(ancestor.path, O_EVTONLY)
            guard ancestorFD >= 0 else { continue }
            ancestorSources.append(
                makeSource(descriptor: ancestorFD, mask: [.rename, .delete, .revoke]) {
                    [weak self] _ in
                    self?.resolveRelocation()
                }
            )
        }
    }

    private func disarm() {
        debounceTask?.cancel()
        debounceTask = nil
        directorySource?.cancel()
        directorySource = nil
        directoryDescriptor = -1
        for source in ancestorSources { source.cancel() }
        ancestorSources = []
        watchedURL = nil
    }

    private func makeSource(
        descriptor: CInt,
        mask: DispatchSource.FileSystemEvent,
        onEvent: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: .main
        )
        // The handler keeps `source` alive until `cancel()`; every source made
        // here is cancelled in `disarm` or `deinit`.
        source.setEventHandler {
            let flags = source.data
            MainActor.assumeIsolated {
                onEvent(flags)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    // MARK: - Events

    private func handleDirectoryEvent(_ flags: DispatchSource.FileSystemEvent) {
        if flags.contains(.delete) || flags.contains(.revoke) {
            reportDisappeared()
        } else if flags.contains(.rename) {
            resolveRelocation()
        } else {
            scheduleContentsChanged()
        }
    }

    private func resolveRelocation() {
        guard let watchedURL else { return }
        // An unlinked vnode can still answer F_GETPATH with its stale path, so
        // existence is checked besides the descriptor lookup.
        guard directoryDescriptor >= 0,
              let currentPath = Self.currentPath(of: directoryDescriptor),
              FileManager.default.fileExists(atPath: currentPath) else {
            reportDisappeared()
            return
        }
        let current = URL(fileURLWithPath: currentPath, isDirectory: true).standardizedFileURL
        guard current != watchedURL else { return }
        guard !Self.isInTrash(current) else {
            // Following a folder into the Trash would resurrect it on screen;
            // trashing means the user wants it gone.
            reportDisappeared()
            return
        }
        // Re-arm before reporting: the handler will navigate, and its follow-up
        // `start` with the new URL must find the watch already consistent.
        arm(at: current)
        handler?(.relocated(from: watchedURL, to: current))
    }

    private func reportDisappeared() {
        guard let watchedURL else { return }
        disarm()
        handler?(.disappeared(watchedURL))
    }

    private func scheduleContentsChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            handler?(.contentsChanged)
        }
    }

    // MARK: - Paths

    private static func currentPath(of descriptor: CInt) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    private static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    /// Every ancestor except the volume root, deepest first.
    private static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.deletingLastPathComponent().standardizedFileURL
        while current.pathComponents.count > 1 {
            result.append(current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return result
    }
}
