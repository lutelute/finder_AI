import AppKit
import Foundation
import UniformTypeIdentifiers

/// ユーザーが明示的に選んだときだけ、現在Terminalに残っている表示バッファを
/// テキストとして保存する。常時ログとは違い、タブを隠すだけではディスクへ書かない。
@MainActor
enum SessionTranscriptExporter {
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
