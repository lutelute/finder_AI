import Foundation
@testable import FinderAIApp
import Testing

@Suite("Build identity and installation state")
struct WorkspaceBuildInfoTests {
    private let current: [String: Any] = [
        "CFBundleShortVersionString": "1.3.0",
        "CFBundleVersion": "18",
        "FinderAIGitCommit": "1234567890abcdef"
    ]

    @Test("the installed app reports its exact version and commit")
    func installedIdentity() {
        let info = WorkspaceBuildInfo(
            infoDictionary: current,
            bundleURL: WorkspaceBuildInfo.installedAppURL,
            installedInfoDictionary: current
        )

        #expect(info.installationState == .installed)
        #expect(info.versionText == "FinderAI 1.3.0（build 18）")
        #expect(info.commitText == "commit: 1234567890ab")
    }

    @Test("a replaced on-disk app tells the running copy to restart")
    func pendingRestart() {
        let disk: [String: Any] = [
            "CFBundleShortVersionString": "1.3.1",
            "CFBundleVersion": "19",
            "FinderAIGitCommit": "fedcba9876543210"
        ]
        let info = WorkspaceBuildInfo(
            infoDictionary: current,
            bundleURL: WorkspaceBuildInfo.installedAppURL,
            installedInfoDictionary: disk
        )

        #expect(info.installationState == .restartRequired)
        #expect(info.installationText.contains("終了して開き直して"))
    }

    @Test("dist and swift-run builds are never mistaken for the installed app")
    func developmentLocations() {
        let dist = WorkspaceBuildInfo(
            infoDictionary: current,
            bundleURL: URL(fileURLWithPath: "/tmp/FinderAI.app", isDirectory: true),
            installedInfoDictionary: current
        )
        let swiftRun = WorkspaceBuildInfo(
            infoDictionary: [:],
            bundleURL: URL(fileURLWithPath: "/tmp/debug", isDirectory: true)
        )

        #expect(dist.installationState == .developmentCopy)
        #expect(swiftRun.installationState == .unbundled)
    }
}
