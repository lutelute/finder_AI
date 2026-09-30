import CryptoKit
import FinderAICore
import Foundation
import Testing

@Suite("tmux session naming")
struct TmuxSessionNamingTests {
    @Test("name is stable for equivalent folder spellings")
    func stableAcrossEquivalentURLs() {
        let plain = TerminalSessionKey(
            directoryURL: URL(fileURLWithPath: "/tmp/プロジェクト A", isDirectory: true),
            kind: .shell
        )
        let trailingSlash = TerminalSessionKey(
            directoryURL: URL(fileURLWithPath: "/tmp/プロジェクト A/", isDirectory: true),
            kind: .shell
        )
        // 再接続は同じ名前を引けることが全てなので、綴り違いで名前が揺れたら壊れる。
        #expect(
            TmuxSessionNaming.sessionName(for: plain)
                == TmuxSessionNaming.sessionName(for: trailingSlash)
        )
    }

    @Test("kind and folder both distinguish the name")
    func distinctPerKindAndFolder() {
        let folderA = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
        let folderB = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
        let names = [
            TmuxSessionNaming.sessionName(for: TerminalSessionKey(directoryURL: folderA, kind: .shell)),
            TmuxSessionNaming.sessionName(for: TerminalSessionKey(directoryURL: folderA, kind: .claude)),
            TmuxSessionNaming.sessionName(for: TerminalSessionKey(directoryURL: folderB, kind: .shell))
        ]
        #expect(Set(names).count == names.count)
    }

    @Test("kind survives the round trip through the session name")
    func kindRoundTrip() {
        let folder = URL(fileURLWithPath: "/tmp/roundtrip", isDirectory: true)
        for kind in TerminalSessionKind.allCases {
            let name = TmuxSessionNaming.sessionName(
                for: TerminalSessionKey(directoryURL: folder, kind: kind)
            )
            #expect(TmuxSessionNaming.kind(fromSessionName: name) == kind)
        }
        #expect(TmuxSessionNaming.kind(fromSessionName: "users-own-session") == nil)
        #expect(TmuxSessionNaming.kind(fromSessionName: "finderai-mystery-abc") == nil)
    }

    @Test("list-sessions lines parse into name, path and attachment")
    func parseListLine() {
        let info = TmuxSessionInfo.parse(line: "finderai-shell-abc\t/tmp/dir with space\t1")
        #expect(info == TmuxSessionInfo(
            name: "finderai-shell-abc",
            workingDirectoryPath: "/tmp/dir with space",
            isAttached: true
        ))
        #expect(TmuxSessionInfo.parse(line: "finderai-shell-abc\t/tmp/x\t0")?.isAttached == false)
        #expect(TmuxSessionInfo.parse(line: "no-tabs-here") == nil)
        #expect(TmuxSessionInfo.parse(line: "") == nil)
    }

    @Test("names avoid characters tmux rejects, regardless of the folder path")
    func tmuxSafeCharacters() {
        let hostile = URL(
            fileURLWithPath: "/tmp/dots.and:colons and spaces",
            isDirectory: true
        )
        let name = TmuxSessionNaming.sessionName(
            for: TerminalSessionKey(directoryURL: hostile, kind: .codex)
        )
        #expect(name.hasPrefix(TmuxSessionNaming.namePrefix))
        #expect(!name.contains("."))
        #expect(!name.contains(":"))
        #expect(!name.contains(" "))
    }
}

@Suite("tmux session naming for ssh")
struct TmuxSSHNamingTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    /// どちらもホームで開くので、宛先を名前に入れないと2台目が1台目のtmuxに
    /// 繋がってしまう。
    @Test("宛先が違えばtmuxの名前も違う")
    func distinctPerTarget() {
        let gpu = TmuxSessionNaming.sessionName(for: .init(directoryURL: home, kind: .ssh, target: "pws-gpu3060"))
        let pgx = TmuxSessionNaming.sessionName(for: .init(directoryURL: home, kind: .ssh, target: "pws-pgx1"))
        #expect(gpu != pgx)
        #expect(TmuxSessionNaming.kind(fromSessionName: gpu) == .ssh)
    }

    /// 宛先の無いセッションの名前が変わると、走っているtmuxに繋ぎ直せなくなる。
    @Test("宛先の無いセッションの名前は以前と同じ")
    func unchangedWithoutTarget() {
        let key = TerminalSessionKey(directoryURL: home, kind: .shell)
        #expect(TmuxSessionNaming.sessionName(for: key) == "finderai-shell-" + expectedHash(for: key.directoryKey))
        #expect(key == TerminalSessionKey(directoryURL: home, kind: .shell, target: nil))
    }

    private func expectedHash(for text: String) -> String {
        // sessionName(for:)が使う形（SHA-256の先頭6バイト）を独立に計算する。
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
