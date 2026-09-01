import AppKit
import FinderAICore

/// ホイールがターミナルへ届く前に一度見るウインドウ。
///
/// 本来は`LoggingTerminalView`で`scrollWheel(with:)`を上書きしたい。だがSwiftTermの
/// `TerminalView.scrollWheel`は`public`であって`open`ではなく、モジュールの外から
/// 上書きすると`overriding non-open instance method outside of its defining module`で
/// 弾かれる。`NSEvent`のローカルモニタも使えない——ハンドラが`@Sendable`なのに
/// `NSEvent`はSendableではないため、Swift 6ではコンパイルが通らない。
/// 残るのが配送の一段手前、ウインドウの`sendEvent`。ここで落とす。
///
/// 何を落とすかの判断は`TerminalWheelRouting`にある。
final class TerminalWheelWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, swallowsWheel(event) { return }
        super.sendEvent(event)
    }

    /// ポインタの下がターミナルで、そのホイールを渡してはいけないか。
    /// SwiftTermはカーソルなどの子ビューを重ねるので、当たったビューから親を辿る。
    private func swallowsWheel(_ event: NSEvent) -> Bool {
        guard let contentView else { return false }
        var candidate = contentView.hitTest(event.locationInWindow)
        while let view = candidate {
            if let terminal = view as? LoggingTerminalView {
                return terminal.wheelAction(for: event) == .swallow
            }
            candidate = view.superview
        }
        return false
    }
}
