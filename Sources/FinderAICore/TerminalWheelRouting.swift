import Foundation

/// ホストが立てた`DECSET 1007`（alternate scroll）を、出力バイト列から拾って覚える。
///
/// SwiftTerm 1.14はこのモードを見ない。alternate screenでありさえすれば、ホイールを
/// 常に↑↓キーへ変換して前面のアプリへ送る。tmuxもclaudeもalternate screenで動くので、
/// 画面を送るつもりで回すたびにシェルの履歴や直前のプロンプトが呼び出されていた。
/// xtermと同じく、1007を立てたアプリにだけ矢印キーを渡したい——そのモードをここで持つ。
///
/// 出力は読み取りチャンクの切れ目でいくらでも割れるので、1バイトずつ状態機械で追う。
/// 完全なCSIパーサではなく、`ESC [ ? … h/l`だけを見分ければ足りる。
public struct AlternateScrollTracker: Sendable {
    public private(set) var isEnabled = false

    /// パラメータバイトの上限。これを超える列にDECSETは無い——壊れた列で
    /// 際限なく溜め込まないための蓋。
    private static let maximumParameterBytes = 64

    private enum State: Sendable {
        case ground
        case escape
        /// `ESC [`の後、パラメータバイト（0x30...0x3F）を集めている途中。
        case parameters([UInt8])
        /// DECSETではないと分かった列。最終バイトまで読み飛ばす。
        case skipping
    }

    private var state: State = .ground

    public init() {}

    public mutating func consume(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            consume(byte)
        }
    }

    private mutating func consume(_ byte: UInt8) {
        // 分岐の中で`self`を書き換えるので、読んだ状態を先に手元へ取る。
        let current = state
        switch current {
        case .ground:
            state = byte == 0x1B ? .escape : .ground
        case .escape:
            switch byte {
            case 0x5B: state = .parameters([]) // '['
            case 0x1B: state = .escape
            default: state = .ground
            }
        case let .parameters(collected):
            if byte == 0x1B {
                state = .escape
            } else if (0x30...0x3F).contains(byte) {
                var next = collected
                next.append(byte)
                state = next.count > Self.maximumParameterBytes ? .skipping : .parameters(next)
            } else if isFinalByte(byte) {
                apply(finalByte: byte, parameters: collected)
                state = .ground
            } else if (0x20...0x2F).contains(byte) {
                // 中間バイトが挟まる列にDECSETは無い。
                state = .skipping
            } else {
                // 制御文字。列が中断された。
                state = .ground
            }
        case .skipping:
            if byte == 0x1B {
                state = .escape
            } else if isFinalByte(byte) {
                state = .ground
            }
        }
    }

    private func isFinalByte(_ byte: UInt8) -> Bool {
        (0x40...0x7E).contains(byte)
    }

    private mutating func apply(finalByte: UInt8, parameters: [UInt8]) {
        guard finalByte == 0x68 || finalByte == 0x6C else { return } // 'h' / 'l'
        guard parameters.first == 0x3F else { return } // '?' 付きのDECSET/DECRSTだけ
        let body = String(decoding: parameters.dropFirst(), as: UTF8.self)
        // `ESC [ ? 1000 ; 1007 h`のようにまとめて立てられることがある。
        guard body.split(separator: ";").contains("1007") else { return }
        isEnabled = finalByte == 0x68
    }
}

/// ターミナルの上でホイールを回したとき、SwiftTermの既定処理へ渡すか、握り潰すか。
///
/// 握り潰すのはひとつの場合だけ——alternate screenで、1007が立っていないとき。
/// SwiftTermはそこで↑↓キーを送ってしまうが、それを求めていないアプリ（tmux、claude）
/// にとっては履歴を遡る打鍵そのもので、スクロールではない。何も起きないほうがまだ近い。
public enum TerminalWheelRouting {
    public enum Action: Equatable, Sendable {
        /// SwiftTermへ渡す。マウス報告か、スクロールバック送りになる。
        case forward
        /// 何もしない。
        case swallow
    }

    /// - Parameters:
    ///   - isAlternateBuffer: 画面がalternate screenか（`Terminal.isCurrentBufferAlternate`）。
    ///   - reportsMouse: このイベントがマウス報告としてアプリへ届くか。
    ///   - alternateScrollEnabled: ホストが1007を立てているか。
    public static func action(
        isAlternateBuffer: Bool,
        reportsMouse: Bool,
        alternateScrollEnabled: Bool
    ) -> Action {
        // マウスを見ているアプリ（tmux mouse on、エディタ）は自分でスクロールを解釈する。
        if reportsMouse { return .forward }
        guard isAlternateBuffer else { return .forward }
        return alternateScrollEnabled ? .forward : .swallow
    }
}
