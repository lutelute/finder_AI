import FinderAICore
import Foundation
import Testing

@Suite("Sidebar sections")
struct WorkspaceSidebarModelTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test("sections come out in display order")
    func order() {
        let sections = WorkspaceSidebarModel.sections(
            .init(
                pins: [url("/tmp/pin")],
                favorites: [url("/tmp/fav")],
                volumes: [url("/")],
                frequent: [url("/tmp/freq")],
                recent: [url("/tmp/rec")]
            ),
            home: home
        )
        #expect(sections.map(\.title) == ["ピン留め", "よく使う項目", "場所", "よく使うフォルダ", "最近"])
    }

    @Test("empty sections are omitted rather than shown as headers with nothing under them")
    func emptySectionsDropped() {
        let sections = WorkspaceSidebarModel.sections(
            .init(favorites: [url("/tmp/fav")]),
            home: home
        )
        #expect(sections.map(\.title) == ["よく使う項目"])
    }

    @Test("no input at all yields no sections")
    func nothingAtAll() {
        #expect(WorkspaceSidebarModel.sections(.init(), home: home).isEmpty)
    }

    /// Pinning something that is also a favourite and also frequent should move
    /// it, not clone it into three rows.
    @Test("a folder appears once, in its highest-priority section")
    func noDuplicatesAcrossSections() {
        let shared = url("/tmp/shared")
        let sections = WorkspaceSidebarModel.sections(
            .init(
                pins: [shared],
                favorites: [shared, url("/tmp/fav")],
                volumes: [],
                frequent: [shared],
                recent: [shared, url("/tmp/rec")]
            ),
            home: home
        )

        let allPaths = sections.flatMap { $0.items.map(\.url.path) }
        #expect(allPaths.filter { $0 == shared.path }.count == 1)
        #expect(sections.first(where: { $0.title == "ピン留め" })?.items.map(\.url.path) == [shared.path])
        #expect(sections.first(where: { $0.title == "よく使う項目" })?.items.map(\.url.path) == ["/tmp/fav"])
        // frequent had only the shared folder, so it drops out entirely.
        #expect(!sections.contains { $0.title == "よく使うフォルダ" })
    }

    @Test("different spellings of one folder count as the same folder")
    func normalizesBeforeDeduping() {
        let sections = WorkspaceSidebarModel.sections(
            .init(pins: [url("/tmp/a")], favorites: [url("/tmp/b/../a")]),
            home: home
        )
        #expect(sections.map(\.title) == ["ピン留め"])
    }

    @Test("home shows as the account name and the root as the startup disk")
    func displayNames() {
        let sections = WorkspaceSidebarModel.sections(
            .init(favorites: [home], volumes: [url("/")]),
            home: home
        )
        #expect(sections[0].items[0].title == NSUserName())
        #expect(sections[1].items[0].title == "Macintosh HD")
    }

    @Test("known folders get their own symbol, others fall back to a folder")
    func symbols() {
        let sections = WorkspaceSidebarModel.sections(
            .init(
                pins: [url("/tmp/anything")],
                favorites: [
                    home.appendingPathComponent("Desktop"),
                    home.appendingPathComponent("Downloads"),
                    url("/Applications"),
                    home.appendingPathComponent("Library/CloudStorage/OneDrive/x"),
                    url("/tmp/plain")
                ],
                volumes: [url("/"), url("/Volumes/NAS")]
            ),
            home: home
        )
        let favorites = sections.first { $0.title == "よく使う項目" }?.items.map(\.symbol)
        #expect(sections.first { $0.title == "ピン留め" }?.items.map(\.symbol) == ["pin.fill"])
        #expect(favorites == [
            "desktopcomputer", "arrow.down.circle.fill", "square.grid.3x3.fill",
            "icloud.fill", "folder.fill"
        ])
        // The startup disk and an external volume should not look alike.
        #expect(sections.first { $0.title == "場所" }?.items.map(\.symbol)
            == ["internaldrive.fill", "externaldrive.fill"])
    }

    @Test("the fallback covers the folders a sidebar is useless without")
    func fallback() {
        let fallback = WorkspaceSidebarModel.fallbackFavorites(home: home)
        #expect(fallback.map(\.lastPathComponent) == ["someone", "Desktop", "Documents", "Downloads"])
    }
}
