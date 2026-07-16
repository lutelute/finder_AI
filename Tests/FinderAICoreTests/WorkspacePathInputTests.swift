import FinderAICore
import Foundation
import Testing

/// Every form here is something that actually arrives from a copied path, a
/// terminal, or the Finder.
@Suite("Typed and pasted paths")
struct WorkspacePathInputTests {
    private let home = "/Users/someone"
    private func parse(_ s: String) -> URL? { WorkspacePathInput.parse(s, home: home) }

    @Test("a plain absolute path")
    func absolute() {
        #expect(parse("/usr/local/bin")?.path == "/usr/local/bin")
    }

    @Test("tilde expands, alone or with a path")
    func tilde() {
        #expect(parse("~")?.path == home)
        #expect(parse("~/Documents")?.path == "\(home)/Documents")
    }

    @Test("a file:// URL becomes a path")
    func fileURL() {
        #expect(parse("file:///usr/bin")?.path == "/usr/bin")
        // Percent-encoded spaces have to survive the trip.
        #expect(parse("file:///tmp/a%20b")?.path == "/tmp/a b")
    }

    @Test("quotes and whitespace from a copied path are stripped")
    func wrapping() {
        #expect(parse("  /usr/bin  ")?.path == "/usr/bin")
        #expect(parse("\"/usr/bin\"")?.path == "/usr/bin")
        #expect(parse("'/tmp/a b'")?.path == "/tmp/a b")
    }

    @Test("a trailing slash and dot segments are normalised")
    func normalisation() {
        #expect(parse("/usr/bin/")?.path == "/usr/bin")
        #expect(parse("/usr/local/../bin")?.path == "/usr/bin")
    }

    @Test("nothing to act on yields nil")
    func empty() {
        #expect(parse("") == nil)
        #expect(parse("   ") == nil)
        #expect(parse("\"\"") == nil)
    }

    /// Resolving one against the process's working directory would land
    /// somewhere meaningless, so a bare name is refused rather than guessed at.
    @Test("a relative path is refused, not guessed")
    func relativeIsRefused() {
        #expect(parse("Documents") == nil)
        #expect(parse("./Documents") == nil)
        #expect(parse("../up") == nil)
    }

    @Test("spaces and non-ASCII survive")
    func awkwardNames() {
        #expect(parse("/tmp/書類 と 空白")?.path == "/tmp/書類 と 空白")
        #expect(parse("~/書籍(L)/001")?.path == "\(home)/書籍(L)/001")
    }

    @Test("a path that looks like shell syntax stays a path")
    func hostileInput() {
        // Nothing here reaches a shell; it is just an unusual folder name.
        #expect(parse("/tmp/$(rm -rf *)")?.path == "/tmp/$(rm -rf *)")
    }

    /// A Japanese IME left on turns "~" into "〜" and "/" into "／" — observed
    /// live as "〜/Documents／GitHub". Refusing that makes the path bar unusable
    /// for anyone typing with the IME active.
    @Test("full-width separators from the IME are folded")
    func imeInput() {
        #expect(parse("〜/Documents／GitHub")?.path == "\(home)/Documents/GitHub")
        #expect(parse("～/Documents")?.path == "\(home)/Documents")
        #expect(parse("／Users／someone")?.path == "/Users/someone")
    }

    /// The fold must not eat these characters where they are part of a name.
    @Test("a tilde inside a folder name survives")
    func tildeInNames() {
        #expect(parse("/tmp/2025～2026年度")?.path == "/tmp/2025～2026年度")
        #expect(parse("/tmp/a〜b")?.path == "/tmp/a〜b")
        // Full-width spaces occur in names and never in separators.
        #expect(parse("/tmp/書類　控え")?.path == "/tmp/書類　控え")
    }
}
