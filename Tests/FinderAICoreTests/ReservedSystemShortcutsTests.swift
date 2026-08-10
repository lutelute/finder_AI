import FinderAICore
import Testing

@Suite("macOSが押さえている鍵の読み取り")
struct ReservedSystemShortcutsTests {
    private func entry(
        enabled: Bool,
        character: Int,
        keyCode: Int,
        modifiers: Int
    ) -> [String: Any] {
        [
            "enabled": enabled,
            "value": ["parameters": [character, keyCode, modifiers], "type": "standard"]
        ]
    }

    /// これがこの読み取りの要。文字を持つ鍵をkeyCodeで引くと嘘が出る。
    ///
    /// keyCode 33 はJISキーボードでは`@`、ANSIでは`[`。このMacに実際に
    /// 登録されている「次のウインドウを操作対象にする」は⌘@で、
    /// keyCodeを信じると「戻る（⌘[）がOSに押さえられている」という
    /// ありもしない警告が出る——一度出した。
    @Test("文字はparameters[0]から読む。keyCodeで引くとJISで嘘になる")
    func characterWinsOverKeyCode() {
        let shortcuts = ReservedSystemShortcuts.enabled(from: [
            "27": entry(enabled: true, character: 64, keyCode: 33, modifiers: 0x100000)
        ])
        #expect(shortcuts == [SystemShortcut(key: "@", modifiers: SystemShortcut.command)])
        #expect(!shortcuts.contains(SystemShortcut(key: "[", modifiers: SystemShortcut.command)))
    }

    @Test("文字を持たない鍵だけkeyCodeで引く")
    func functionKeysFallBackToKeyCode() {
        let shortcuts = ReservedSystemShortcuts.enabled(from: [
            "32": entry(enabled: true, character: 65535, keyCode: 126, modifiers: 0x40000),
            "79": entry(enabled: true, character: 65535, keyCode: 123, modifiers: 0x40000)
        ])
        #expect(shortcuts.contains(SystemShortcut(key: "↑", modifiers: SystemShortcut.control)))
        #expect(shortcuts.contains(SystemShortcut(key: "←", modifiers: SystemShortcut.control)))
    }

    @Test("切ってある登録は数えない")
    func disabledEntriesAreIgnored() {
        let shortcuts = ReservedSystemShortcuts.enabled(from: [
            "64": entry(enabled: false, character: 32, keyCode: 49, modifiers: 0x100000)
        ])
        #expect(shortcuts.isEmpty)
    }

    /// 読めなかったぶんを衝突として報告すると、直しようのない警告が出続ける。
    @Test("形が違うものは黙って落とす")
    func malformedEntriesAreDropped() {
        let shortcuts = ReservedSystemShortcuts.enabled(from: [
            "1": ["enabled": true],
            "2": ["enabled": true, "value": ["parameters": [1, 2]]],
            "3": ["enabled": true, "value": ["parameters": [65535, 999, 0x100000]]],
            "4": "文字列"
        ])
        #expect(shortcuts.isEmpty)
    }

    @Test("見比べるのは⇧⌃⌥⌘の4つだけ")
    func onlyTheFourModifiersAreCompared() {
        let shortcuts = ReservedSystemShortcuts.enabled(from: [
            "1": entry(enabled: true, character: 100, keyCode: 2, modifiers: 0x140000 | 0x800000)
        ])
        #expect(shortcuts == [
            SystemShortcut(key: "d", modifiers: SystemShortcut.control | SystemShortcut.command)
        ])
    }

    @Test("AppKitのプライベート文字を、システム側と同じ語彙へ揃える")
    func menuKeysAreNormalized() {
        #expect(ReservedSystemShortcuts.normalizedKey("\u{F700}") == "↑")
        #expect(ReservedSystemShortcuts.normalizedKey("\u{F703}") == "→")
        #expect(ReservedSystemShortcuts.normalizedKey("\u{8}") == "Del")
        #expect(ReservedSystemShortcuts.normalizedKey("T") == "t")
        #expect(ReservedSystemShortcuts.normalizedKey("[") == "[")
    }

    @Test("人が読める並びになる")
    func labelReadsLikeAMenu() {
        #expect(SystemShortcut(key: "t", modifiers: SystemShortcut.shift | SystemShortcut.command).label == "⇧⌘T")
        #expect(SystemShortcut(key: "↑", modifiers: SystemShortcut.control).label == "⌃↑")
    }
}
