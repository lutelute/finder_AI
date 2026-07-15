import Darwin
import Foundation
@preconcurrency import SwiftTerm
import Testing

@Test func ptyStartsDirectlyInHostileDirectoryWithoutShellInterpolation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("finder-ai-pty-\(UUID().uuidString)", isDirectory: true)
    let hostileName = "- 日本語 quote'\" $(touch finder-ai-pwned) line\nbreak"
    let directory = root.appendingPathComponent(hostileName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let capture = PTYCapture()
    let process = LocalProcess(delegate: capture, dispatchQueue: capture.callbackQueue)
    let result = await withCheckedContinuation { continuation in
        capture.begin(continuation)
        process.startProcess(
            executable: "/bin/pwd",
            args: [],
            environment: nil,
            currentDirectory: directory.path
        )
    }

    let output = String(decoding: result.data, as: UTF8.self)
        .replacingOccurrences(of: "\r", with: "")
        .dropLast()
    let canonicalDirectory = directory.path.withCString { pathPointer -> String in
        guard let resolved = realpath(pathPointer, nil) else { return directory.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    #expect(String(output) == canonicalDirectory)
    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("finder-ai-pwned").path))
}

@Test func ptyAcceptsInputResizeAndContinuesWhileHostIsIdle() async throws {
    let capture = PTYCapture()
    let process = LocalProcess(delegate: capture, dispatchQueue: capture.callbackQueue)
    let result = await withCheckedContinuation { continuation in
        capture.begin(continuation)
        process.startProcess(
            executable: "/bin/zsh",
            args: ["-f"],
            environment: ["TERM=xterm-256color"],
            currentDirectory: "/tmp"
        )

        var resized = winsize(
            ws_row: 42,
            ws_col: 123,
            ws_xpixel: 1230,
            ws_ypixel: 840
        )
        #expect(PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: process.childfd,
            windowSize: &resized
        ) == 0)

        let script = """
        value='日本語 quote'
        printf 'INPUT_RESULT=<%s>\\n' "$value"
        stty size
        sleep 0.2
        printf 'CONTINUED_%s\\n' 'AFTER_IDLE_7C31'
        exit 0
        """ + "\n"
        let bytes = Array(script.utf8)
        process.send(data: bytes[...])
    }

    let output = String(decoding: result.data, as: UTF8.self)
        .replacingOccurrences(of: "\r", with: "")
    #expect(output.contains("INPUT_RESULT=<日本語 quote>"))
    #expect(output.contains("42 123"))
    #expect(output.contains("CONTINUED_AFTER_IDLE_7C31"))
    #expect(result.exitCode == 0)
}

private final class PTYCapture: @unchecked Sendable, LocalProcessDelegate {
    struct Result: Sendable {
        let data: Data
        let exitCode: Int32?
    }

    let callbackQueue = DispatchQueue(label: "com.shigenoburyuto.finderai.tests.pty")
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var exitCode: Int32?
    private var didTerminate = false
    private var continuation: CheckedContinuation<Result, Never>?

    func begin(_ continuation: CheckedContinuation<Result, Never>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.withLock {
            self.exitCode = exitCode
            didTerminate = true
            finishIfReady()
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        lock.withLock {
            bytes.append(contentsOf: slice)
            finishIfReady()
        }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    private func finishIfReady() {
        guard didTerminate, !bytes.isEmpty, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: Result(data: Data(bytes), exitCode: exitCode))
    }
}
