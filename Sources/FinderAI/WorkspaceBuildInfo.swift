import Foundation

struct WorkspaceBuildIdentity: Equatable, Sendable {
    let version: String
    let build: String
    let commit: String

    init(infoDictionary: [String: Any]) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "開発版"
        build = infoDictionary["CFBundleVersion"] as? String ?? "–"
        commit = infoDictionary["FinderAIGitCommit"] as? String ?? "unknown"
    }

    var shortCommit: String {
        commit == "unknown" ? commit : String(commit.prefix(12))
    }
}

struct WorkspaceBuildInfo: Equatable, Sendable {
    enum InstallationState: Equatable, Sendable {
        case installed
        case restartRequired
        case developmentCopy
        case unbundled
    }

    static let installedAppURL = URL(
        fileURLWithPath: "/Applications/FinderAI.app",
        isDirectory: true
    )

    /// Bundle.main's Info.plist lives beside the executable and can be replaced
    /// while this process keeps running. Capture it before the event loop starts;
    /// reading Bundle.main lazily after an install would mistake the new file on
    /// disk for code that is already running.
    private static let runningIdentity = WorkspaceBuildIdentity(
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    )

    static func captureRunningIdentity() {
        _ = runningIdentity
    }

    let identity: WorkspaceBuildIdentity
    let bundleURL: URL
    let installationState: InstallationState

    init(
        infoDictionary: [String: Any],
        bundleURL: URL,
        installedInfoDictionary: [String: Any]? = nil
    ) {
        self.init(
            identity: WorkspaceBuildIdentity(infoDictionary: infoDictionary),
            bundleURL: bundleURL,
            installedInfoDictionary: installedInfoDictionary
        )
    }

    private init(
        identity: WorkspaceBuildIdentity,
        bundleURL: URL,
        installedInfoDictionary: [String: Any]? = nil
    ) {
        self.identity = identity
        self.bundleURL = bundleURL.standardizedFileURL

        guard bundleURL.pathExtension == "app" else {
            installationState = .unbundled
            return
        }
        if self.bundleURL == Self.installedAppURL.standardizedFileURL {
            if let installedInfoDictionary,
               WorkspaceBuildIdentity(infoDictionary: installedInfoDictionary) != identity {
                installationState = .restartRequired
            } else {
                installationState = .installed
            }
        } else {
            installationState = .developmentCopy
        }
    }

    static var current: WorkspaceBuildInfo {
        WorkspaceBuildInfo(
            identity: runningIdentity,
            bundleURL: Bundle.main.bundleURL,
            installedInfoDictionary: readInfoDictionary(
                at: installedAppURL.appendingPathComponent("Contents/Info.plist")
            )
        )
    }

    var versionText: String {
        "FinderAI \(identity.version)（build \(identity.build)）"
    }

    var commitText: String {
        identity.commit == "unknown"
            ? "commit: 未記録"
            : "commit: \(identity.shortCommit)"
    }

    var installationText: String {
        switch installationState {
        case .installed:
            "インストール済み — /Applications/FinderAI.app"
        case .restartRequired:
            "ディスク上に新版があります。FinderAIを終了して開き直してください。"
        case .developmentCopy:
            "開発用コピーから実行中 — \(bundleURL.path)"
        case .unbundled:
            "swift runによる開発実行中"
        }
    }

    private static func readInfoDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else { return nil }
        return value as? [String: Any]
    }
}
