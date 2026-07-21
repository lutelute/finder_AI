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

    @Test("TERM gets a grace period to run process cleanup")
    func gracefulCleanupRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-term-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let cleaned = root.appendingPathComponent("cleaned")
        let delegate = NoopLocalProcessDelegate()
        let process = LocalProcess(delegate: delegate, dispatchQueue: delegate.callbackQueue)
        process.startProcess(
            executable: "/bin/zsh",
            args: [
                "-f", "-c",
                "trap 'print -r -- cleaned > \"$CLEANED_PATH\"; exit 0' TERM; "
                    + "print -r -- ready > \"$READY_PATH\"; while true; do sleep 1; done"
            ],
            environment: [
                "TERM=xterm-256color",
                "READY_PATH=\(ready.path)",
                "CLEANED_PATH=\(cleaned.path)"
            ],
            currentDirectory: root.path
        )
        let pid = process.shellPid
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }

        OwnedProcessTerminator.terminate(process, gracePeriod: 1)

        try await waitUntil { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
        #expect(FileManager.default.fileExists(atPath: cleaned.path))
    }

    @Test("a process ignoring TERM is killed and reaped after the grace period")
    func stubbornProcessEscalates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderai-kill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let delegate = NoopLocalProcessDelegate()
        let process = LocalProcess(delegate: delegate, dispatchQueue: delegate.callbackQueue)
        process.startProcess(
            executable: "/bin/zsh",
            args: [
                "-f", "-c",
                "trap '' TERM; print -r -- ready > \"$READY_PATH\"; while true; do sleep 1; done"
            ],
            environment: ["TERM=xterm-256color", "READY_PATH=\(ready.path)"],
            currentDirectory: root.path
        )
        let pid = process.shellPid
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }

        OwnedProcessTerminator.terminate(process, gracePeriod: 0.06)

        try await waitUntil { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    private func waitUntil(
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for child process state")
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
