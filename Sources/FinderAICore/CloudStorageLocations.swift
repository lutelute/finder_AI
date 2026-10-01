import Foundation

/// このMacに入っているクラウドの置き場（Google Drive、OneDrive、Dropbox、iCloud Drive）。
///
/// macOSのFile Providerに乗ったクラウドは、どれも`~/Library/CloudStorage/`の下に
/// `<提供元>-<アカウントや組織>`という名前のフォルダとして現れる。マウントも登録も
/// 要らず、そのフォルダへ移れば開ける——だからサイドバーには見つけた分をそのまま出す。
///
/// 読むのは名前だけにする。File Providerの配下で`ubiquitousItem*`のような
/// クラウド系の属性を引くと、提供元のデーモンへの問い合わせになって数十秒止まる
/// ことがある（OneDriveで実測）。フォルダの一覧と「フォルダかどうか」だけなら
/// 手元のファイルシステムで答えが出る。
public enum CloudStorageLocations {
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    public static var defaultICloudDrive: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// フォルダ名ひとつの読み。
    public struct Parsed: Equatable, Sendable {
        /// 「Google Drive」「OneDrive」のような提供元の名前。
        public let provider: String
        /// アカウントや組織（`個人用`、`国立大学法人福井大学`、`lutebass@gmail.com`）。
        public let detail: String?
        /// サイドバーに出す名前。
        public let title: String
        /// 同じ提供元の中で先に並べるもの（OneDriveの個人用）。
        let isPersonal: Bool
    }

    /// `~/Library/CloudStorage`の中のフォルダ名を読む。出さないものはnil。
    ///
    /// - `GoogleDrive-lutebass@gmail.com` → 「Google Drive」（アカウントは同じ提供元が
    ///   2つあるときだけ添える）
    /// - `OneDrive-個人用` → 「OneDrive 個人用」
    /// - `OneDrive-共有ライブラリ-国立大学法人福井大学` → 「OneDrive 国立大学法人福井大学」
    ///   （「共有ライブラリ」は長いだけで見分けの役に立たないので落とす）
    /// - `…-OneDriveCloudTemp` はOneDriveの作業用の置き場で、人が開く場所ではない
    public static func parse(folderName name: String) -> Parsed? {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("CloudTemp") else { return nil }
        let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let rawProvider = String(parts[0])
        guard !rawProvider.isEmpty else { return nil }
        let provider = providerTitle(rawProvider)
        var detail = parts.count > 1 ? String(parts[1]) : nil
        for prefix in ["共有ライブラリ-", "SharedLibraries-", "Shared Libraries-"] {
            if let current = detail, current.hasPrefix(prefix) {
                detail = String(current.dropFirst(prefix.count))
            }
        }
        // `Box-Box`のように提供元の名前を繰り返しているだけのものは添えない。
        if let current = detail, current.isEmpty || current.caseInsensitiveCompare(rawProvider) == .orderedSame {
            detail = nil
        }
        let isPersonal = detail.map { ["個人用", "Personal"].contains($0) } ?? false
        // Google Driveの後ろはアカウントのメールアドレスで、1つしか無ければ要らない。
        let title: String
        if rawProvider == "GoogleDrive" || detail == nil {
            title = provider
        } else {
            title = "\(provider) \(detail!)"
        }
        return Parsed(provider: provider, detail: detail, title: title, isPersonal: isPersonal)
    }

    /// 見つかったクラウドを、サイドバーに並べる順で。
    ///
    /// Google Drive、OneDrive（個人用が先）、そのほかの提供元、最後にiCloud Drive。
    /// 同じ名前になるもの（Google Driveのアカウント違い）は、アカウントを添えて分ける。
    /// **メインスレッドで呼ばない。** クラウドのフォルダに触るので、提供元の機嫌で待つ
    /// ことがある。
    public static func locations(
        root: URL = defaultRoot,
        iCloudDrive: URL = defaultICloudDrive,
        fileManager: FileManager = .default
    ) -> [WorkspaceSidebarModel.Item] {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        var found: [(parsed: Parsed, url: URL)] = names.compactMap { name in
            guard let parsed = parse(folderName: name) else { return nil }
            let url = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return (parsed, url)
        }
        found.sort { lhs, rhs in
            let left = providerRank(lhs.parsed.provider)
            let right = providerRank(rhs.parsed.provider)
            if left != right { return left < right }
            if lhs.parsed.provider != rhs.parsed.provider {
                return lhs.parsed.provider.localizedStandardCompare(rhs.parsed.provider) == .orderedAscending
            }
            if lhs.parsed.isPersonal != rhs.parsed.isPersonal { return lhs.parsed.isPersonal }
            // 名前が同じ（Google Driveのアカウント違い）なら、アカウントで決める。
            // 一覧の順に任せると、開くたびに入れ替わることがある。
            let leftName = lhs.parsed.title + " " + (lhs.parsed.detail ?? "")
            let rightName = rhs.parsed.title + " " + (rhs.parsed.detail ?? "")
            return leftName.localizedStandardCompare(rightName) == .orderedAscending
        }

        let titleCounts = Dictionary(found.map { ($0.parsed.title, 1) }, uniquingKeysWith: +)
        var items = found.map { entry -> WorkspaceSidebarModel.Item in
            var title = entry.parsed.title
            if titleCounts[title, default: 0] > 1, let detail = entry.parsed.detail, !title.contains(detail) {
                title += " \(detail)"
            }
            return WorkspaceSidebarModel.Item(title: title, url: entry.url, symbol: "cloud.fill")
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: iCloudDrive.path, isDirectory: &isDirectory), isDirectory.boolValue {
            items.append(WorkspaceSidebarModel.Item(title: "iCloud Drive", url: iCloudDrive, symbol: "icloud.fill"))
        }
        return items
    }

    /// 提供元が名乗っている綴り。大文字で区切ると`OneDrive`が`One Drive`になる。
    static let knownProviders: [String: String] = [
        "GoogleDrive": "Google Drive",
        "OneDrive": "OneDrive",
        "Dropbox": "Dropbox",
        "Box": "Box",
        "pCloud": "pCloud",
        "iCloudDrive": "iCloud Drive"
    ]

    /// 知らない提供元は大文字の手前で区切る（`SynologyDrive`→`Synology Drive`）。
    static func providerTitle(_ raw: String) -> String {
        if let known = knownProviders[raw] { return known }
        var result = ""
        var previous: Character?
        for character in raw {
            if character.isUppercase, let previous, previous.isLowercase {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func providerRank(_ provider: String) -> Int {
        switch provider {
        case "Google Drive": 0
        case "OneDrive": 1
        default: 2
        }
    }
}
