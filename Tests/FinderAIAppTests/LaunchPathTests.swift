import AppKit
import Foundation
@testable import FinderAIApp
import Testing

/// The launch path must not touch the filesystem before the first window exists.
///
/// Storing the last folder as a bookmark once made `lastDirectory` resolve it on
/// launch, which reached TCC and the filesystem and pushed time-to-window from
/// 363ms to 15.6s — the app looked like it never started. These tests pin the
/// property that prevented it: reading the preference is pure `UserDefaults`.
@Suite("Launch path stays off the filesystem")
@MainActor
struct LaunchPathTests {
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "finderai.launch.\(UUID().uuidString)"))
    }

    @Test("reading the last directory does not hit the filesystem")
    func lastDirectoryReadIsCheap() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        preferences.lastDirectory = URL(fileURLWithPath: "/tmp/somewhere", isDirectory: true)

        // A filesystem round-trip cannot happen in this budget; a bookmark
        // resolve on a protected folder took four orders of magnitude longer.
        let start = ContinuousClock.now
        for _ in 0..<1_000 { _ = preferences.lastDirectory }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100))
    }

    @Test("a folder that no longer exists is still returned, not silently dropped")
    func missingFolderIsReturnedForTheCallerToCheck() throws {
        // The getter must not verify existence itself — that is the blocking call
        // we moved off the launch path. Validation belongs to the async caller.
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        let gone = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        preferences.lastDirectory = gone

        #expect(preferences.lastDirectory?.path == gone.path)
    }

    @Test("the last directory round-trips through a restart")
    func roundTrip() throws {
        let defaults = try makeDefaults()
        let folder = URL(fileURLWithPath: "/tmp/finderai round trip", isDirectory: true)
        WorkspacePreferences(defaults: defaults).lastDirectory = folder

        // A fresh instance stands in for the next launch.
        #expect(WorkspacePreferences(defaults: defaults).lastDirectory?.path == folder.path)
    }

    @Test("clearing removes the stored value")
    func clearing() throws {
        let preferences = WorkspacePreferences(defaults: try makeDefaults())
        preferences.lastDirectory = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        preferences.lastDirectory = nil
        #expect(preferences.lastDirectory == nil)
    }

    /// Existence is no longer the getter's job, so the reachability check that
    /// replaced it has to hold: a folder deleted between launches must not be
    /// restored, and a live one must be.
    @Test("reachability check rejects a folder deleted between launches")
    func reachabilityRejectsMissingFolder() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("launch-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(await WorkspaceAppCoordinator.isReachableDirectory(folder))

        try FileManager.default.removeItem(at: folder)
        #expect(await WorkspaceAppCoordinator.isReachableDirectory(folder) == false)
    }

    @Test("reachability check rejects a file where a folder is expected")
    func reachabilityRejectsFile() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("launch-file-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(await WorkspaceAppCoordinator.isReachableDirectory(file) == false)
    }
}
