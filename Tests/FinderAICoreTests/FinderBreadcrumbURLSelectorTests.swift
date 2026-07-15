import CoreGraphics
import Foundation
import Testing
@testable import FinderAICore

@Test func breadcrumbSelectsDeepestFileURL() throws {
    let candidates = [
        FinderBreadcrumbCandidate(
            url: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            frame: CGRect(x: 10, y: 700, width: 70, height: 28)
        ),
        FinderBreadcrumbCandidate(
            url: URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true),
            frame: CGRect(x: 80, y: 700, width: 90, height: 28)
        ),
        FinderBreadcrumbCandidate(
            url: URL(fileURLWithPath: "/Users/example/Documents/project", isDirectory: true),
            frame: CGRect(x: 170, y: 700, width: 80, height: 28)
        )
    ]

    let selected = try #require(FinderBreadcrumbURLSelector.selectCurrent(from: candidates))
    #expect(selected.path == "/Users/example/Documents/project")
}

@Test func breadcrumbUsesRightmostItemOnlyAsDepthTieBreaker() throws {
    let candidates = [
        FinderBreadcrumbCandidate(
            url: URL(fileURLWithPath: "/Volumes/one/folder", isDirectory: true),
            frame: CGRect(x: 10, y: 700, width: 80, height: 28)
        ),
        FinderBreadcrumbCandidate(
            url: URL(fileURLWithPath: "/Volumes/two/folder", isDirectory: true),
            frame: CGRect(x: 90, y: 700, width: 80, height: 28)
        )
    ]

    let selected = try #require(FinderBreadcrumbURLSelector.selectCurrent(from: candidates))
    #expect(selected.path == "/Volumes/two/folder")
}

@Test func breadcrumbRejectsVerticalListsAndNonFileURLs() {
    let vertical = [
        FinderBreadcrumbCandidate(
            url: URL(fileURLWithPath: "/tmp/a", isDirectory: true),
            frame: CGRect(x: 10, y: 10, width: 80, height: 20)
        ),
        FinderBreadcrumbCandidate(
            url: URL(fileURLWithPath: "/tmp/b", isDirectory: true),
            frame: CGRect(x: 10, y: 40, width: 80, height: 20)
        )
    ]
    #expect(FinderBreadcrumbURLSelector.selectCurrent(from: vertical) == nil)

    let web = FinderBreadcrumbCandidate(
        url: URL(string: "https://example.com")!,
        frame: CGRect(x: 10, y: 10, width: 80, height: 20)
    )
    #expect(FinderBreadcrumbURLSelector.selectCurrent(from: [web]) == nil)
}
