import FinderAICore
import Testing

@Suite("セッションを回す鍵の判定")
struct SessionCycleShortcutTests {
    private func match(
        _ characters: String?,
        command: Bool = true,
        option: Bool = true,
        others: Bool = false
    ) -> SessionCycleShortcut? {
        SessionCycleShortcut.match(
            characters: characters,
            hasCommand: command,
            hasOption: option,
            hasOtherModifiers: others
        )
    }

    @Test("⌘⌥→で次、⌘⌥←で前")
    func arrowsPickTheDirection() {
        #expect(match(String(SessionCycleShortcut.rightArrow)) == .next)
        #expect(match(String(SessionCycleShortcut.leftArrow)) == .previous)
        #expect(SessionCycleShortcut.next.offset == 1)
        #expect(SessionCycleShortcut.previous.offset == -1)
    }

    @Test("⌘か⌥が欠けていれば手を出さない")
    func bothModifiersAreRequired() {
        let right = String(SessionCycleShortcut.rightArrow)
        #expect(match(right, command: false) == nil)
        #expect(match(right, option: false) == nil)
        #expect(match(right, command: false, option: false) == nil)
    }

    @Test("他の修飾が混ざっていたら別の意図とみなす")
    func extraModifiersBackOff() {
        // ⌘⌥⇧→ は選択範囲を伸ばす類の操作かもしれない。横から取らない。
        #expect(match(String(SessionCycleShortcut.rightArrow), others: true) == nil)
    }

    @Test("矢印以外は素通しする")
    func otherKeysPassThrough() {
        #expect(match("a") == nil)
        #expect(match("\u{F700}") == nil)  // 上矢印
        #expect(match("\u{F701}") == nil)  // 下矢印
        #expect(match(nil) == nil)
        #expect(match("") == nil)
        // 複数文字が来たら鍵ではない。
        #expect(match("ab") == nil)
    }
}
