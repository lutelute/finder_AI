import Foundation

/// Tailscaleに参加している相手ひとつ（`tailscale status --json`の`Peer`）。
public struct TailscalePeer: Equatable, Sendable {
    public let hostName: String
    /// MagicDNSの名前（`pws-nas03.taile5b55a.ts.net.`）。
    public let dnsName: String
    public let addresses: [String]
    public let isOnline: Bool

    public init(hostName: String, dnsName: String, addresses: [String], isOnline: Bool) {
        self.hostName = hostName
        self.dnsName = dnsName
        self.addresses = addresses
        self.isOnline = isOnline
    }

    /// 繋ぐときに使う住所。IPv4を優先する——名前（MagicDNS）はDNSの設定しだいで
    /// 引けないことがあり、IPv6は経路が無い環境がある。
    public var preferredAddress: String? {
        addresses.first { !$0.contains(":") } ?? addresses.first
    }
}

/// 研究室のLANに届かないとき、Tailscaleで同じ相手に回り込む。
///
/// NodeDashと同じ考え方で、ふだんの住所（`pws-nas03.local`、`10.0.70.81`）が
/// 届かなければ、Tailscaleの一覧から同じ機械を**名前で**探して、そのTailscaleの
/// 住所で繋ぐ。住所を二重に登録させない——Tailscaleの一覧が機械の名前を持っている。
///
/// 名前で照合するので、IPアドレスだけで登録した相手は探せない（Tailscaleの一覧は
/// 相手のLANのIPを出さない）。そういう相手は`~/.ssh/config`の別名や、`.local`の
/// 名前で登録してもらう。
public enum TailscaleRoute {
    /// `tailscale status --json`を読む。読めなければ空。
    public static func peers(fromStatusJSON data: Data) -> [TailscalePeer] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = root["Peer"] as? [String: Any] else { return [] }
        return peers.values.compactMap { value in
            guard let peer = value as? [String: Any],
                  let hostName = peer["HostName"] as? String else { return nil }
            return TailscalePeer(
                hostName: hostName,
                dnsName: peer["DNSName"] as? String ?? "",
                addresses: peer["TailscaleIPs"] as? [String] ?? [],
                isOnline: peer["Online"] as? Bool ?? false
            )
        }
        .sorted { $0.hostName < $1.hostName }
    }

    /// 名前の候補（ホスト名、sshの別名）のどれかに一致する相手。既定では繋がって
    /// いる相手だけ。`includeOffline`は「見つかったが止まっている」を言い分けるため。
    public static func peer(
        matching names: [String],
        in peers: [TailscalePeer],
        includeOffline: Bool = false
    ) -> TailscalePeer? {
        let wanted = Set(names.compactMap(label(of:)))
        guard !wanted.isEmpty else { return nil }
        return peers.first { peer in
            guard includeOffline || peer.isOnline, peer.preferredAddress != nil else { return false }
            let own = [label(of: peer.hostName), label(of: peer.dnsName)].compactMap { $0 }
            return own.contains(where: wanted.contains)
        }
    }

    /// 照合に使う名前の頭。`pws-nas03.local`も`PWS-NAS03`も`pws-nas03._smb._tcp.local`も
    /// `pws-nas03`に揃える。IPアドレスは名前ではないのでnil。
    public static func label(of host: String) -> String? {
        var value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if let components = URLComponents(string: value), components.scheme != nil, let parsed = components.host {
            value = parsed
        }
        guard !value.isEmpty, !NetworkPlaceAddress.isIPAddress(value) else { return nil }
        let canonical = NetworkShareMatching.canonicalHost(value)
        return canonical.split(separator: ".").first.map(String.init)
    }

    /// Tailscaleの住所として`ssh -o HostName=`やURLへ入れてよい形か。
    public static func isUsableAddress(_ address: String) -> Bool {
        !address.isEmpty && !address.hasPrefix("-")
            && address.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || ".:-".unicodeScalars.contains($0)
            }
    }
}

/// `ssh -G <宛先>`の出力から、実際に繋ぐ先（ホスト名とポート）を読む。
///
/// `~/.ssh/config`の別名は、読まないとどこへ繋ぐのか分からない。`-G`は設定を
/// 解決して表示するだけで、ネットワークには出ない。
public enum SSHResolvedConfig {
    public static func hostAndPort(fromSSHG output: String) -> (host: String, port: Int)? {
        var host: String?
        var port = 22
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname": host = String(parts[1])
            case "port": port = Int(parts[1]) ?? 22
            default: break
            }
        }
        return host.map { ($0, port) }
    }
}
