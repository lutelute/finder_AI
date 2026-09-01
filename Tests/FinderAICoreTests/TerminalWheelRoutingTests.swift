import FinderAICore
import Testing

@Suite("ホイールを矢印キーにするかの判定")
struct TerminalWheelRoutingTests {
    private func tracker(fed sequences: String...) -> AlternateScrollTracker {
        var tracker = AlternateScrollTracker()
        for sequence in sequences {
            tracker.consume(Array(sequence.utf8))
        }
        return tracker
    }

    @Test("何も来ていなければ1007は立っていない")
    func startsDisabled() {
        #expect(tracker().isEnabled == false)
    }

    @Test("ESC[?1007hで立ち、ESC[?1007lで下りる")
    func setAndReset() {
        #expect(tracker(fed: "\u{1b}[?1007h").isEnabled == true)
        #expect(tracker(fed: "\u{1b}[?1007h", "\u{1b}[?1007l").isEnabled == false)
    }

    @Test("読み取りチャンクが列の途中で割れても拾える")
    func survivesSplitChunks() {
        // PTYの読み取りは列の切れ目を守らない。ここで落とすと、モードを立てた
        // アプリにだけ矢印キーを渡すという前提そのものが崩れる。
        #expect(tracker(fed: "\u{1b}[?10", "07h").isEnabled == true)
        #expect(tracker(fed: "\u{1b}", "[", "?", "1", "0", "0", "7", "h").isEnabled == true)
    }

    @Test("まとめて立てられた列からも1007を見つける")
    func findsModeAmongOthers() {
        #expect(tracker(fed: "\u{1b}[?1000;1002;1007h").isEnabled == true)
        #expect(tracker(fed: "\u{1b}[?1007;1049h", "\u{1b}[?1000;1007l").isEnabled == false)
    }

    @Test("別のモードや?なしの列では動かない")
    func ignoresOtherSequences() {
        // 1049はalternate screenへの切り替え。これで1007まで立ったことにすると、
        // tmuxやclaudeに入った瞬間また矢印キーが飛ぶ。
        #expect(tracker(fed: "\u{1b}[?1049h").isEnabled == false)
        #expect(tracker(fed: "\u{1b}[1007h").isEnabled == false)
        #expect(tracker(fed: "\u{1b}[?10070h").isEnabled == false)
        #expect(tracker(fed: "\u{1b}[?1007m").isEnabled == false)
    }

    @Test("中断された列や長い列を跨いでも状態が壊れない")
    func recoversFromBrokenSequences() {
        var broken = AlternateScrollTracker()
        broken.consume(Array("\u{1b}[?100".utf8))
        broken.consume(Array("\u{1b}[?1007h".utf8)) // 前の列は捨てて新しい列を読む
        #expect(broken.isEnabled == true)

        let long = String(repeating: "1;", count: 100)
        #expect(tracker(fed: "\u{1b}[?1007h", "\u{1b}[?\(long)h", "ls -la\n").isEnabled == true)
    }

    @Test("普通の画面ではホイールをSwiftTermへ渡す")
    func primaryBufferScrollsBack() {
        #expect(
            TerminalWheelRouting.action(
                isAlternateBuffer: false,
                reportsMouse: false,
                alternateScrollEnabled: false
            ) == .forward
        )
    }

    @Test("alternate screenで1007が立っていなければ握り潰す")
    func alternateScreenWithoutModeSwallows() {
        // tmuxのシェルやclaudeがここに来る。渡せば↑↓が打たれ、履歴が呼び出される。
        #expect(
            TerminalWheelRouting.action(
                isAlternateBuffer: true,
                reportsMouse: false,
                alternateScrollEnabled: false
            ) == .swallow
        )
    }

    @Test("1007を立てたアプリには今まで通り矢印キーを渡す")
    func alternateScrollIsHonoured() {
        #expect(
            TerminalWheelRouting.action(
                isAlternateBuffer: true,
                reportsMouse: false,
                alternateScrollEnabled: true
            ) == .forward
        )
    }

    @Test("マウスを見ているアプリには常に渡す")
    func mouseReportingWins() {
        #expect(
            TerminalWheelRouting.action(
                isAlternateBuffer: true,
                reportsMouse: true,
                alternateScrollEnabled: false
            ) == .forward
        )
    }
}
