import Foundation

/// Watches one directory for content changes and reports them on the main actor.
///
/// Uses a vnode source on an open descriptor rather than FSEvents: only one
/// directory is ever observed, no subtree recursion is wanted, and this keeps the
/// app free of the FSEvents run-loop lifecycle.
///
/// Editors write via create-temp/rename/delete, which fires several events for one
/// logical change, so callbacks are coalesced and delivered after a quiet period.
@MainActor
final class DirectoryWatcher {
    private var source: (any DispatchSourceFileSystemObject)?
    private var descriptor: CInt = -1
    private var debounceTask: Task<Void, Never>?
    private let debounce: Duration

    private(set) var watchedURL: URL?

    init(debounce: Duration = .milliseconds(200)) {
        self.debounce = debounce
    }

    deinit {
        // `source` owns the descriptor via its cancel handler; cancelling from a
        // nonisolated deinit is safe because DispatchSource is thread-safe.
        source?.cancel()
    }

    /// Starts watching `url`, replacing any previous watch. Passing the currently
    /// watched URL is a no-op so navigation churn does not thrash descriptors.
    func start(url: URL, onChange: @escaping @MainActor () -> Void) {
        let url = url.standardizedFileURL
        guard watchedURL != url else { return }
        stop()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleCallback(onChange)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        self.source = source
        descriptor = fd
        watchedURL = url
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
        descriptor = -1
        watchedURL = nil
    }

    private func scheduleCallback(_ onChange: @escaping @MainActor () -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
