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
            let host = url.host ?? ""
            let port = UInt16(url.port ?? Self.defaultPort(for: url.scheme))
            var target = url
            var viaTailscale: String?
            if await !Self.probe(host: host, port: port, timeout: Self.primaryProbeTimeout) {
                let route = await Self.tailscaleRoute(names: [host], port: port)
                guard case .reachable(let address) = route,
                      let replaced = NetworkPlaceAddress.replacingHost(of: url, with: address) else {
                    self.finish(place, failure: Self.unreachableMessage(host: host, route: route))
                    completion(nil)
                    return
                }
                target = replaced
                viaTailscale = address
            }
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
    nonisolated private static func mount(_ url: URL) async -> MountResult {
        await withCheckedContinuation { continuation in
            // `kNAUIOptionKey`/`kNAUIOptionAllowUI`はCFSTRのマクロで、Swiftへは
            // 取り込まれない。中身の文字列を直接書く。
            let openOptions = NSMutableDictionary()
            openOptions["UIOption"] = "AllowUI"
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
