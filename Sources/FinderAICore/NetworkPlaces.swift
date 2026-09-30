import Foundation

/// サイドバーに登録したネットワークの場所ひとつ。
///
/// 二種類ある。**共有**はNASなどのファイル共有（`smb://host/share`）で、押すと
/// マウントしてその中へ入る。**サーバー**はSSHで入る先（`ubuntu@host`）で、押すと
/// 下のTerminalで`ssh`が始まる。どちらも「アドレスを覚えずに押して入る」ための
/// 登録で、パスワードは持たない——共有はmacOSの認証ダイアログとキーチェーンに、
/// サーバーはsshの鍵と`~/.ssh/config`に任せる。
public struct NetworkPlace: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case share
        case server
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    /// 共有は正規化したURLの文字列、サーバーはsshへそのまま渡す宛先。
    public var address: String
    /// ふだんの住所に届かずTailscaleで繋いだとき、使ったTailscaleの住所。
    /// マウントの戻り先がこの住所になるので、突き合わせに要る。無かった頃の登録も
    /// 読めるよう省略可能。
    public var tailscaleAddress: String?

    public init(id: UUID = UUID(), kind: Kind, name: String, address: String, tailscaleAddress: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.address = address
        self.tailscaleAddress = tailscaleAddress
    }

    /// Tailscaleの住所に差し替えた共有のURL。
    public var tailscaleShareURL: URL? {
        guard let url = shareURL, let tailscaleAddress else { return nil }
        return NetworkPlaceAddress.replacingHost(of: url, with: tailscaleAddress)
    }

    /// 共有のURL。サーバーや壊れた値ではnil。
    public var shareURL: URL? {
        guard kind == .share else { return nil }
        return URL(string: address)
    }
}

/// 登録の並び。並びは登録した順で、ピン留めと同じく利用者のもの。
public struct NetworkPlaces: Equatable, Sendable {
    public private(set) var all: [NetworkPlace]

    /// サイドバーを飲み込まない程度に。研究室のNAS3台とサーバー6台で足りる数の倍。
    public static let capacity = 30

    public init(_ places: [NetworkPlace] = []) {
        var accepted: [NetworkPlace] = []
        for place in places where !accepted.contains(where: { Self.sameTarget($0, place) }) {
            accepted.append(place)
        }
        all = Array(accepted.prefix(Self.capacity))
    }

    public var shares: [NetworkPlace] { all.filter { $0.kind == .share } }
    public var servers: [NetworkPlace] { all.filter { $0.kind == .server } }
    public var isFull: Bool { all.count >= Self.capacity }

    public func place(id: UUID) -> NetworkPlace? {
        all.first { $0.id == id }
    }

    /// 同じ宛先がもう登録されていれば、それを返す。
    public func existing(matching place: NetworkPlace) -> NetworkPlace? {
        all.first { Self.sameTarget($0, place) }
    }

    /// 断ったときはfalse: 同じ宛先が登録済み、または満杯。
    @discardableResult
    public mutating func add(_ place: NetworkPlace) -> Bool {
        guard existing(matching: place) == nil, !isFull else { return false }
        all.append(place)
        return true
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        all.remove(at: index)
        return true
    }

    /// Tailscaleで繋いだ住所を覚える。同じなら何もしない。
    @discardableResult
    public mutating func setTailscaleAddress(id: UUID, to address: String?) -> Bool {
        guard let index = all.firstIndex(where: { $0.id == id }),
              all[index].tailscaleAddress != address else { return false }
        all[index].tailscaleAddress = address
        return true
    }

    /// 空の名前は受けない。サイドバーに名前の無い行が出るよりは、何もしないほうがいい。
    @discardableResult
    public mutating func rename(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = all.firstIndex(where: { $0.id == id }) else { return false }
        all[index].name = trimmed
        return true
    }

    /// 大文字小文字と`smb`/`cifs`の違いは同じ宛先として扱う。
    private static func sameTarget(_ lhs: NetworkPlace, _ rhs: NetworkPlace) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        switch lhs.kind {
        case .share:
            guard let left = lhs.shareURL, let right = rhs.shareURL else {
                return lhs.address == rhs.address
            }
            return NetworkShareMatching.sameShare(left, right)
        case .server:
            return lhs.address.lowercased() == rhs.address.lowercased()
        }
    }
}

/// 打ち込まれたアドレスを登録できる形に直す。
///
/// 手で打つものなので、Finderの「サーバへ接続」で通る書き方はここでも通す:
/// スキーム無しの`host/share`はSMBとみなし、Windows流の`\\host\share`も受ける。
public enum NetworkPlaceAddress {
    /// NetFSが扱えるスキーム。`cifs`は古いSMBの呼び名。
    public static let shareSchemes: Set<String> = ["smb", "cifs", "afp", "nfs", "ftp", "http", "https"]

    /// 共有のアドレスを正規化する。読めなければnil。
    ///
    /// **パスワードは落とす。** `smb://user:pass@host`と打たれても、設定ファイルに
    /// 平文で残さない。ユーザー名は残す——認証ダイアログの初期値になる。
    public static func normalizedShare(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("\\\\") {
            raw = "smb://" + raw.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        if !raw.contains("://") {
            raw = "smb://" + raw
        }
        guard var components = URLComponents(string: raw)
            ?? URLComponents(string: raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = components.scheme?.lowercased(),
              shareSchemes.contains(scheme),
              let host = components.host, !host.isEmpty,
              !host.contains(where: \.isWhitespace) else { return nil }
        components.scheme = scheme
        components.password = nil
        components.query = nil
        components.fragment = nil
        // 末尾の`/`は共有名の一部ではない。`smb://host/share/`と`smb://host/share`を
        // 別物として二重に登録させない。
        while components.percentEncodedPath.count > 1, components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath == "/" { components.percentEncodedPath = "" }
        return components.url
    }

    /// サーバーの宛先を確かめる。`user@host`、`host`、`ssh://user@host:2222`、
    /// `~/.ssh/config`の別名をそのまま受ける。
    ///
    /// 空白と制御文字は断る。`-`で始まるものも断る——sshのオプションとして
    /// 読まれ、宛先ではなく指示になってしまうため。
    public static func normalizedServer(_ text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              !raw.hasPrefix("-"),
              !raw.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        if raw.contains("://") {
            guard let components = URLComponents(string: raw),
                  components.scheme?.lowercased() == "ssh",
                  let host = components.host, !host.isEmpty else { return nil }
        }
        return raw
    }

    /// 登録シートに最初から入れておく名前。
    ///
    /// ホスト名の頭（`pws-nas03.local`なら`pws-nas03`）に共有名を添える。
    /// IPアドレスは頭だけでは`10`になって意味を失うので、丸ごと使う。
    public static func suggestedName(forShare url: URL) -> String {
        let host = hostLabel(url.host ?? "")
        guard let share = NetworkShareMatching.shareName(of: url) else { return host }
        return host.isEmpty ? share : "\(host) \(share)"
    }

    public static func suggestedName(forServer destination: String) -> String {
        var host = destination
        if let components = URLComponents(string: destination),
           components.scheme != nil, let parsed = components.host {
            host = parsed
        } else if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        return hostLabel(host)
    }

    /// サイドバーの見出しの横に出す短い説明（`smb://pws-nas03.local/share`→
    /// `pws-nas03.local/share`）。スキームは種類が決まっているので要らない。
    public static func displayAddress(for place: NetworkPlace) -> String {
        guard place.kind == .share, let url = place.shareURL else { return place.address }
        let host = url.host ?? ""
        guard let share = NetworkShareMatching.shareName(of: url) else { return host }
        return "\(host)/\(share)"
    }

    /// URLのホストだけを差し替える（`smb://pws-nas03.local/share`→`smb://100.102.148.23/share`）。
    public static func replacingHost(of url: URL, with host: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = host
        return components.url
    }

    static func hostLabel(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isIPAddress(trimmed) { return trimmed }
        return trimmed.split(separator: ".").first.map(String.init) ?? trimmed
    }

    public static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}

/// マウント済みのボリュームひとつ。`remountURL`は`volumeURLForRemountingKey`で、
/// ネットワーク共有にだけ付く（`smb://user@host/share`）。
public struct MountedShare: Equatable, Sendable {
    public let mountPoint: URL
    public let remountURL: URL

    public init(mountPoint: URL, remountURL: URL) {
        self.mountPoint = mountPoint.standardizedFileURL
        self.remountURL = remountURL
    }
}

/// 登録した共有と、いまマウントされているボリュームを突き合わせる。
///
/// ネットワークには触らない。名前を引けば`pws-nas03.local`と`10.0.70.189`が
/// 同じだと分かるが、それは待ちを生む。サイドバーを描くたびに走るので、
/// 書き方の揺れ（大文字小文字、`.local`の有無、Bonjourのサービス名）だけを吸収する。
public enum NetworkShareMatching {
    /// `smb://host/share/sub`の`share`。共有を指さないURLではnil。
    public static func shareName(of url: URL) -> String? {
        let components = url.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
        return components.first.map(String.init)
    }

    /// 同じ共有を指しているか。共有名を持たない登録（`smb://host`）は、その
    /// ホストのどの共有とも一致する——登録したのはホストで、どの共有を開くかは
    /// 接続のときに選ぶから。
    public static func matches(registered: URL, mounted: URL) -> Bool {
        guard sameScheme(registered, mounted),
              sameHost(registered.host ?? "", mounted.host ?? "") else { return false }
        guard let share = shareName(of: registered) else { return true }
        guard let mountedShare = shareName(of: mounted) else { return false }
        return share.caseInsensitiveCompare(mountedShare) == .orderedSame
    }

    /// 二重登録を防ぐための比較。こちらは共有名の有無も区別する。
    static func sameShare(_ lhs: URL, _ rhs: URL) -> Bool {
        guard sameScheme(lhs, rhs), sameHost(lhs.host ?? "", rhs.host ?? "") else { return false }
        switch (shareName(of: lhs), shareName(of: rhs)) {
        case (nil, nil): return true
        case let (left?, right?): return left.caseInsensitiveCompare(right) == .orderedSame
        default: return false
        }
    }

    /// 登録したものがマウントされていれば、そのマウント先。Tailscaleで繋いだ
    /// もの（戻り先がTailscaleの住所）も同じ登録として拾う。
    public static func mountPoint(for place: NetworkPlace, in mounts: [MountedShare]) -> URL? {
        let candidates = [place.shareURL, place.tailscaleShareURL].compactMap { $0 }
        return mounts.first { mount in
            candidates.contains { matches(registered: $0, mounted: mount.remountURL) }
        }?.mountPoint
    }

    /// そのマウントがTailscaleの住所で繋がっているか。
    public static func isViaTailscale(_ place: NetworkPlace, mountPoint: URL, in mounts: [MountedShare]) -> Bool {
        guard let tailscale = place.tailscaleShareURL,
              let mount = mounts.first(where: { $0.mountPoint.path == mountPoint.path }) else { return false }
        return matches(registered: tailscale, mounted: mount.remountURL)
    }

    private static func sameScheme(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalScheme(lhs.scheme) == canonicalScheme(rhs.scheme)
    }

    private static func canonicalScheme(_ scheme: String?) -> String {
        let lowered = scheme?.lowercased() ?? ""
        return lowered == "cifs" ? "smb" : lowered
    }

    static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        let left = canonicalHost(lhs)
        return !left.isEmpty && left == canonicalHost(rhs)
    }

    /// `pws-nas03._smb._tcp.local`（Finderのネットワーク欄から繋ぐとこうなる）も
    /// `PWS-NAS03.local.`も`pws-nas03`に揃える。
    public static func canonicalHost(_ host: String) -> String {
        var value = (host.removingPercentEncoding ?? host).lowercased()
        if let service = value.range(of: "._") {
            value = String(value[..<service.lowerBound])
        }
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasSuffix(".local") { value.removeLast(".local".count) }
        return value
    }
}

/// 押した共有がいまどうなっているか。
public enum NetworkPlaceState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(URL)
    /// 届かなかった。理由は人が読む一文。
    case unreachable(String)

    /// マウントが見えていればそれが勝つ。押して失敗した後でFinderから
    /// 繋がることもあるし、繋ぎに行っている間に他の窓で繋がることもある。
    public static func resolve(mountPoint: URL?, transient: NetworkPlaceState?) -> NetworkPlaceState {
        if let mountPoint { return .connected(mountPoint) }
        switch transient {
        case .connecting?: return .connecting
        case .unreachable(let reason)?: return .unreachable(reason)
        case .connected?, .disconnected?, nil: return .disconnected
        }
    }
}

/// Finderの「サーバへ接続」に登録された「よく使うサーバ」。
///
/// `com.apple.LSSharedFileList.FavoriteServers.sfl4`に入っている。
/// `FinderFavorites`と同じくAppleの非公開形式なので、`$objects`からURLらしい
/// 文字列を拾うだけにして、形が変わっても何も出ないだけで済むようにする。
public enum FinderFavoriteServers {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(
                "Library/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.FavoriteServers.sfl4",
                isDirectory: false
            )
    }

    /// 登録順。共有として読めないもの（`vnc://`など）は落とす。
    public static func addresses(at url: URL? = nil) -> [URL] {
        guard let data = try? Data(contentsOf: url ?? defaultURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return [] }

        var seen = Set<String>()
        return objects.compactMap { object in
            guard let text = object as? String,
                  text.contains("://"),
                  let url = NetworkPlaceAddress.normalizedShare(text),
                  seen.insert(url.absoluteString.lowercased()).inserted else { return nil }
            return url
        }
    }
}

/// `~/.ssh/config`の`Host`に書いた別名。サーバーを登録するときの候補に出す。
///
/// 別名で登録しておけば、ユーザー名・鍵・踏み台は`~/.ssh/config`のまま効く。
/// ワイルドカードの行（`Host *`）は宛先ではないので落とす。gitの置き場も、
/// 入ってシェルを使う相手ではないので落とす。
public enum SSHConfigHosts {
    static let codeHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".ssh/config", isDirectory: false)
    }

    public static func aliases(at url: URL? = nil) -> [String] {
        guard let text = try? String(contentsOf: url ?? defaultURL, encoding: .utf8) else { return [] }
        return aliases(in: text)
    }

    public static func aliases(in text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            // `Host=a b`も`Host a b`も書ける。
            let words = line
                .replacingOccurrences(of: "=", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard words.count >= 2, words[0].lowercased() == "host" else { continue }
            for pattern in words.dropFirst() {
                let name = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !name.isEmpty,
                      !name.contains(where: { "*?!".contains($0) }),
                      !codeHosts.contains(name.lowercased()),
                      seen.insert(name.lowercased()).inserted else { continue }
                result.append(name)
            }
        }
        return result
    }
}
