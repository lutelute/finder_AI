import AppKit
import FinderAICore
@testable import FinderAIApp
import Testing

@Suite("ターミナルのホイール")
@MainActor
struct TerminalWheelTests {
    private func scrollEvent() throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func terminalView() -> LoggingTerminalView {
        LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    /// ホストからの出力と同じ道（`dataReceived`）で流す。ここを通らないと、
    /// SwiftTermの画面状態とこちらのモード追跡がずれていても気づけない。
    private func feed(_ view: LoggingTerminalView, _ text: String) {
        view.dataReceived(slice: ArraySlice(Array(text.utf8)))
    }

    @Test("普通の画面ではSwiftTermへ渡す（スクロールバックを遡る）")
    func primaryScreenForwards() throws {
        #expect(terminalView().wheelAction(for: try scrollEvent()) == .forward)
    }

    @Test("alternate screenへ入ったら渡さない")
    func alternateScreenSwallows() throws {
        // tmuxのシェルもclaudeもここに入る。渡すとSwiftTermが↑↓キーを送り、
        // スクロールではなく履歴が呼び出される。
        let view = terminalView()
        feed(view, "\u{1b}[?1049h")
        #expect(view.wheelAction(for: try scrollEvent()) == .swallow)
    }

    @Test("1007を立てたアプリには従来どおり渡す")
    func alternateScrollForwards() throws {
        let view = terminalView()
        feed(view, "\u{1b}[?1049h")
        feed(view, "\u{1b}[?1007h")
        #expect(view.wheelAction(for: try scrollEvent()) == .forward)
    }

    @Test("マウスを見ているアプリには渡す")
    func mouseReportingForwards() throws {
        let view = terminalView()
        feed(view, "\u{1b}[?1049h")
        feed(view, "\u{1b}[?1000h")
        #expect(view.wheelAction(for: try scrollEvent()) == .forward)
    }

    @Test("普通の画面へ戻ればまた渡す")
    func returningToPrimaryForwards() throws {
        let view = terminalView()
        feed(view, "\u{1b}[?1049h")
        feed(view, "\u{1b}[?1049l")
        #expect(view.wheelAction(for: try scrollEvent()) == .forward)
    }
}
