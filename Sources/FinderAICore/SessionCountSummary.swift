import Foundation

/// 「今いくつのAIが動いているか」の言い方。
///
/// 繋いでいる数と、tmuxで生きているが繋いでいない数は別物なのに、前者だけを
/// 見せていた。アプリを開き直した直後は後者しか無く、「実行中0件」と出て
/// 動いているAIが1つも無いように読めた。両方を数え、内訳が要るときだけ言う。
public struct SessionCountSummary: Equatable, Sendable {
    /// このアプリが繋いでいて動いているもの。
    public let attached: Int
    /// tmuxで生きているが、このアプリは繋いでいないもの。
    public let detached: Int

    public init(attached: Int, detached: Int) {
        self.attached = max(0, attached)
        self.detached = max(0, detached)
    }

    public var total: Int { attached + detached }

    public var isIdle: Bool { total == 0 }

    /// 畳んだ帯に出す数。動いていなければ何も出さない。
    public var badgeText: String { isIdle ? "" : "\(total)" }

    /// 繋いでいないものがあるときだけ内訳を言う。全部繋がっているのに
    /// 「うち0件は未接続」と添えても読む手間が増えるだけ。
    private var breakdown: String {
        detached == 0 ? "" : "（うち\(detached)件は未接続）"
    }

    public var statusTooltip: String {
        isIdle ? "実行中のセッションはありません" : "実行中\(total)件\(breakdown)"
    }

    public var manageTooltip: String {
        isIdle
            ? "すべてのTerminalセッションを管理（⌘⌥T）"
            : "Terminalセッションを管理 — 実行中\(total)件\(breakdown)（⌘⌥T）"
    }
}
