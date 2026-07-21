import AppKit
import Foundation
import UniformTypeIdentifiers

enum SessionTranscriptArchiveError: LocalizedError, Equatable {
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            "このセッションのTerminal表示を取得できませんでした。"
        }
    }
}

/// 現在Terminalに残っている表示バッファをテキストとして保存する。
/// 手動保存または完全終了確認のチェックボックスで明示されたときだけ書き込み、
/// 常時ログとは違ってタブを隠すだけではディスクへ書かない。
@MainActor
enum SessionTranscriptExporter {
    /// A destructive close first leaves a short-lived recovery artifact in the
    /// same folder exposed by Settings. Explicit user exports still go wherever
    /// the save panel chooses and are not subject to log pruning.
    static func archiveBeforeTermination(
        _ session: any ManagedTerminalSession,
        directory: URL = SessionLogStore.directory,
        date: Date = Date()
    ) throws -> URL {
        guard let transcript = session.transcriptData() else {
            throw SessionTranscriptArchiveError.transcriptUnavailable
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let baseName = URL(fileURLWithPath: SessionLogStore.fileName(
            kind: session.kind,
            directoryURL: session.directoryURL,
            date: date
        )).deletingPathExtension().lastPathComponent
        let destination = directory.appendingPathComponent(
            "\(baseName)-終了前記録.log",
            isDirectory: false
        )
        let header = SessionLogStore.header(
            kind: session.kind,
            directoryURL: session.directoryURL,
            date: date
        ) + "# saved automatically before permanent termination\n\n"
        var data = Data(header.utf8)
        data.append(transcript)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func present(
        for session: any ManagedTerminalSession,
        attachedTo window: NSWindow?
    ) {
        let panel = NSSavePanel()
        panel.title = "セッション記録を保存"
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        let logName = SessionLogStore.fileName(
            kind: session.kind,
            directoryURL: session.directoryURL
        )
        panel.nameFieldStringValue = URL(fileURLWithPath: logName)
            .deletingPathExtension()
            .appendingPathExtension("txt")
            .lastPathComponent

        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            guard let data = session.transcriptData() else {
                presentError(
                    title: "記録を取得できません",
                    message: "このセッションのTerminalバッファを読み取れませんでした。",
                    attachedTo: window
                )
                return
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                presentError(
                    title: "記録を保存できません",
                    message: error.localizedDescription,
                    attachedTo: window
                )
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private static func presentError(
        title: String,
        message: String,
        attachedTo window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
