import Foundation
@testable import FinderAIApp
import Testing

@Suite("Terminal drawer folder linking")
struct TerminalDrawerLinkTests {
    @Test("following Finder changes the Terminal tab context")
    func followsFinder() {
        let first = URL(fileURLWithPath: "/tmp/project-a", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/project-b", isDirectory: true)
        var link = TerminalDrawerLink()

        link.setFinderDirectory(first)
        #expect(link.mode == .followsFinder)
        #expect(link.terminalDirectoryURL == first.standardizedFileURL)

        link.setFinderDirectory(second)
        #expect(link.terminalDirectoryURL == second.standardizedFileURL)
    }

    @Test("a fixed Terminal stays mounted while Finder navigates")
    func fixedTerminalSurvivesNavigation() {
        let terminalFolder = URL(fileURLWithPath: "/tmp/terminal-project", isDirectory: true)
        let browsedFolder = URL(fileURLWithPath: "/tmp/other-folder", isDirectory: true)
        var link = TerminalDrawerLink()

        link.setFinderDirectory(terminalFolder)
        link.fixTerminalDirectory(terminalFolder)
        link.setFinderDirectory(browsedFolder)

        #expect(link.mode == .fixed)
        #expect(link.finderDirectoryURL == browsedFolder.standardizedFileURL)
        #expect(link.terminalDirectoryURL == terminalFolder.standardizedFileURL)
    }

    @Test("returning to follow mode immediately uses the current Finder folder")
    func resumesFollowingCurrentFinderFolder() {
        let terminalFolder = URL(fileURLWithPath: "/tmp/terminal-project", isDirectory: true)
        let browsedFolder = URL(fileURLWithPath: "/tmp/new-location", isDirectory: true)
        var link = TerminalDrawerLink()
        link.setFinderDirectory(terminalFolder)
        link.fixTerminalDirectory(terminalFolder)
        link.setFinderDirectory(browsedFolder)

        link.followFinder()

        #expect(link.mode == .followsFinder)
        #expect(link.fixedDirectoryURL == nil)
        #expect(link.terminalDirectoryURL == browsedFolder.standardizedFileURL)
    }
}
