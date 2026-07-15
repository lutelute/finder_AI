import Darwin
import Foundation

/// A kernel-owned advisory lock prevents duplicate panels even if the binary
/// is launched directly rather than through LaunchServices. A crash releases
/// the lock automatically; the harmless file may remain in the user temp dir.
final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init?(identifier: String = "com.shigenoburyuto.finderai") {
        let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "-")
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeIdentifier).lock", isDirectory: false)
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        fileDescriptor = descriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}
