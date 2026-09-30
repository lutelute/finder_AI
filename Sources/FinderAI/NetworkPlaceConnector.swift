import AppKit
import FinderAICore
import NetFS
import Network

extension Notification.Name {
    /// 登録の増減・改名、接続の始まりと終わり。窓が何枚あってもサイドバーを揃える。
    static let networkPlacesDidChange = Notification.Name("FinderAI.networkPlacesDidChange")
}

/// 登録した共有へ繋ぎ、切る。
///
/// アプリに一つ。マウントはMac全体のもので、窓ごとに「繋いでいる最中」を
/// 持つと、片方の窓で押したものがもう片方では未接続に見える。
///
/// **認証はmacOSに任せる。** NetFSにUIを許すと、Finderの「サーバへ接続」と同じ
/// ダイアログが別プロセスで出て、キーチェーンへの保存もそこで選べる。
/// こちらはパスワードに一度も触らない。
@MainActor
final class NetworkPlaceConnector {
    static let shared = NetworkPlaceConnector()

    /// 繋ぎに行っている最中と、届かなかったもの。マウントが見えればそちらが勝つ
    /// （`NetworkPlaceState.resolve`）ので、成功はここに残さない。
    private var transient: [UUID: NetworkPlaceState] = [:]

    /// 届くかを先に確かめる時間。NetFSに任せると、届かない相手に数十秒黙る。
    /// 押した人には「固まった」としか見えないので、先に短く当たる。
    static let probeTimeout: TimeInterval = 5
    /// ふだんの住所に当たる時間。届かなければTailscaleへ回るので、そのぶん短く。
    /// 研究室のLANは届けば数ミリ秒で返る。
    static let primaryProbeTimeout: TimeInterval = 2.5

    func state(for place: NetworkPlace, mounts: [MountedShare]) -> NetworkPlaceState {
        NetworkPlaceState.resolve(
            mountPoint: NetworkShareMatching.mountPoint(for: place, in: mounts),
            transient: transient[place.id]
        )
    }

    /// 繋いでいる最中・届かなかった、の印だけ（サーバーの行が使う）。
    func transientState(for id: UUID) -> NetworkPlaceState? {
        transient[id]
    }

    /// 繋いだ結果。`tailscaleAddress`は、Tailscaleへ回り込んで繋いだときの住所。
    struct Connection {
        let mountPoint: URL
        let tailscaleAddress: String?
    }

    /// 繋いで、マウント先を返す。取り消されたときと失敗したときはnil。
    /// 失敗の理由は`state(for:)`に残るので、呼んだ側が見せる。
    ///
    /// ふだんの住所に先に当たり、届かなければTailscaleの一覧から同じ名前の機械を
    /// 探してそちらで繋ぐ（NodeDashと同じ順）。研究室にいればLAN、外にいれば
    /// Tailscale、を押す人が選ばなくていい。
    func connect(_ place: NetworkPlace, completion: @escaping @MainActor (Connection?) -> Void) {
        guard let url = place.shareURL else {
            completion(nil)
            return
        }
        if case .connecting? = transient[place.id] { return }
        transient[place.id] = .connecting
        notifyChange()

        Task { @MainActor in
            guard let route = await self.shareRoute(place, url: url) else {
                completion(nil)
                return
            }
            let target = route.url
            let viaTailscale = route.tailscaleAddress
            let result = await Self.mount(target)
            switch result {
            case .mounted(let mountPoint):
                self.finish(place, failure: nil)
                completion(Connection(mountPoint: mountPoint, tailscaleAddress: viaTailscale))
            case .alreadyMounted:
                // 別の経路（Finderなど）で先に繋がっていた。マウント一覧を読み直して
                // そこへ入る。
                self.finish(place, failure: nil)
                var known = place
                known.tailscaleAddress = viaTailscale ?? place.tailscaleAddress
                let mounts = await Task.detached(priority: .userInitiated) {
                    NetworkPlaceConnector.mountedShares()
                }.value
                completion(NetworkShareMatching.mountPoint(for: known, in: mounts).map {
                    Connection(mountPoint: $0, tailscaleAddress: viaTailscale)
                })
            case .cancelled:
                self.finish(place, failure: nil)
                completion(nil)
            case .failed(let message):
                self.finish(place, failure: message)
                completion(nil)
            }
        }
    }

    /// 共有へ繋ぐ経路。ふだんの住所に届けばそのまま、届かなければTailscaleの住所に
    /// 差し替えたURL。どちらも駄目なら理由を残してnil。
    private func shareRoute(_ place: NetworkPlace, url: URL) async -> (url: URL, tailscaleAddress: String?)? {
        let host = url.host ?? ""
        let port = UInt16(url.port ?? Self.defaultPort(for: url.scheme))
        if await Self.probe(host: host, port: port, timeout: Self.primaryProbeTimeout) {
            return (url, nil)
        }
        let route = await Self.tailscaleRoute(names: [host], port: port)
        guard case .reachable(let address) = route,
              let replaced = NetworkPlaceAddress.replacingHost(of: url, with: address) else {
            finish(place, failure: Self.unreachableMessage(host: host, route: route))
            return nil
        }
        return (replaced, address)
    }

    /// サーバーの共有を全部つないで並べたフォルダ。
    struct ServerView {
        let folder: URL
        let tailscaleAddress: String?
        /// つなげなかった共有（権限が無いなど）。
        let skipped: [String]
        /// 読めた共有の一覧。登録に覚えておく。
        let shares: [String]
    }

    /// 共有名なしで登録したサーバーを開く。共有を全部つなぎ、それぞれへのリンクを
    /// 並べたフォルダを返す（Finderでサーバーを開いたときの見え方）。
    ///
    /// 一覧は`smbutil view`で読む。まだ一度も認証していなければ読めないので、
    /// そのときはmacOSの認証画面を一度出す（そこで共有を選ぶ画面も出る）。
    /// 認証が済めば、残りの共有は画面を出さずにつながる。
    func openServer(_ place: NetworkPlace, completion: @escaping @MainActor (ServerView?) -> Void) {
        guard let url = place.shareURL, NetworkShareMatching.shareName(of: url) == nil else {
            completion(nil)
            return
        }
        if case .connecting? = transient[place.id] { return }
        transient[place.id] = .connecting
        notifyChange()

        Task { @MainActor in
            guard let route = await self.shareRoute(place, url: url) else {
                completion(nil)
                return
            }
            let hostURL = route.url
            // 一覧が読めなければ（起動し直した後など、まだ認証していない）、前回
            // 読めた一覧を使う。最初の1つだけ認証画面を許してつなぎ、キーチェーンの
            // 名前とパスワードで入れば、画面は出ない。
            var shares = await Self.listShares(hostURL)
            var needsFirstAuth = false
            if shares == nil, let known = place.knownShares, !known.isEmpty {
                shares = known
                needsFirstAuth = true
            }
            if shares == nil {
                switch await Self.mount(hostURL) {
                case .cancelled:
                    self.finish(place, failure: nil)
                    completion(nil)
                    return
                case .failed(let message):
                    self.finish(place, failure: message)
                    completion(nil)
                    return
                case .mounted, .alreadyMounted:
                    shares = await Self.listShares(hostURL)
                }
            }
            guard let shares, !shares.isEmpty else {
                self.finish(place, failure: "共有の一覧を読めませんでした。名前とパスワードを確かめてください。")
                completion(nil)
                return
            }

            var known = place
            known.tailscaleAddress = route.tailscaleAddress ?? place.tailscaleAddress
            var mounts = await Task.detached(priority: .userInitiated) {
                NetworkPlaceConnector.mountedShares()
            }.value
            var links: [(name: String, target: URL)] = []
            var skipped: [String] = []
            for share in shares {
                guard let shareURL = Self.url(hostURL, share: share),
                      let primaryURL = Self.url(url, share: share) else { continue }
                let probe = NetworkPlace(
                    kind: .share, name: share, address: primaryURL.absoluteString,
                    tailscaleAddress: known.tailscaleAddress
                )
                if let existing = NetworkShareMatching.mountPoint(for: probe, in: mounts) {
                    links.append((share, existing))
                    continue
                }
                // 認証はもう済んでいる（一覧が読めた）。残りの共有は画面を出さずにつなぐ。
                // 画面を許すと、権限の違う共有があるたびに認証画面が重なって出て、
                // 答えるまで先へ進まない。つなげない共有は飛ばして、並べられる分を開く。
                let allowsUI = needsFirstAuth
                needsFirstAuth = false
                switch await Self.mount(shareURL, allowsUI: allowsUI) {
                case .mounted(let mountPoint):
                    links.append((share, mountPoint))
                case .alreadyMounted:
                    mounts = await Task.detached(priority: .userInitiated) {
                        NetworkPlaceConnector.mountedShares()
                    }.value
                    if let existing = NetworkShareMatching.mountPoint(for: probe, in: mounts) {
                        links.append((share, existing))
                    } else {
                        skipped.append(share)
                    }
                case .cancelled:
                    // 認証画面を閉じたなら、残りもつながらない。そこで止める。
                    if allowsUI {
                        self.finish(place, failure: nil)
                        completion(nil)
                        return
                    }
                    skipped.append(share)
                case .failed:
                    skipped.append(share)
                }
            }
            guard !links.isEmpty else {
                self.finish(place, failure: "どの共有にもつなげませんでした。")
                completion(nil)
                return
            }
            let folder = NetworkServerFolder.folder(for: place)
            do {
                try NetworkServerFolder.rebuild(folder, links: links)
            } catch {
                self.finish(place, failure: "共有を並べるフォルダを作れませんでした（\(error.localizedDescription)）。")
                completion(nil)
                return
            }
            self.finish(place, failure: nil)
            completion(ServerView(
                folder: folder,
                tailscaleAddress: route.tailscaleAddress,
                skipped: skipped,
                shares: shares
            ))
        }
    }

    /// `smb://host`に共有名を足す。共有名の空白や日本語は符号化する。
    private static func url(_ host: URL, share: String) -> URL? {
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/" + share
        return components.url
    }

    /// サーバーのディスク共有の名前。まだ認証していなくて読めなければnil。
    nonisolated private static func listShares(_ hostURL: URL) async -> [String]? {
        await Task.detached(priority: .userInitiated) { () -> [String]? in
            guard let host = hostURL.host, TailscaleRoute.isUsableAddress(host) || host.hasSuffix(".local") else {
                return nil
            }
            let user = hostURL.user.map { "\($0)@" } ?? ""
            guard let data = run("/usr/bin/smbutil", ["view", "-N", "//\(user)\(host)"], timeout: 10),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let shares = SMBShareList.diskShares(fromSmbutilView: text)
            return shares.isEmpty ? nil : shares
        }.value
    }

    /// sshで繋ぐ先。ふだんの住所に届けばnil（そのまま）、届かずTailscaleに同じ
    /// 機械が見つかって届けば、その住所。見極めているあいだは行に回る印を出す。
    ///
    /// `~/.ssh/config`の別名は`ssh -G`で実際の繋ぎ先を読んでから当たる。
    /// どちらにも届かなければnilを返して、ふだんの住所のままsshに任せる——
    /// sshが理由を画面に出し、Enterで閉じるまで残る。
    func sshRoute(for place: NetworkPlace, completion: @escaping @MainActor (String?) -> Void) {
        guard place.kind == .server else {
            completion(nil)
            return
        }
        if case .connecting? = transient[place.id] { return }
        transient[place.id] = .connecting
        notifyChange()
        Task { @MainActor in
            let resolved = await Task.detached(priority: .userInitiated) {
                NetworkPlaceConnector.resolveSSH(place.address)
            }.value
            let host = resolved?.host ?? place.address
            let port = UInt16(clamping: resolved?.port ?? 22)
            var override: String?
            if await !Self.probe(host: host, port: port, timeout: Self.primaryProbeTimeout),
               case .reachable(let address) = await Self.tailscaleRoute(names: [place.address, host], port: port) {
                override = address
            }
            self.finish(place, failure: nil)
            completion(override)
        }
    }

    /// 接続を切る。失敗したら理由を返す（使用中など）。
    func disconnect(mountPoint: URL, completion: @escaping @MainActor (String?) -> Void) {
        FileManager.default.unmountVolume(at: mountPoint, options: []) { error in
            let message = error.map { error in
                let nsError = error as NSError
                let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                if nsError.code == Int(EBUSY) || underlying?.code == Int(EBUSY) {
                    return "使用中のため切れません。Terminalやほかのアプリがこの中を開いていないか確かめてください。"
                }
                return nsError.localizedDescription
            }
            Task { @MainActor in
                NetworkPlaceConnector.shared.notifyChange()
                completion(message)
            }
        }
    }

    /// 登録を外したものの「届かない」印は残さない。
    func forget(_ id: UUID) {
        transient.removeValue(forKey: id)
    }

    func notifyChange() {
        NotificationCenter.default.post(name: .networkPlacesDidChange, object: nil)
    }

    private func finish(_ place: NetworkPlace, failure: String?) {
        if let failure {
            transient[place.id] = .unreachable(failure)
        } else {
            transient.removeValue(forKey: place.id)
        }
        notifyChange()
    }

    // MARK: - Tailscale

    private enum TailscaleOutcome {
        case reachable(String)
        case unreachable(String)
        case notFound
    }

    /// Tailscaleの一覧から名前で相手を探す。
    ///
    /// Tailscaleが「繋がっている」と言う相手には当たりに行かず、そのまま使う。
    /// 中継（DERP）越しの最初の1回は応答まで数秒かかることがあり、5秒の探りが
    /// 空振りして「届かない」と言ってしまった（実機、gpu3060。直後は0.8秒で届いた）。
    /// 繋ぐ本番（NetFS・ssh）はその数秒を待てる。
    private static func tailscaleRoute(names: [String], port: UInt16) async -> TailscaleOutcome {
        let peers = await Task.detached(priority: .userInitiated) {
            NetworkPlaceConnector.tailscalePeers()
        }.value
        guard let peer = TailscaleRoute.peer(matching: names, in: peers, includeOffline: true),
              let address = peer.preferredAddress,
              TailscaleRoute.isUsableAddress(address) else { return .notFound }
        return peer.isOnline ? .reachable(address) : .unreachable(address)
    }

    private static func unreachableMessage(host: String, route: TailscaleOutcome) -> String {
        switch route {
        case .unreachable(let address):
            return "\(host) に届かず、Tailscale（\(address)）でも相手が止まっています。相手の電源とTailscaleの接続を確かめてください。"
        case .notFound, .reachable:
            return "\(host) に届きません。Tailscaleにも同じ名前の機械が見つかりませんでした。学外ならVPNか、Tailscaleに入っている名前で登録してください。"
        }
    }

    /// `tailscale status --json`を読む。CLIが無い・止まっているときは空。
    /// **メインスレッドで呼ばない**（別プロセスを待つ）。
    nonisolated static func tailscalePeers() -> [TailscalePeer] {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return [] }
        guard let data = run(path, ["status", "--json"], timeout: 5) else { return [] }
        return TailscaleRoute.peers(fromStatusJSON: data)
    }

    /// `ssh -G`でsshが実際に繋ぐ先を読む。ネットワークには出ない。
    nonisolated static func resolveSSH(_ destination: String) -> (host: String, port: Int)? {
        guard NetworkPlaceAddress.normalizedServer(destination) != nil,
              let data = run("/usr/bin/ssh", ["-G", destination], timeout: 5),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return SSHResolvedConfig.hostAndPort(fromSSHG: text)
    }

    /// 小さな問い合わせのためのプロセス起動。時間内に終わらなければ打ち切る。
    nonisolated private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        // 出力を読みながら待つ。パイプが詰まると相手が書けずに終わらない。
        var data = Data()
        let handle = output.fileHandleForReading
        while process.isRunning, Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02) } else { data.append(chunk) }
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        data.append(handle.readDataToEndOfFile())
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: - マウントの一覧

    /// マウント済みのネットワーク共有。**メインスレッドで呼ばない**——
    /// `mountedVolumeURLs`はネットワークのボリュームを待つ。
    nonisolated static func mountedShares() -> [MountedShare] {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal != true,
                  let remount = values.volumeURLForRemounting,
                  remount.scheme.map({ NetworkPlaceAddress.shareSchemes.contains($0.lowercased()) }) == true
            else { return nil }
            return MountedShare(mountPoint: volume, remountURL: remount)
        }
    }

    // MARK: - 下回り

    private enum MountResult: Sendable {
        case mounted(URL)
        case alreadyMounted
        case cancelled
        case failed(String)
    }

    nonisolated private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "afp": 548
        case "nfs": 2049
        case "ftp": 21
        case "http": 80
        case "https": 443
        default: 445
        }
    }

    /// 相手のポートにTCPで当たってみる。繋がれば届く。
    ///
    /// 断られた（`waiting`）も届かないとみなす——ホストは生きていても、
    /// そのポートで共有が待っていなければマウントは通らない。
    nonisolated private static func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "FinderAI.NetworkPlaceProbe")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let once = ProbeOnce(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed, .waiting, .cancelled: once.finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.finish(false) }
            connection.start(queue: queue)
        }
    }

    /// NetFSで繋ぐ。UIを許すので、パスワードが要れば標準のダイアログが出る。
    nonisolated private static func mount(_ url: URL, allowsUI: Bool = true) async -> MountResult {
        await withCheckedContinuation { continuation in
            // `kNAUIOptionKey`/`kNAUIOptionAllowUI`/`kNAUIOptionNoUI`はCFSTRのマクロで、
            // Swiftへは取り込まれない。中身の文字列を直接書く。
            let openOptions = NSMutableDictionary()
            openOptions["UIOption"] = allowsUI ? "AllowUI" : "NoUI"
            let mountOptions = NSMutableDictionary()
            var requestID: AsyncRequestID?
            // 始める前に断られたときはコールバックが来ない、という約束に頼り切らない。
            // 二度resumeすると落ちるので、先に来たほうだけを通す。
            let once = MountOnce(continuation)
            let status = NetFSMountURLAsync(
                url as CFURL,
                nil,
                nil,
                nil,
                openOptions as CFMutableDictionary,
                mountOptions as CFMutableDictionary,
                &requestID,
                DispatchQueue.global(qos: .userInitiated)
            ) { status, _, mountPoints in
                once.resume(result(status: status, mountPoints: mountPoints))
            }
            if status != 0 {
                once.resume(result(status: status, mountPoints: nil))
            }
        }
    }

    nonisolated private static func result(status: Int32, mountPoints: CFArray?) -> MountResult {
        switch status {
        case 0:
            let paths = (mountPoints as? [String]) ?? []
            guard let first = paths.first else { return .alreadyMounted }
            return .mounted(URL(fileURLWithPath: first, isDirectory: true))
        case EEXIST:
            return .alreadyMounted
        case ECANCELED, -128:
            return .cancelled
        default:
            return .failed(message(for: status))
        }
    }

    nonisolated static func message(for status: Int32) -> String {
        switch status {
        case EAUTH, EACCES, EPERM:
            return "ユーザー名かパスワードが違うか、この共有を開く権限がありません。"
        case ENOENT:
            return "その名前の共有が見つかりません。アドレスの共有名を確かめてください。"
        case ETIMEDOUT:
            return "相手から応答がありません。"
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN:
            return "相手に届きません。ネットワークの接続を確かめてください。"
        case -5998:
            return "開ける共有がありません。"
        case -5045:
            return "パスワードの変更が必要です。Finderの「サーバへ接続」から一度繋いでください。"
        default:
            if status > 0, let text = strerror(status) {
                return "接続できませんでした（\(String(cString: text))）。"
            }
            return "接続できませんでした（エラー \(status)）。"
        }
    }
}

/// マウントの結果を一度だけ返す。コールバックは任意のキューから来る。
private final class MountOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// 探りの決着を一度だけ付ける。状態の通知とタイムアウトが同じキューに乗るので、
/// 決着の旗はそのキューの上でしか触らない。
private final class ProbeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ reachable: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: reachable)
    }
}
