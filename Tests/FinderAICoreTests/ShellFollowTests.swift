import FinderAICore
import Testing

@Suite("Follow-cd command construction")
struct ShellFollowTests {
    @Test("the command aborts pending input before cd and ends with return")
    func shape() {
        #expect(
            ShellFollow.command(forPath: "/Users/x/My Folder (L)")
                == "\u{03}cd '/Users/x/My Folder (L)'\n"
        )
    }

    @Test("embedded single quotes stay escaped inside the cd")
    func quoting() {
        #expect(
            ShellFollow.command(forPath: "/x/it's")
                == "\u{03}cd '/x/it'\\''s'\n"
        )
    }
}
