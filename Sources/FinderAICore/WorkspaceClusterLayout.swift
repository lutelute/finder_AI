import CoreGraphics
import Foundation

/// 束を「島」として並べ、複数の束に属するものをその境界に置く配置。
///
/// 一覧は線形なので、二つの束に属するものは二行に割れる。同じ実体が二度並ぶだけで、
/// どこが重なりなのかは行からは読めない。平面ならそれが**位置**で出る — 両方の島に
/// 属する項目は、その境界に立つ。それがこの表示の主題。
///
/// ## 力学をやめた経緯
///
/// はじめはばね・反発・アンカーで解いていた。三度作り直して、そのたびに実機で
/// 別の破綻が出た。
///
/// 1. 全152項目を力学に入れた → 束に属さない116個が29個を包囲し、画面の八割を
///    無関係な点が占めた（「カツかつでえらい見辛い」）。束に属さないものは
///    そもそも受け取らないことにした（`WorkspaceItemGroups.partition`）。
/// 2. 束ごとのアンカーを置いた → 束は固まったが、点が島の端に寄って名前が枠から
///    漏れ、ラベル同士がぶつかって**7項目のうち3つしか名前が出なかった**。
/// 3. 減衰と手数上限で止めた → 止まりはしたが、止まる場所が力の釣り合い次第で、
///    名前が読める配置になる保証がどこにも無かった。
///
/// 地図に求められていたのは「動くこと」ではなく「重なりが場所で分かること」だった。
/// 動きは目的ではなく、配置を決める手段にすぎず、その手段が可読性を保証しない。
/// そこで**島の中は名前順に整列**し、**複数所属だけを境界に置く**決定的な配置にした。
/// 揺れない・必ず名前が出る・同じフォルダなら必ず同じ地図になる。
public struct WorkspaceClusterLayout: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        /// 属している束。ここに来るものは必ず一つ以上持つ。
        public let groups: [String]
        public let position: CGPoint
        /// 名前を置く向き。整列した島の中では点の右、境界では点の下。
        public let labelPlacement: LabelPlacement

        public var isShared: Bool { groups.count > 1 }
    }

    public enum LabelPlacement: Equatable, Sendable {
        case trailing
        case below
    }

    /// 一つの束と、その島の矩形。
    public struct Island: Equatable, Sendable {
        public let name: String
        public let frame: CGRect
        /// 島の中に並べきれなかった数。0でなければ「ほか N」と出す必要がある。
        public let overflow: Int
    }

    public private(set) var nodes: [Node]
    public private(set) var islands: [Island]
    public private(set) var size: CGSize

    /// 複数の束に属するノードの添字。橋を描く相手。
    public private(set) var bridges: [Int]

    private let groupedItems: [WorkspaceItem]
    private let groups: WorkspaceItemGroups?

    /// 島の内側の余白と、束名の帯の高さ。
    public static let islandInset = CGSize(width: 14, height: 12)
    public static let islandTitleHeight: Double = 26
    /// 島の中の一行。点と名前が並ぶ高さ。
    public static let rowHeight: Double = 21

    public init(groupedItems: [WorkspaceItem], groups: WorkspaceItemGroups?, size: CGSize) {
        self.groupedItems = groupedItems
        self.groups = groups
        self.size = size
        (islands, nodes, bridges) = Self.build(items: groupedItems, groups: groups, size: size)
    }

    // MARK: - 割り付け

    private static func build(
        items: [WorkspaceItem],
        groups: WorkspaceItemGroups?,
        size: CGSize
    ) -> ([Island], [Node], [Int]) {
        let names = groups?.adjacencyOrderedNames() ?? []
        guard !names.isEmpty, size.width > 1, size.height > 1 else { return ([], [], []) }

        let frames = islandFrames(count: names.count, in: size)
        let byName = Dictionary(
            zip(names, frames).map { ($0, $1) },
            uniquingKeysWith: { first, _ in first }
        )

        // 島に並べるのは、その島だけに属するもの。複数所属は境界へ回す。
        var exclusive: [String: [WorkspaceItem]] = [:]
        var shared: [WorkspaceItem] = []
        for item in items {
            let belongs = groups?.groupNames(for: item.name) ?? []
            guard !belongs.isEmpty else { continue }
            if belongs.count == 1 {
                exclusive[belongs[0], default: []].append(item)
            } else {
                shared.append(item)
            }
        }

        var built: [Node] = []
        var islands: [Island] = []

        for name in names {
            guard let frame = byName[name] else { continue }
            let members = (exclusive[name] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let (placed, overflow) = place(members, in: frame, groups: [name])
            built.append(contentsOf: placed)
            islands.append(Island(name: name, frame: frame, overflow: overflow))
        }

        // 複数所属は、属する島の中心を結んだ中点に置く。同じ組み合わせが複数あれば、
        // その線に垂直な向きへ等間隔にずらす — 重なると一つにしか見えない。
        let sharedByGroups = Dictionary(grouping: shared) { item in
            (groups?.groupNames(for: item.name) ?? []).sorted().joined(separator: "\u{1F}")
        }
        for key in sharedByGroups.keys.sorted() {
            let members = (sharedByGroups[key] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard let first = members.first else { continue }
            let belongs = groups?.groupNames(for: first.name) ?? []
            let centres = belongs.compactMap { byName[$0] }
                .map { CGPoint(x: $0.midX, y: $0.midY) }
            guard let anchor = centroid(of: centres) else { continue }

            let axis = spreadDirection(across: centres)
            let spacing = 78.0
            let start = -(Double(members.count) - 1) / 2
            for (index, item) in members.enumerated() {
                let offset = (start + Double(index)) * spacing
                built.append(Node(
                    name: item.name,
                    isDirectory: item.isDirectory,
                    groups: groups?.groupNames(for: item.name) ?? [],
                    position: CGPoint(x: anchor.x + axis.dx * offset, y: anchor.y + axis.dy * offset),
                    labelPlacement: .below
                ))
            }
        }

        let bridges = built.indices.filter { built[$0].isShared }
        return (islands, built, bridges)
    }

    /// 島の中に名前順で並べる。入りきらない分は数だけ返す。
    ///
    /// 一列に並べるのは名前を読ませるため。二列にすると一列の幅が半分になり、
    /// `bus_inertia_project_for_SHAKIL` のような名前が切れて、並べた意味が薄れる。
    private static func place(
        _ items: [WorkspaceItem],
        in frame: CGRect,
        groups: [String]
    ) -> ([Node], Int) {
        let usable = frame.insetBy(dx: islandInset.width, dy: islandInset.height)
        // 余白が島より大きいと`insetBy`は`CGRect.null`を返す。null の座標は無限で、
        // そのまま引き算するとNaNになり`Int(_:)`が落ちる（狭い窓で実際に落ちた）。
        guard !usable.isNull, usable.height > 0, usable.width > 0 else {
            return ([], items.count)
        }
        let top = usable.minY + islandTitleHeight
        let height = max(usable.maxY - top, 0)
        guard height.isFinite else { return ([], items.count) }
        let capacity = max(Int(height / rowHeight), 0)
        guard capacity > 0 else { return ([], items.count) }

        // 入りきらないときは、最後の一行を「ほか N」に譲る。
        let shown = items.count <= capacity ? items : Array(items.prefix(max(capacity - 1, 0)))
        let nodes = shown.enumerated().map { index, item in
            Node(
                name: item.name,
                isDirectory: item.isDirectory,
                groups: groups,
                position: CGPoint(
                    x: usable.minX + 8,
                    y: top + rowHeight * (Double(index) + 0.5)
                ),
                labelPlacement: .trailing
            )
        }
        return (nodes, items.count - shown.count)
    }

    /// 領域の縦横比に合わせて枡を割る。1束なら全面。
    public static func gridShape(count: Int, aspect: Double) -> (columns: Int, rows: Int) {
        guard count > 1 else { return (1, 1) }
        let columns = max(1, Int(ceil((Double(count) * max(aspect, 0.2)).squareRoot())))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        return (columns, rows)
    }

    private static func islandFrames(count: Int, in size: CGSize) -> [CGRect] {
        let margin: Double = 14
        let gap: Double = 12
        let area = CGRect(
            x: margin,
            y: margin,
            width: max(size.width - margin * 2, 1),
            height: max(size.height - margin * 2, 1)
        )
        let shape = gridShape(count: count, aspect: area.width / area.height)
        let cellWidth = (area.width - gap * Double(shape.columns - 1)) / Double(shape.columns)
        let cellHeight = (area.height - gap * Double(shape.rows - 1)) / Double(shape.rows)

        return (0..<count).map { index in
            let row = index / shape.columns
            // 蛇行して折り返す。行優先で素直に並べると、行末の束と次の行頭の束が
            // 対角に離れる。共有のある束を隣の番号にしても、それが画面で隣に
            // ならず橋が地図を横断した。
            let raw = index % shape.columns
            let column = row.isMultiple(of: 2) ? raw : shape.columns - 1 - raw
            return CGRect(
                x: area.minX + (cellWidth + gap) * Double(column),
                y: area.minY + (cellHeight + gap) * Double(row),
                width: cellWidth,
                height: cellHeight
            )
        }
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        return CGPoint(
            x: points.reduce(0) { $0 + $1.x } / Double(points.count),
            y: points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }

    /// 島を結ぶ線に垂直な向き。ここへ等間隔にずらすと、境界に沿って並ぶ。
    private static func spreadDirection(across centres: [CGPoint]) -> CGVector {
        guard let first = centres.first, let last = centres.last, centres.count > 1 else {
            return CGVector(dx: 1, dy: 0)
        }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.01 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    // MARK: - 変化

    public mutating func resize(to newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        size = newSize
        // 引き伸ばすのではなく組み直す。決定的なので、同じ大きさなら必ず同じ地図。
        (islands, nodes, bridges) = Self.build(
            items: groupedItems,
            groups: groups,
            size: newSize
        )
    }

    // MARK: - 問い合わせ

    public func island(named name: String) -> Island? {
        islands.first { $0.name == name }
    }

    public func node(named name: String) -> Node? {
        nodes.first { $0.name == name }
    }

    /// その点にあるノード。境界に立つもの（後に置かれるもの）から探す。
    public func node(at point: CGPoint, radius: Double) -> Node? {
        nodes.reversed().first { node in
            let dx = node.position.x - point.x
            let dy = node.position.y - point.y
            return dx * dx + dy * dy <= radius * radius
        }
    }
}
