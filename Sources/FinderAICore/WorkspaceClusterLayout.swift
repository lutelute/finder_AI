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
        /// クリックを受ける範囲。
        ///
        /// 点だけを的にすると半径10ptを狙わせることになる。島の中は行として
        /// 並んでいるので、**行ぜんぶ**を的にする — 名前をクリックしても
        /// 選べるし、一覧の行をクリックするのと同じ感覚になる。
        public let hitRect: CGRect

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
        /// 定義にあるのに実物が無い数。フォルダを消したり別の場所へ動かすと増える。
        public let missing: Int
    }

    public private(set) var nodes: [Node]
    public private(set) var islands: [Island]
    public private(set) var size: CGSize

    /// 複数の束に属するノードの添字。橋を描く相手。
    public private(set) var bridges: [Int]

    /// 「新しい束」の枠。ここに落とせば束を作れる。
    ///
    /// 束が一つも無いフォルダでは、これが唯一の入口になる（枡いっぱいに出る）。
    /// 束があるときは最後の枡を空けて置く — 地図の上で作れないと、右クリックの
    /// メニューを知っている人しか束を作れない。
    public private(set) var newGroupSlot: CGRect?

    private let groupedItems: [WorkspaceItem]
    private let groups: WorkspaceItemGroups?
    private let presentNames: Set<String>?

    /// 島の内側の余白と、束名の帯の高さ。
    public static let islandInset = CGSize(width: 14, height: 12)
    public static let islandTitleHeight: Double = 23
    /// 島の中の一行。点と名前が並ぶ高さ。
    ///
    /// 21ptだと、幅を優先して2列3行に割ったときに6行しか入らず、7項目の束から
    /// 2つが「ほか」に落ちた。18ptなら7行入る。11ptの文字には詰まった値だが、
    /// 名前が読めないのと見えないのとでは、見えないほうが困る。
    public static let rowHeight: Double = 18

    /// - Parameter presentNames: このフォルダに実在する名前。**隠しファイルも含める**。
    ///   省略すると`groupedItems`の名前を使うが、それだと隠し表示をオフにしただけで
    ///   隠しフォルダが「見つからない」に化ける。
    public init(
        groupedItems: [WorkspaceItem],
        groups: WorkspaceItemGroups?,
        size: CGSize,
        presentNames: Set<String>? = nil
    ) {
        self.groupedItems = groupedItems
        self.groups = groups
        self.presentNames = presentNames
        self.size = size
        (islands, nodes, bridges, newGroupSlot) = Self.build(
            items: groupedItems,
            groups: groups,
            size: size,
            presentNames: presentNames
        )
    }

    // MARK: - 割り付け

    private static func build(
        items: [WorkspaceItem],
        groups: WorkspaceItemGroups?,
        size: CGSize,
        presentNames: Set<String>?
    ) -> ([Island], [Node], [Int], CGRect?) {
        let names = groups?.adjacencyOrderedNames() ?? []
        guard size.width > 1, size.height > 1 else { return ([], [], [], nil) }

        // 「新しい束」は下端の帯に置く。
        //
        // 枡を一つ多く割って最後を充てていたが、6束のときに枡が3×2から3×3になり、
        // 島の高さが三分の二に縮んで7項目のうち2つが「ほか」に落ちた。新しい束を
        // 置ける代わりに既にある束が読めなくなるのは筋が悪い。帯なら島は縮まない。
        let margin: Double = 14
        let slotHeight: Double = 44
        let slotGap: Double = 12
        let newGroupSlot = CGRect(
            x: margin,
            y: size.height - margin - slotHeight,
            width: max(size.width - margin * 2, 1),
            height: slotHeight
        )

        // 束が一つも無ければ、帯ではなく全面を入口にする。ここしか入口がない。
        guard !names.isEmpty else {
            return ([], [], [], CGRect(
                x: margin,
                y: margin,
                width: max(size.width - margin * 2, 1),
                height: max(size.height - margin * 2, 1)
            ))
        }

        let frames = islandFrames(
            count: names.count,
            in: CGSize(width: size.width, height: max(size.height - slotHeight - slotGap, 1))
        )
        let byName = Dictionary(
            zip(names, frames).map { ($0, $1) },
            uniquingKeysWith: { first, _ in first }
        )

        // 定義にあるのに実物が無いものを数える。呼び出し側は束に属するものだけを
        // 渡してくるので、ここで数えられるのは「束の定義に居るが実物が無い」名前。
        let missingByGroup = groups?.missingMembers(
            amongNames: presentNames ?? Set(items.map(\.name))
        ) ?? [:]

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
        /// 島ごとの、並べた行の下端。境界に立つ点をここより下に置く。
        var rowsBottom: [String: Double] = [:]

        for name in names {
            guard let frame = byName[name] else { continue }
            let members = (exclusive[name] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let (placed, overflow) = place(members, in: frame, groups: [name])
            rowsBottom[name] = (placed.map { $0.position.y }.max() ?? frame.minY) + rowHeight / 2
            built.append(contentsOf: placed)
            islands.append(Island(
                name: name,
                frame: frame,
                overflow: overflow,
                missing: missingByGroup[name]?.count ?? 0
            ))
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
            guard var anchor = centroid(of: centres) else { continue }

            // 島の中の行より下に置く。中点そのままだと島の中身の上に乗って、
            // 点も名前もどちらも読めなくなった（実機でそうなった）。
            // 「境界に立つ」という意味は横位置が担うので、縦にずらしても崩れない。
            let below = belongs.compactMap { rowsBottom[$0] }.max()
            let ceiling = belongs.compactMap { byName[$0]?.maxY }.min()
            if let below, let ceiling, below + 22 < ceiling - 8 {
                anchor.y = max(anchor.y, below + 22)
            }

            let axis = spreadDirection(across: centres)
            let spacing = 78.0
            let start = -(Double(members.count) - 1) / 2
            for (index, item) in members.enumerated() {
                let offset = (start + Double(index)) * spacing
                let raw = CGPoint(x: anchor.x + axis.dx * offset, y: anchor.y + axis.dy * offset)
                let placed = pushedOutOfForeignIslands(raw, belongingTo: Set(belongs), islands: byName)
                built.append(Node(
                    name: item.name,
                    isDirectory: item.isDirectory,
                    groups: groups?.groupNames(for: item.name) ?? [],
                    position: placed,
                    labelPlacement: .below,
                    // 境界に立つものは行に属さないので、点のまわりを的にする。
                    hitRect: CGRect(x: placed.x - 17, y: placed.y - 17, width: 34, height: 34)
                ))
            }
        }

        let bridges = built.indices.filter { built[$0].isShared }
        return (islands, built, bridges, newGroupSlot)
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
            let centreY = top + rowHeight * (Double(index) + 0.5)
            return Node(
                name: item.name,
                isDirectory: item.isDirectory,
                groups: groups,
                position: CGPoint(x: usable.minX + 8, y: centreY),
                labelPlacement: .trailing,
                hitRect: CGRect(
                    x: usable.minX,
                    y: centreY - rowHeight / 2,
                    width: usable.width,
                    height: rowHeight
                )
            )
        }
        return (nodes, items.count - shown.count)
    }

    /// 島の最小幅。これを下回ると、島の中の名前が読めるだけの横幅が残らない。
    ///
    /// 縦横比だけで枡を割ると、幅445ptの領域に6束で3列になり、1列155pt —
    /// 点と余白を引くと名前に100ptしか残らず `power-system-stabi…` と切れた。
    /// 行数が増えて「ほか N」が出るほうが、名前が読めないよりましなので幅を優先する。
    public static let minIslandWidth: Double = 196

    /// 領域の縦横比に合わせて枡を割る。1束なら全面。
    /// ただし幅が足りないときは列を減らす — 名前が読めない列を増やしても意味がない。
    public static func gridShape(
        count: Int,
        aspect: Double,
        width: Double = .infinity
    ) -> (columns: Int, rows: Int) {
        guard count > 1 else { return (1, 1) }
        let byAspect = max(1, Int(ceil((Double(count) * max(aspect, 0.2)).squareRoot())))
        let byWidth = width.isFinite ? max(1, Int(width / minIslandWidth)) : byAspect
        let columns = max(1, min(byAspect, byWidth))
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
        let shape = gridShape(
            count: count,
            aspect: area.width / area.height,
            width: area.width
        )
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

    /// 島の並びに垂直な向き。ここへ等間隔にずらすと、境界に沿って並ぶ。
    ///
    /// 三つ以上の島に属する場合は、いちばん離れた二つの島を軸に取る。端から端まで
    /// を軸にすれば、途中の島がどこにあっても大きく外れない。
    private static func spreadDirection(across centres: [CGPoint]) -> CGVector {
        guard centres.count > 1 else { return CGVector(dx: 1, dy: 0) }
        var best = (a: centres[0], b: centres[1], distance: -1.0)
        for i in 0..<centres.count {
            for j in (i + 1)..<centres.count {
                let d = hypot(centres[i].x - centres[j].x, centres[i].y - centres[j].y)
                if d > best.distance { best = (centres[i], centres[j], d) }
            }
        }
        let dx = best.b.x - best.a.x
        let dy = best.b.y - best.a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.01 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    /// 属していない島の中に落ちたら、その外へ押し出す。
    ///
    /// 三つ以上の束に属する項目の置き場所は、属する島の中心の重心にしている。
    /// ところが枡の並び次第で、その重心が**属していない島**の真ん中に落ちる。
    /// 「電力系統と可視化と講義」のものが講義の隣に座ると、講義のメンバーに
    /// 見えてしまう。いちばん近い縁の外へ逃がす。
    ///
    /// 二周するのは、逃がした先がまた別の島だったときのため。
    private static func pushedOutOfForeignIslands(
        _ point: CGPoint,
        belongingTo mine: Set<String>,
        islands: [String: CGRect]
    ) -> CGPoint {
        let margin: Double = 10
        var result = point
        for _ in 0..<2 {
            var moved = false
            // 順序を固定して、同じ入力なら必ず同じ結果になるようにする。
            for name in islands.keys.sorted() where !mine.contains(name) {
                guard let frame = islands[name], frame.contains(result) else { continue }
                let left = result.x - frame.minX
                let right = frame.maxX - result.x
                let above = result.y - frame.minY
                let below = frame.maxY - result.y
                switch min(left, right, above, below) {
                case left: result.x = frame.minX - margin
                case right: result.x = frame.maxX + margin
                case above: result.y = frame.minY - margin
                default: result.y = frame.maxY + margin
                }
                moved = true
            }
            if !moved { break }
        }
        return result
    }

    // MARK: - 変化

    public mutating func resize(to newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        size = newSize
        // 引き伸ばすのではなく組み直す。決定的なので、同じ大きさなら必ず同じ地図。
        (islands, nodes, bridges, newGroupSlot) = Self.build(
            items: groupedItems,
            groups: groups,
            size: newSize,
            presentNames: presentNames
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
    public func node(at point: CGPoint) -> Node? {
        nodes.reversed().first { $0.hitRect.contains(point) }
    }

    /// その点にある島。ドロップ先を決めるのに使う。
    public func island(at point: CGPoint) -> Island? {
        islands.first { $0.frame.contains(point) }
    }
}
