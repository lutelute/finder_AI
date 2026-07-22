import Foundation

/// Asks the real Finder where its front window is, over Apple events.
///
/// Runs osascript as a child instead of NSAppleScript in-process: the query
/// never blocks the main thread while the user stares at the one-time
/// automation consent dialog, and no AppleScript machinery is loaded into the
/// app. TCC attributes the request to FinderAI either way.
enum FinderFrontWindow {
    enum LookupError: Error {
        /// Finder has no window open (it is showing only the Desktop).
        case noWindow
        /// The user declined the automation prompt, or revoked it later.
        case notAuthorized
        case failed(String)
    }

    static func currentFolder() async -> Result<URL, LookupError> {
        await Task.detached(priority: .userInitiated) { () -> Result<URL, LookupError> in
            let script = """
            tell application "Finder"
                if (count of Finder windows) is 0 then return ""
                return POSIX path of (target of front Finder window as alias)
            end tell
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errorOutput, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // errAEEventNotPermitted — the automation consent was denied.
                return .failure(message.contains("-1743") ? .notAuthorized : .failed(message))
            }
            let path = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return .failure(.noWindow) }
            return .success(URL(fileURLWithPath: path, isDirectory: true))
        }.value
    }
}
