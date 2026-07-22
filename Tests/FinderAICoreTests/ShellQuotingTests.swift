import FinderAICore
import Testing

@Suite("Shell quoting for copy-paste into a terminal")
struct ShellQuotingTests {
    @Test("a plain path is wrapped in single quotes")
    func plainPath() {
        #expect(ShellQuoting.quoted("/Users/x/projects") == "'/Users/x/projects'")
    }

    @Test("spaces and shell metacharacters survive inside single quotes")
    func metacharacters() {
        #expect(
            ShellQuoting.quoted("/Users/x/My Folder ($1 & \"stuff\")")
                == "'/Users/x/My Folder ($1 & \"stuff\")'"
        )
    }

    @Test("an embedded single quote is closed, escaped and reopened")
    func singleQuote() {
        #expect(ShellQuoting.quoted("/Users/x/it's here") == "'/Users/x/it'\\''s here'")
    }

    @Test("the cd command is ready to paste")
    func changeDirectory() {
        #expect(
            ShellQuoting.changeDirectoryCommand(forPath: "/Users/x/My Folder")
                == "cd '/Users/x/My Folder'"
        )
    }
}
