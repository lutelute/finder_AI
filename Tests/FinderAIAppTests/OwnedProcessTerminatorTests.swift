import Darwin
import Foundation
@testable import FinderAIApp
@preconcurrency import SwiftTerm
import Testing

@Suite("FinderAI-owned PTY process termination")
@MainActor
struct OwnedProcessTerminatorTests {
    @Test("an interactive shell is killed and reaped instead of becoming a zombie")
    func interactiveShellIsReaped() async throws {
        let delegate = NoopLocalProcessDelegate()
        let process = LocalProcess(
            delegate: delegate,
            dispatchQueue: delegate.callbackQueue
        )
        process.startProcess(
            executable: "/bin/zsh",
            args: ["-f"],
            environment: ["TERM=xterm-256color"],
            currentDirectory: "/tmp"
        )
        let pid = process.shellPid
        #expect(pid > 1)
        #expect(process.running)

        OwnedProcessTerminator.terminate(process)

        for _ in 0..<200 {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let lookupResult = Darwin.kill(pid, 0)
        let lookupError = errno
        #expect(lookupResult == -1)
        #expect(lookupError == ESRCH)
    }
}

private final class NoopLocalProcessDelegate: @unchecked Sendable, LocalProcessDelegate {
    let callbackQueue = DispatchQueue(
        label: "com.shigenoburyuto.finderai.tests.process-termination"
    )

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func dataReceived(slice: ArraySlice<UInt8>) {}
    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}
