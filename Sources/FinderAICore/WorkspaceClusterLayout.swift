import CoreGraphics
import Foundation

/// 束を平面に散らす力学配置。
///
/// 一覧は線形なので、複数の束に属するものを二度並べるしかない。同じ実体が二行に
/// 見えて、どこが重なりなのかは行からは読めない。平面ならそれが**位置**で出る —
/// 二つの束の両方から引かれた項目は、その間で釣り合って止まる。
///
/// 力は四つ。
/// - 近くのノード同士が反発する（重ならないため）
/// - 束を共有するノード同士が引き合う。共有する束が多いほど強い
/// - 束ごとに決めた居場所へ引かれる（束同士が重ならないため）
/// - 中心へ弱く引かれる（画面の外へ流れないため）
///
/// 乱数を使わない。同じフォルダを開き直すたびに配置が変わると、
/// 「前はここにあった」が通じなくなり、地図として読めなくなる。初期配置は
/// 黄金角のらせんで、番号だけから決まる。
public struct WorkspaceClusterLayout: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        /// 属している束。空ならどこにも属さない。
        public let groups: [String]
        public var position: CGPoint
        public var velocity: CGVector

        public var isShared: Bool { groups.count > 1 }
    }

    public private(set) var nodes: [Node]
    public private(set) var size: CGSize

    /// 束を共有するノードの組と、共有している数。重なりが多いほど強く引き合う。
    private let edges: [(a: Int, b: Int, weight: Double)]

    /// 束ごとの居場所。円周上に等間隔で置く。
    ///
    /// バネと反発だけだと、束は固まるものの互いに重なって同じ場所に積もった
    /// （実測: 6束が画面の左三分の一に密集した）。束同士を引き離す力が
    /// どこにも無いため。ここが各束の帰る場所になり、束の間隔を決める。
    private var anchors: [String: CGPoint]
    private let anchorPull: Double = 0.011

    // 実測で決めた値。~/Documents/GitHub（152項目・うち束に属するのは30ほど）で
    // 束が固まって見えるところまで合わせた。
    private let repulsion: Double = 9_000
    /// この距離より遠い相手からは押されない。
    ///
    /// 全対全で反発させると、束に属さない120個が出す押しの合計が束の引力を上回り、
    /// 束が集まる前に画面全体へ広がってしまった（最初の実装がそうなった）。
    /// 遠くを切ると力が局所的になり、束がまとまる余地ができる。
    private let repulsionCutoff: Double = 190
    private let springStiffness: Double = 0.0075
    private let springLength: Double = 62
    private let centering: Double = 0.0016
    /// 束に属さないものへの中心引力の倍率。弱くすると外周へ押し出され、
    /// 中央が束のための場所として空く。
    private let looseCentering: Double = 0.45
    private let damping: Double = 0.86
    private let maxSpeed: Double = 24

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.nodes == rhs.nodes && lhs.size == rhs.size
    }

    public init(items: [WorkspaceItem], groups: WorkspaceItemGroups?, size: CGSize) {
        self.size = size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // 黄金角のらせん: 番号だけで決まり、かつ均等に散る。完全な同心円だと
        // 力が釣り合って初手から動かない配置ができてしまう。
        let goldenAngle = 2.399963229728653
        let spacing = min(size.width, size.height) / (2 * max(sqrt(Double(max(items.count, 1))), 1))

        nodes = items.enumerated().map { index, item in
            let angle = Double(index) * goldenAngle
            let radius = spacing * sqrt(Double(index))
            return Node(
                name: item.name,
                isDirectory: item.isDirectory,
                groups: groups?.groupNames(for: item.name) ?? [],
                position: CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
                ),
                velocity: .zero
            )
        }

        let names = groups?.groups.map(\.name) ?? []
        var placed: [String: CGPoint] = [:]
        if names.count == 1 {
            placed[names[0]] = center
        } else {
            let ring = min(size.width, size.height) * 0.30
            for (index, name) in names.enumerated() {
                // 上から時計回り。定義順で場所が決まるので、束を並べ替えない限り
                // 地図の上での位置も動かない。
                let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(names.count)
                placed[name] = CGPoint(
                    x: center.x + ring * cos(angle),
                    y: center.y + ring * sin(angle)
                )
            }
        }
        anchors = placed

        var shared: [Int: Double] = [:]
        let count = nodes.count
        for (index, node) in nodes.enumerated() where !node.groups.isEmpty {
            let mine = Set(node.groups)
            for other in (index + 1)..<count {
                let overlap = mine.intersection(nodes[other].groups).count
                guard overlap > 0 else { continue }
                shared[index * count + other] = Double(overlap)
            }
        }
        edges = shared.map { (a: $0.key / count, b: $0.key % count, weight: $0.value) }
            .sorted { ($0.a, $0.b) < ($1.a, $1.b) }
    }

    /// 一手進める。呼ぶたびに少しずつ落ち着く。
    public mutating func step() {
        guard nodes.count > 1 else { return }
        var forces = [CGVector](repeating: .zero, count: nodes.count)

        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                // 完全に重なった二点は力の向きが決まらない。番号で決まるずれを
                // 与えて必ず離れるようにする（乱数を使わないのはここでも同じ理由）。
                let distanceSquared = max(dx * dx + dy * dy, 0.01)
                guard distanceSquared < repulsionCutoff * repulsionCutoff else { continue }
                let distance = sqrt(distanceSquared)
                // 束に属さないもの同士は、弱くしか押し合わない。同じ強さで押し合うと
                // 等間隔で釣り合って格子に結晶化し、地図というより方眼紙になる。
                // 束との間の反発はそのままなので、束の周りは空いたままになる。
                let bothLoose = nodes[i].groups.isEmpty && nodes[j].groups.isEmpty
                let magnitude = repulsion * (bothLoose ? 0.22 : 1) / distanceSquared
                let ux = distance > 0.1 ? dx / distance : Double(i - j)
                let uy = distance > 0.1 ? dy / distance : 1
                forces[i].dx += ux * magnitude
                forces[i].dy += uy * magnitude
                forces[j].dx -= ux * magnitude
                forces[j].dy -= uy * magnitude
            }
        }

        for edge in edges {
            let dx = nodes[edge.b].position.x - nodes[edge.a].position.x
            let dy = nodes[edge.b].position.y - nodes[edge.a].position.y
            let distance = max(sqrt(dx * dx + dy * dy), 0.01)
            let magnitude = springStiffness * edge.weight * (distance - springLength)
            let ux = dx / distance
            let uy = dy / distance
            forces[edge.a].dx += ux * magnitude
            forces[edge.a].dy += uy * magnitude
            forces[edge.b].dx -= ux * magnitude
            forces[edge.b].dy -= uy * magnitude
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for i in 0..<nodes.count {
            let pull = nodes[i].groups.isEmpty ? centering * looseCentering : centering
            forces[i].dx += (center.x - nodes[i].position.x) * pull
            forces[i].dy += (center.y - nodes[i].position.y) * pull

            // 属する束の居場所の平均へ。二つの束に属するものは両方の中間を
            // 目指すので、重なりはそのまま「間」に落ち着く。
            let homes = nodes[i].groups.compactMap { anchors[$0] }
            if !homes.isEmpty {
                let home = homes.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + $1.x / Double(homes.count), y: $0.y + $1.y / Double(homes.count))
                }
                forces[i].dx += (home.x - nodes[i].position.x) * anchorPull
                forces[i].dy += (home.y - nodes[i].position.y) * anchorPull
            }

            var velocity = CGVector(
                dx: (nodes[i].velocity.dx + forces[i].dx) * damping,
                dy: (nodes[i].velocity.dy + forces[i].dy) * damping
            )
            let speed = sqrt(velocity.dx * velocity.dx + velocity.dy * velocity.dy)
            if speed > maxSpeed {
                velocity.dx *= maxSpeed / speed
                velocity.dy *= maxSpeed / speed
            }
            nodes[i].velocity = velocity
            nodes[i].position.x += velocity.dx
            nodes[i].position.y += velocity.dy
        }

        clampToBounds()
    }

    /// 端で止める。画面の外に出たものは、ユーザーから見れば消えたのと同じ。
    private mutating func clampToBounds() {
        let margin: Double = 26
        for i in 0..<nodes.count {
            if nodes[i].position.x < margin {
                nodes[i].position.x = margin
                nodes[i].velocity.dx = 0
            } else if nodes[i].position.x > size.width - margin {
                nodes[i].position.x = size.width - margin
                nodes[i].velocity.dx = 0
            }
            if nodes[i].position.y < margin {
                nodes[i].position.y = margin
                nodes[i].velocity.dy = 0
            } else if nodes[i].position.y > size.height - margin {
                nodes[i].position.y = size.height - margin
                nodes[i].velocity.dy = 0
            }
        }
    }

    /// もう動きが目に見えないところまで来たか。描き直しを止める判断に使う。
    public var isSettled: Bool {
        nodes.allSatisfy { abs($0.velocity.dx) < 0.12 && abs($0.velocity.dy) < 0.12 }
    }

    public mutating func resize(to newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0, size.width > 0, size.height > 0 else { return }
        let scaleX = newSize.width / size.width
        let scaleY = newSize.height / size.height
        for i in 0..<nodes.count {
            nodes[i].position.x *= scaleX
            nodes[i].position.y *= scaleY
        }
        // 束の居場所も一緒に伸ばす。ここを据え置くと、窓を広げたとたんに
        // 全部が元の大きさの位置へ引き戻されて縮む。
        for (name, point) in anchors {
            anchors[name] = CGPoint(x: point.x * scaleX, y: point.y * scaleY)
        }
        size = newSize
        clampToBounds()
    }

    /// 束の重心。見出しをどこに書くかを決めるのに使う。
    public func centroid(of group: String) -> CGPoint? {
        let members = nodes.filter { $0.groups.contains(group) }
        guard !members.isEmpty else { return nil }
        let sum = members.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y)
        }
        return CGPoint(x: sum.x / Double(members.count), y: sum.y / Double(members.count))
    }

    public func node(named name: String) -> Node? {
        nodes.first { $0.name == name }
    }

    /// その点にあるノード。手前にあるもの（後に描かれるもの）から探す。
    public func node(at point: CGPoint, radius: Double) -> Node? {
        nodes.reversed().first { node in
            let dx = node.position.x - point.x
            let dy = node.position.y - point.y
            return dx * dx + dy * dy <= radius * radius
        }
    }
}
