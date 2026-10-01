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

@Suite("Cloud storage in the sidebar")
struct CloudStorageLocationsTests {
    @Test("フォルダ名を読める名前にする。作業用の置き場とファイルは出さない")
    func parsesFolderNames() {
        func title(_ name: String) -> String? { CloudStorageLocations.parse(folderName: name)?.title }
        #expect(title("GoogleDrive-lutebass@gmail.com") == "Google Drive")
        #expect(title("OneDrive-個人用") == "OneDrive 個人用")
        #expect(title("OneDrive-共有ライブラリ-国立大学法人福井大学") == "OneDrive 国立大学法人福井大学")
        #expect(title("OneDrive-共有ライブラリ-u-fukui.ac.jp") == "OneDrive u-fukui.ac.jp")
        #expect(title("OneDrive-SharedLibraries-Contoso") == "OneDrive Contoso")
        #expect(title("OneDrive-共有ライブラリ-OneDriveCloudTemp") == nil)
        #expect(title("Dropbox") == "Dropbox")
        #expect(title("Box-Box") == "Box")
        #expect(title("SynologyDrive-nas") == "Synology Drive nas")
        #expect(title(".DS_Store") == nil)
    }

    @Test("見つけた分を並べる。Google Drive、OneDrive（個人用が先）、ほか、最後にiCloud Drive")
    func listsLocationsInOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("CloudStorage", isDirectory: true)
        for name in [
            "OneDrive-共有ライブラリ-国立大学法人福井大学",
            "Dropbox",
            "OneDrive-個人用",
            "GoogleDrive-lutebass@gmail.com",
            "OneDrive-共有ライブラリ-OneDriveCloudTemp"
        ] {
            try FileManager.default.createDirectory(
                at: storage.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: storage.appendingPathComponent("fy2025_v3.pdf"))
        let iCloud = root.appendingPathComponent("CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)

        let items = CloudStorageLocations.locations(root: storage, iCloudDrive: iCloud)
        #expect(items.map(\.title) == [
            "Google Drive", "OneDrive 個人用", "OneDrive 国立大学法人福井大学", "Dropbox", "iCloud Drive"
        ])
        #expect(items.last?.symbol == "icloud.fill")
        #expect(items.first?.url.lastPathComponent == "GoogleDrive-lutebass@gmail.com")
    }

    @Test("Google Driveが2つあればアカウントを添えて分ける")
    func disambiguatesAccounts() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        for name in ["GoogleDrive-a@gmail.com", "GoogleDrive-b@u-fukui.ac.jp"] {
            try FileManager.default.createDirectory(
                at: storage.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let items = CloudStorageLocations.locations(
            root: storage, iCloudDrive: storage.appendingPathComponent("none"))
        #expect(items.map(\.title) == ["Google Drive a@gmail.com", "Google Drive b@u-fukui.ac.jp"])
    }

    @Test("クラウドの節はよく使う項目と場所のあいだ。よく使う項目と重なれば一度だけ")
    func sectionPlacement() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let drive = URL(fileURLWithPath: "/Users/someone/Library/CloudStorage/GoogleDrive-a", isDirectory: true)
        let personal = URL(fileURLWithPath: "/Users/someone/Library/CloudStorage/OneDrive-個人用", isDirectory: true)
        let sections = WorkspaceSidebarModel.sections(
            .init(
                favorites: [personal],
                cloud: [
                    .init(title: "Google Drive", url: drive, symbol: "cloud.fill"),
                    .init(title: "OneDrive 個人用", url: personal, symbol: "cloud.fill")
                ],
                volumes: [URL(fileURLWithPath: "/", isDirectory: true)]
            ),
            home: home
        )
        #expect(sections.map(\.title) == ["よく使う項目", "クラウド", "場所"])
        #expect(sections[1].items.map(\.title) == ["Google Drive"])
    }
}
