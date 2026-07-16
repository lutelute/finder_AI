import AppKit
import Sparkle

/// Wraps Sparkle so the rest of the app never imports it.
///
/// The feed, the public key and the check interval live in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`, `SUScheduledCheckInterval`); the matching
/// private key lives in the developer's keychain and is never committed. An
/// update is only installed if it carries an EdDSA signature made by that key,
/// which is what stops a tampered download from being accepted — the app's own
/// ad-hoc/self-signed code signature would not.
@MainActor
final class WorkspaceUpdater {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true schedules the background check itself, honouring
        // SUEnableAutomaticChecks. Sparkle's default UI driver supplies the
        // "update available" window, so nothing here has to draw one.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Fully automatic: the daily background check downloads the update
        // silently and Sparkle's Autoupdate swaps it in when the app quits.
        // Without this the check only *offers* the update and every version
        // needs a click. Menu-initiated checks still show their UI.
        //
        // Note this cannot help an app that is force-killed: install-on-quit
        // needs a normal termination for Sparkle to hand over to its installer.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true

        // Deterministic trigger for testing the pipeline end-to-end: the daily
        // scheduler is otherwise the only thing that starts a *silent* check,
        // and waiting a day is not a test.
        if ProcessInfo.processInfo.environment["FINDERAI_CHECK_UPDATES"] == "1" {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// Wired to the app menu; Sparkle handles the "you're up to date" case.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Where the feed points, for the About panel and for diagnosing a build that
    /// silently never updates.
    var feedURL: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }
}
