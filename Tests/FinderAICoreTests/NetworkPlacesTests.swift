import FinderAICore
import Foundation
import Testing

@Suite("Network places")
struct NetworkPlacesTests {
    private func share(_ text: String) -> URL? { NetworkPlaceAddress.normalizedShare(text) }

    @Test("打ち込んだ共有のアドレスはFinderの⌘Kで通る書き方をすべて受ける")
    func normalizesShareAddresses() {
        #expect(share("smb://pws-nas03.local/share")?.absoluteString == "smb://pws-nas03.local/share")
        #expect(share("  pws-nas03.local/share  ")?.absoluteString == "smb://pws-nas03.local/share")
        #expect(share(#"\\10.0.70.169\disk1"#)?.absoluteString == "smb://10.0.70.169/disk1")
        #expect(share("SMB://NAS/Share/")?.absoluteString == "smb://NAS/Share")
        #expect(share("smb://pws-nas03.local/")?.absoluteString == "smb://pws-nas03.local")
        #expect(share("afp://old-mac.local/Public")?.scheme == "afp")
    }

    @Test("パスワードは設定ファイルに残さない。ユーザー名は残す")
    func dropsPasswords() {
        let url = share("smb://pwslab:secret@100.121.140.79/share")
        #expect(url?.absoluteString == "smb://pwslab@100.121.140.79/share")
        #expect(url?.password == nil)
    }

    @Test("共有として読めないものは断る")
    func rejectsNonShares() {
        #expect(share("") == nil)
        #expect(share("   ") == nil)
        #expect(share("vnc://host") == nil)
        #expect(share("ssh://ubuntu@host") == nil)
        #expect(share("smb://") == nil)
    }

    @Test("sshの宛先はそのまま通す。オプションに読まれるものと空白入りは断る")
    func validatesServers() {
        #expect(NetworkPlaceAddress.normalizedServer(" ubuntu@100.117.16.18 ") == "ubuntu@100.117.16.18")
        #expect(NetworkPlaceAddress.normalizedServer("pws-gpu") == "pws-gpu")
        #expect(NetworkPlaceAddress.normalizedServer("ssh://lute@100.116.168.15:22") == "ssh://lute@100.116.168.15:22")
        #expect(NetworkPlaceAddress.normalizedServer("-oProxyCommand=evil") == nil)
        #expect(NetworkPlaceAddress.normalizedServer("ubuntu@host rm") == nil)
        #expect(NetworkPlaceAddress.normalizedServer("http://host") == nil)
        #expect(NetworkPlaceAddress.normalizedServer("") == nil)
    }

    @Test("名前の初期値はホスト名の頭に共有名。IPアドレスは丸ごと")
    func suggestsNames() throws {
        #expect(NetworkPlaceAddress.suggestedName(forShare: try #require(share("smb://pws-nas03.local"))) == "pws-nas03")
        #expect(NetworkPlaceAddress.suggestedName(forShare: try #require(share("smb://pws-nas04.local/share"))) == "pws-nas04 share")
        #expect(NetworkPlaceAddress.suggestedName(forShare: try #require(share("smb://10.0.70.169/disk1"))) == "10.0.70.169 disk1")
        #expect(NetworkPlaceAddress.suggestedName(forServer: "ubuntu@100.117.16.18") == "100.117.16.18")
        #expect(NetworkPlaceAddress.suggestedName(forServer: "lute@pws-pgx1.fuee.u-fukui.ac.jp") == "pws-pgx1")
        #expect(NetworkPlaceAddress.suggestedName(forServer: "ssh://lute@pws-pgx1:22") == "pws-pgx1")
        #expect(NetworkPlaceAddress.suggestedName(forServer: "pws-gpu") == "pws-gpu")
    }

    @Test("マウント済みとの突き合わせは書き方の揺れを吸収する")
    func matchesMountedVolumes() throws {
        let registered = try #require(share("smb://pws-nas03.local/share"))
        let bonjour = try #require(URL(string: "smb://pwslab@pws-nas03._smb._tcp.local/share"))
        let upper = try #require(URL(string: "smb://PWS-NAS03.local./Share"))
        let bare = try #require(URL(string: "cifs://pws-nas03/share"))
        let otherShare = try #require(URL(string: "smb://pws-nas03.local/backup"))
        let otherHost = try #require(URL(string: "smb://pws-nas04.local/share"))
        let afp = try #require(URL(string: "afp://pws-nas03.local/share"))

        #expect(NetworkShareMatching.matches(registered: registered, mounted: bonjour))
        #expect(NetworkShareMatching.matches(registered: registered, mounted: upper))
        #expect(NetworkShareMatching.matches(registered: registered, mounted: bare))
        #expect(!NetworkShareMatching.matches(registered: registered, mounted: otherShare))
        #expect(!NetworkShareMatching.matches(registered: registered, mounted: otherHost))
        #expect(!NetworkShareMatching.matches(registered: registered, mounted: afp))
    }

    @Test("共有名の無い登録は、そのホストのどの共有とも一致する")
    func hostOnlyRegistrationMatchesAnyShare() throws {
        let host = try #require(share("smb://pws-nas03.local"))
        let mounted = try #require(URL(string: "smb://pwslab@pws-nas03.local/backup"))
        #expect(NetworkShareMatching.matches(registered: host, mounted: mounted))
    }

    @Test("日本語の共有名もマウントと一致する")
    func matchesNonASCIIShareNames() throws {
        let registered = try #require(share("smb://nas-c.fuee.u-fukui.ac.jp/共有"))
        let mounted = try #require(URL(string: "smb://staff@nas-c.fuee.u-fukui.ac.jp/%E5%85%B1%E6%9C%89"))
        #expect(NetworkShareMatching.matches(registered: registered, mounted: mounted))
    }

    @Test("マウント先を引ける。無ければnil")
    func findsMountPoint() throws {
        let place = NetworkPlace(kind: .share, name: "nas04", address: "smb://100.121.140.79/share")
        let mounts = [
            MountedShare(
                mountPoint: URL(fileURLWithPath: "/Volumes/other", isDirectory: true),
                remountURL: try #require(URL(string: "smb://10.0.70.169/disk1"))
            ),
            MountedShare(
                mountPoint: URL(fileURLWithPath: "/Volumes/share", isDirectory: true),
                remountURL: try #require(URL(string: "smb://pwslab@100.121.140.79/share"))
            )
        ]
        #expect(NetworkShareMatching.mountPoint(for: place, in: mounts)?.path == "/Volumes/share")
        #expect(NetworkShareMatching.mountPoint(for: place, in: []) == nil)
        let server = NetworkPlace(kind: .server, name: "gpu", address: "ubuntu@100.121.140.79")
        #expect(NetworkShareMatching.mountPoint(for: server, in: mounts) == nil)
    }

    @Test("同じ宛先は二度登録しない。種類が違えば別物")
    func refusesDuplicates() {
        var places = NetworkPlaces()
        do { let accepted = places.add(NetworkPlace(kind: .share, name: "a", address: "smb://nas/share")); #expect(accepted) }
        do { let accepted = places.add(NetworkPlace(kind: .share, name: "b", address: "smb://NAS/Share")); #expect(!accepted) }
        do { let accepted = places.add(NetworkPlace(kind: .share, name: "c", address: "cifs://nas/share")); #expect(!accepted) }
        do { let accepted = places.add(NetworkPlace(kind: .share, name: "d", address: "smb://nas")); #expect(accepted) }
        do { let accepted = places.add(NetworkPlace(kind: .server, name: "e", address: "ubuntu@nas")); #expect(accepted) }
        do { let accepted = places.add(NetworkPlace(kind: .server, name: "f", address: "UBUNTU@nas")); #expect(!accepted) }
        #expect(places.shares.map(\.name) == ["a", "d"])
        #expect(places.servers.map(\.name) == ["e"])
    }

    @Test("満杯なら断る")
    func refusesBeyondCapacity() {
        var places = NetworkPlaces()
        for index in 0..<NetworkPlaces.capacity {
            do { let accepted = places.add(NetworkPlace(kind: .server, name: "\(index)", address: "host\(index)")); #expect(accepted) }
        }
        #expect(places.isFull)
        do { let accepted = places.add(NetworkPlace(kind: .server, name: "x", address: "extra")); #expect(!accepted) }
    }

    @Test("名前の変更と登録の解除。空の名前は受けない")
    func renamesAndRemoves() {
        let place = NetworkPlace(kind: .share, name: "nas03", address: "smb://pws-nas03.local")
        var places = NetworkPlaces([place])
        do { let accepted = places.rename(id: place.id, to: "  研究室NAS  "); #expect(accepted) }
        #expect(places.place(id: place.id)?.name == "研究室NAS")
        do { let accepted = places.rename(id: place.id, to: "   "); #expect(!accepted) }
        #expect(places.place(id: place.id)?.name == "研究室NAS")
        do { let accepted = places.remove(id: place.id); #expect(accepted) }
        #expect(places.all.isEmpty)
        do { let accepted = places.remove(id: place.id); #expect(!accepted) }
    }

    @Test("保存した並びを読み直すと、重複と上限超過は落ちる")
    func initializerCleansStoredValues() {
        let a = NetworkPlace(kind: .share, name: "a", address: "smb://nas/share")
        let dup = NetworkPlace(kind: .share, name: "dup", address: "smb://nas/share")
        let places = NetworkPlaces([a, dup])
        #expect(places.all == [a])
    }

    @Test("状態はマウントが見えていればそれが勝つ")
    func stateResolution() {
        let mount = URL(fileURLWithPath: "/Volumes/share", isDirectory: true)
        #expect(NetworkPlaceState.resolve(mountPoint: mount, transient: .connecting) == .connected(mount))
        #expect(NetworkPlaceState.resolve(mountPoint: mount, transient: .unreachable("x")) == .connected(mount))
        #expect(NetworkPlaceState.resolve(mountPoint: nil, transient: .connecting) == .connecting)
        #expect(NetworkPlaceState.resolve(mountPoint: nil, transient: .unreachable("届きません")) == .unreachable("届きません"))
        #expect(NetworkPlaceState.resolve(mountPoint: nil, transient: nil) == .disconnected)
    }

    @Test("Finderのよく使うサーバを読む。読めない形は何も返さない")
    func readsFinderFavoriteServers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("FavoriteServers.sfl4")
        let plist: [String: Any] = [
            "$objects": [
                "$null",
                "smb://100.104.225.55/nasc-staff",
                "com.apple.LSSharedFileList.OverrideIcon.OSType",
                "smb://nas-c.fuee.u-fukui.ac.jp/staff",
                "vnc://screen.local",
                "SMB://100.104.225.55/nasc-staff/",
                Data("book".utf8)
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: file)

        #expect(FinderFavoriteServers.addresses(at: file).map(\.absoluteString) == [
            "smb://100.104.225.55/nasc-staff",
            "smb://nas-c.fuee.u-fukui.ac.jp/staff"
        ])
        #expect(FinderFavoriteServers.addresses(at: directory.appendingPathComponent("missing")).isEmpty)
    }
}

@Suite("ssh config hosts")
struct SSHConfigHostsTests {
    @Test("Hostの別名を拾う。ワイルドカードとgitの置き場は落とす")
    func parsesAliases() {
        let text = """
        # 研究室
        Host github.com
            IdentityFile ~/.ssh/id_ed25519
        Host pws-160core
            HostName 100.104.225.55
        host pws-gpu3060 gpu3060   # 別名2つ
        Host=pws-pgx1
        Host *
            ServerAliveInterval 30
        Host *.local !skip
        Host pws-160core
        """
        #expect(SSHConfigHosts.aliases(in: text) == ["pws-160core", "pws-gpu3060", "gpu3060", "pws-pgx1"])
    }

    @Test("ファイルが無ければ何も出さない")
    func missingFile() {
        #expect(SSHConfigHosts.aliases(at: URL(fileURLWithPath: "/nonexistent/ssh_config")).isEmpty)
    }
}

@Suite("Tailscale fallback")
struct TailscaleRouteTests {
    private let status = Data(#"""
    {
      "Self": {"HostName": "macbook-pro"},
      "Peer": {
        "a": {"HostName": "pws-nas03", "DNSName": "pws-nas03.taile5b55a.ts.net.",
              "TailscaleIPs": ["100.102.148.23", "fd7a:115c:a1e0::c439:9417"], "Online": true},
        "b": {"HostName": "pws-gpu3060", "DNSName": "pws-gpu3060.taile5b55a.ts.net.",
              "TailscaleIPs": ["100.117.16.18"], "Online": true},
        "c": {"HostName": "DESKTOP-5MB0GO4", "DNSName": "desktop-5mb0go4.taile5b55a.ts.net.",
              "TailscaleIPs": ["100.77.235.82"], "Online": false},
        "d": {"HostName": "funnel-ingress-node", "TailscaleIPs": ["fd7a:115c:a1e0::a801:26ab"], "Online": true}
      }
    }
    """#.utf8)

    @Test("tailscale status --json から相手を読む")
    func parsesPeers() {
        let peers = TailscaleRoute.peers(fromStatusJSON: status)
        #expect(peers.count == 4)
        let nas = peers.first { $0.hostName == "pws-nas03" }
        #expect(nas?.preferredAddress == "100.102.148.23")
        #expect(nas?.isOnline == true)
        #expect(TailscaleRoute.peers(fromStatusJSON: Data("not json".utf8)).isEmpty)
    }

    @Test("ふだんの住所の名前（.local、sshの別名、user@host）から同じ機械を探す")
    func matchesByName() {
        let peers = TailscaleRoute.peers(fromStatusJSON: status)
        #expect(TailscaleRoute.peer(matching: ["pws-nas03.local"], in: peers)?.preferredAddress == "100.102.148.23")
        #expect(TailscaleRoute.peer(matching: ["PWS-NAS03._smb._tcp.local"], in: peers)?.hostName == "pws-nas03")
        #expect(TailscaleRoute.peer(matching: ["pws-gpu3060", "10.0.70.81"], in: peers)?.preferredAddress == "100.117.16.18")
        #expect(TailscaleRoute.peer(matching: ["ubuntu@pws-gpu3060"], in: peers)?.hostName == "pws-gpu3060")
        #expect(TailscaleRoute.peer(matching: ["smb://pws-nas03.local/share"], in: peers)?.hostName == "pws-nas03")
    }

    /// IPアドレスは名前ではないので探せない。止まっている相手には回らない。
    @Test("IPだけの登録と、止まっている相手には回らない")
    func refusesIPsAndOfflinePeers() {
        let peers = TailscaleRoute.peers(fromStatusJSON: status)
        #expect(TailscaleRoute.peer(matching: ["10.0.70.189"], in: peers) == nil)
        #expect(TailscaleRoute.peer(matching: ["desktop-5mb0go4"], in: peers) == nil)
        #expect(TailscaleRoute.peer(matching: ["pws-nas04.local"], in: peers) == nil)
    }

    @Test("住所として差し込んでよい形か")
    func usableAddress() {
        #expect(TailscaleRoute.isUsableAddress("100.102.148.23"))
        #expect(TailscaleRoute.isUsableAddress("fd7a:115c:a1e0::c439:9417"))
        #expect(TailscaleRoute.isUsableAddress("pws-nas03.taile5b55a.ts.net"))
        #expect(!TailscaleRoute.isUsableAddress("-oProxyCommand=x"))
        #expect(!TailscaleRoute.isUsableAddress("1.2.3.4; rm"))
        #expect(!TailscaleRoute.isUsableAddress(""))
    }

    @Test("ssh -G の出力から実際の繋ぎ先を読む")
    func readsSSHG() {
        let output = "user ubuntu\nhostname 10.0.70.81\nport 2222\nidentityfile ~/.ssh/id_ed25519\n"
        let resolved = SSHResolvedConfig.hostAndPort(fromSSHG: output)
        #expect(resolved?.host == "10.0.70.81")
        #expect(resolved?.port == 2222)
        #expect(SSHResolvedConfig.hostAndPort(fromSSHG: "hostname pws-pgx1\n")?.port == 22)
        #expect(SSHResolvedConfig.hostAndPort(fromSSHG: "") == nil)
    }

    /// Tailscaleで繋ぐと、マウントの戻り先はTailscaleの住所になる。それも同じ登録。
    @Test("Tailscaleで繋いだマウントも、登録と突き合わせられる")
    func matchesMountsMadeViaTailscale() throws {
        let place = NetworkPlace(
            kind: .share, name: "nas03", address: "smb://pws-nas03.local/share",
            tailscaleAddress: "100.102.148.23"
        )
        let mounts = [MountedShare(
            mountPoint: URL(fileURLWithPath: "/Volumes/share", isDirectory: true),
            remountURL: try #require(URL(string: "smb://pwslab@100.102.148.23/share"))
        )]
        #expect(place.tailscaleShareURL?.absoluteString == "smb://100.102.148.23/share")
        let mountPoint = try #require(NetworkShareMatching.mountPoint(for: place, in: mounts))
        #expect(NetworkShareMatching.isViaTailscale(place, mountPoint: mountPoint, in: mounts))

        var unknown = place
        unknown.tailscaleAddress = nil
        #expect(NetworkShareMatching.mountPoint(for: unknown, in: mounts) == nil)
    }

    @Test("Tailscaleの住所を覚える。同じなら変えない。古い登録も読める")
    func remembersTailscaleAddress() throws {
        let place = NetworkPlace(kind: .share, name: "nas03", address: "smb://pws-nas03.local")
        var places = NetworkPlaces([place])
        do { let changed = places.setTailscaleAddress(id: place.id, to: "100.102.148.23"); #expect(changed) }
        do { let changed = places.setTailscaleAddress(id: place.id, to: "100.102.148.23"); #expect(!changed) }
        #expect(places.place(id: place.id)?.tailscaleAddress == "100.102.148.23")

        let old = Data(#"[{"id":"A5140812-4FBA-4B67-96C0-9A7E6B0C4CCA","kind":"share","address":"smb://pws-nas03.local","name":"pws-nas03"}]"#.utf8)
        let decoded = try JSONDecoder().decode([NetworkPlace].self, from: old)
        #expect(decoded.first?.tailscaleAddress == nil)
        #expect(decoded.first?.name == "pws-nas03")
    }
}

@Suite("Tailscale fallback — stopped peers")
struct TailscaleOfflinePeerTests {
    @Test("止まっている相手は、言い分けるときだけ見つける")
    func offlineOnlyWhenAsked() {
        let peers = [TailscalePeer(hostName: "pws-gpu", dnsName: "", addresses: ["100.1.2.3"], isOnline: false)]
        #expect(TailscaleRoute.peer(matching: ["pws-gpu"], in: peers) == nil)
        #expect(TailscaleRoute.peer(matching: ["pws-gpu"], in: peers, includeOffline: true)?.hostName == "pws-gpu")
    }
}
