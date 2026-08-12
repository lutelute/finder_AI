import CoreGraphics
import Foundation

/// グループを「島」として並べ、複数のグループに属するものをその境界に置く配置。
///
/// 一覧は線形なので、二つのグループに属するものは二行に割れる。同じ実体が二度並ぶだけで、
/// どこが重なりなのかは行からは読めない。平面ならそれが**位置**で出る — 両方の島に
/// 属する項目は、その境界に立つ。それがこの表示の主題。
///
/// ## 力学をやめた経緯
///
/// はじめはばね・反発・アンカーで解いていた。三度作り直して、そのたびに実機で
/// 別の破綻が出た。
///
/// 1. 全152項目を力学に入れた → グループに属さない116個が29個を包囲し、画面の八割を
///    無関係な点が占めた（「カツかつでえらい見辛い」）。グループに属さないものは
///    そもそも受け取らないことにした（`WorkspaceItemGroups.partition`）。
/// 2. グループごとのアンカーを置いた → グループは固まったが、点が島の端に寄って名前が枠から
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
        /// 属しているグループ。ここに来るものは必ず一つ以上持つ。
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

    /// 一つのグループと、その島の矩形。
    public struct Island: Equatable, Sendable {
        public let name: String
        /// 島の枠。**子の島を含む**外周。
        public let frame: CGRect
        /// 自分のメンバーを並べる領域。子がいる島では、子の枠と重ならない部分だけ。
        public let contentFrame: CGRect
        /// 入れ子の深さ。最上位は0。枠の濃さと字下げに使う。
        public let depth: Int
        /// 島の中に並べきれなかった数。0でなければ「ほか N」と出す必要がある。
        public let overflow: Int
        /// 定義にあるのに実物が無い数。フォルダを消したり別の場所へ動かすと増える。
        public let missing: Int
    }

    public private(set) var nodes: [Node]
    public private(set) var islands: [Island]
    public private(set) var size: CGSize

    /// 複数のグループに属するノードの添字。橋を描く相手。
    public private(set) var bridges: [Int]

    /// 「新しいグループ」の枠。ここに落とせばグループを作れる。
    ///
    /// グループが一つも無いフォルダでは、これが唯一の入口になる（枡いっぱいに出る）。
    /// グループがあるときは最後の枡を空けて置く — 地図の上で作れないと、右クリックの
    /// メニューを知っている人しかグループを作れない。
    public private(set) var newGroupSlot: CGRect?

    /// 中身を全部置くのに要る高さ。見える高さより長ければ、紙のほうを伸ばして
    /// スクロールで辿る。島の高さを中身ぴったりにした以上、必要な高さは
    /// 中身が決めるもので、画面が決めるものではない。
    public private(set) var contentHeight: Double = 0

    private let groupedItems: [WorkspaceItem]
    private let groups: WorkspaceItemGroups?
    private let presentNames: Set<String>?

    /// 島の内側の余白と、グループ名の帯の高さ。
    public static let islandInset = CGSize(width: 14, height: 12)
    public static let islandTitleHeight: Double = 23
    /// 島の中の一行。点と名前が並ぶ高さ。
    ///
    /// 21ptだと、幅を優先して2列3行に割ったときに6行しか入らず、7項目のグループから
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
        (islands, nodes, bridges, newGroupSlot, contentHeight) = Self.build(
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
    ) -> ([Island], [Node], [Int], CGRect?, Double) {
        let names = groups?.adjacencyOrderedNames() ?? []
        guard size.width > 1, size.height > 1 else { return ([], [], [], nil, size.height) }

        let margin: Double = 14
        let slotHeight: Double = 44
        let slotGap: Double = 12

        // グループが一つも無ければ、帯ではなく全面を入口にする。ここしか入口がない。
        guard !names.isEmpty else {
            return ([], [], [], CGRect(
                x: margin,
                y: margin,
                width: max(size.width - margin * 2, 1),
                height: max(size.height - margin * 2, 1)
            ), size.height)
        }

        // 定義にあるのに実物が無いものを数える。呼び出し側はグループに属するものだけを
        // 渡してくるので、ここで数えられるのは「グループの定義に居るが実物が無い」名前。
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

        // 入れ子のまま枠を割る。最上位だけが領域を取り合い、子は親の枠の内側を分ける。
        // 平らな定義なら、これは今までどおりの格子と同じ結果になる。
        // 高さは決めない。島は中身のぶんだけ縦に積まれ、要るだけ紙が伸びる。
        let area = CGRect(
            x: margin,
            y: margin,
            width: max(size.width - margin * 2, 1),
            height: max(size.height - margin * 2, 1)
        )
        var islands: [Island] = []
        if let groups {
            islands = nestedIslands(
                of: nil,
                in: area,
                groups: groups,
                ownCounts: exclusive.mapValues(\.count),
                missing: missingByGroup,
                depth: 0
            )
        }
        let byName = Dictionary(
            islands.map { ($0.name, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )

        var built: [Node] = []
        /// 島ごとの、並べた行の下端。境界に立つ点をここより下に置く。
        var rowsBottom: [String: Double] = [:]

        islands = islands.map { island in
            let members = (exclusive[island.name] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let (placed, overflow) = place(
                members,
                in: island.contentFrame,
                groups: [island.name],
                reservedRows: island.missing > 0 ? 1 : 0
            )
            rowsBottom[island.name] =
                (placed.map { $0.position.y }.max() ?? island.contentFrame.minY) + rowHeight / 2
            built.append(contentsOf: placed)
            return Island(
                name: island.name,
                frame: island.frame,
                contentFrame: island.contentFrame,
                depth: island.depth,
                overflow: overflow,
                missing: island.missing
            )
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
        // 「新しいグループ」の帯は、中身の下に置く。島の高さを中身ぴったりにした以上、
        // 下端は画面ではなく中身が決める。
        let bottom = islands.map(\.frame.maxY).max() ?? area.minY
        let slotTop = max(bottom + slotGap, size.height - margin - slotHeight)
        let newGroupSlot = CGRect(
            x: margin,
            y: slotTop,
            width: max(size.width - margin * 2, 1),
            height: slotHeight
        )
        return (
            islands,
            built,
            bridges,
            newGroupSlot,
            max(slotTop + slotHeight + margin, size.height)
        )
    }

    /// 島の中に名前順で並べる。入りきらない分は数だけ返す。
    ///
    /// 一列に並べるのは名前を読ませるため。二列にすると一列の幅が半分になり、
    /// `bus_inertia_project_for_SHAKIL` のような名前が切れて、並べた意味が薄れる。
    /// - Parameter reservedRows: 下端に空けておく行数。「見つからない N →」の帯に使う。
    private static func place(
        _ items: [WorkspaceItem],
        in frame: CGRect,
        groups: [String],
        reservedRows: Int = 0
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
        // 「見つからない N →」の帯のぶんを先に空けておく。空けずに並べると、
        // 島の下端の名前とその文字が重なって、どちらも読めなくなる。
        let rows = max(Int(height / rowHeight) - reservedRows, 0)
        guard rows > 0 else { return ([], items.count) }

        // 一列で入るなら一列のまま。7個を二列に割っても、読む順が折り返すだけで
        // 得るものがない。
        //
        // 入りきらないときだけ、余っている**幅**を使う。高さだけで数えていたころは、
        // 島が横に広くても「ほか N」と言って隠していた — 置ける場所を空けたまま
        // 隠すのは、広げても中身が見えないということ（島を全面に広げても
        // 表示数が変わらなかったのはこれが理由）。
        // 入りきらないときは、いちばん下の一行を「ほか N」の帯に譲る。
        // まず幅を列に使う。列を増やしても入らないときだけ、最後の一行を
        // 「ほか N」の帯に譲る。先に一行譲ってから列を数えていたので、
        // 高さを中身ぴったりに配った島で辻褄が合わず、7個のうち4個しか出なかった。
        let columns = max(
            columnsInside(count: items.count, width: frame.width),
            // 高さが足りないときは、幅の許す範囲で増やして詰める。
            min(
                max(Int(usable.width / minColumnWidth), 1),
                max(Int((Double(items.count) / Double(rows)).rounded(.up)), 1)
            )
        )
        let usableRows = items.count > rows * columns ? max(rows - 1, 1) : rows
        let capacity = usableRows * columns
        guard capacity > 0 else { return ([], items.count) }

        let shown = Array(items.prefix(capacity))
        let columnWidth = usable.width / Double(columns)
        let nodes = shown.enumerated().map { index, item in
            // 縦に読んでから隣の列へ。名前順に並べたものを横に読ませると、
            // 折り返しのたびに目が戻る。
            let column = index / usableRows
            let row = index % usableRows
            let centreY = top + rowHeight * (Double(row) + 0.5)
            let left = usable.minX + columnWidth * Double(column)
            return Node(
                name: item.name,
                isDirectory: item.isDirectory,
                groups: groups,
                position: CGPoint(x: left + 8, y: centreY),
                labelPlacement: .trailing,
                hitRect: CGRect(
                    x: left,
                    y: centreY - rowHeight / 2,
                    width: columnWidth,
                    height: rowHeight
                )
            )
        }
        return (nodes, items.count - shown.count)
    }

    /// 島の最小幅。これを下回ると、島の中の名前が読めるだけの横幅が残らない。
    ///
    /// 縦横比だけで枡を割ると、幅445ptの領域に6グループで3列になり、1列155pt —
    /// 点と余白を引くと名前に100ptしか残らず `power-system-stabi…` と切れた。
    /// 行数が増えて「ほか N」が出るほうが、名前が読めないよりましなので幅を優先する。
    public static let minIslandWidth: Double = 196

    /// 島の中を縦に割るときの一列の最小幅。島の最小幅から内側の余白を引いた値。
    /// これを下回る列を作っても、点と余白で名前の場所が残らない。
    public static let minColumnWidth: Double = minIslandWidth - islandInset.width * 2

    /// 領域の縦横比に合わせて枡を割る。1グループなら全面。
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

    /// そのグループと、その下にぶら下がる全部の名前。枡の重みを数えるのに使う。
    private static func subtree(of name: String, in groups: WorkspaceItemGroups) -> [String] {
        var result = [name]
        var queue = groups.children(of: name)
        var seen: Set<String> = [name]
        while let current = queue.first {
            queue.removeFirst()
            guard seen.insert(current).inserted else { continue }
            result.append(current)
            queue.append(contentsOf: groups.children(of: current))
        }
        return result
    }

    /// 枡の重み。**そのグループが抱えている中身の量**で決める。
    ///
    /// 子グループの数だけで割っていた。8個入った島と2個の島が同じ大きさになり、
    /// 大きいほうだけが「ほか N」で隠れる — 見たいのは中身なのに、枠の数で
    /// 場所を配っていた。中身の数を主にして、子の枠が食う場所を足す。
    /// - Parameter width: その島に配られる幅。中を何列に割れるかが決まるので、
    ///   要る高さは幅次第で変わる。幅を見ずに「一行×件数」で数えると、80個入った
    ///   束が1500ptの縦長になり、紙をひたすらスクロールすることになる。
    private static func weight(
        of name: String,
        in groups: WorkspaceItemGroups,
        ownCounts: [String: Int],
        missing: [String: [String]],
        width: Double
    ) -> Double {
        let own = Double(ownCounts[name] ?? 0)
        // 「見つからない N →」も一行を占める。数えないと、その一行を空けるために
        // 中身が押し出される（実測: 4個入った島が2個しか出なくなった）。
        let notes = missing[name]?.isEmpty == false ? 1.0 : 0.0
        let columns = Double(columnsInside(count: Int(own), width: width))
        let rows = (own / columns).rounded(.up) + notes
        let children = groups.children(of: name)
        let childWidth = max(width - islandInset.width * 4, 1)
        let inside = children.isEmpty
            ? 0
            : children.reduce(0.0) {
                $0 + weight(
                    of: $1,
                    in: groups,
                    ownCounts: ownCounts,
                    missing: missing,
                    width: childWidth
                )
            } + Double(children.count - 1) * 8 + islandInset.height * 2
        return islandTitleHeight + islandInset.height * 2 + rowHeight * rows + inside
    }

    /// 一つの島の中を何列に割るか。**縦に長くなりすぎるときだけ**増やす。
    ///
    /// 幅があるからと常に割ると、7個の束が2列に折り返して読む順が分かりにくくなる。
    /// 一列で読めるうちは一列。長くなってきたら、幅の許す範囲で列を増やす。
    static func columnsInside(count: Int, width: Double) -> Int {
        let inner = max(width - islandInset.width * 2, 1)
        let byWidth = max(Int(inner / minColumnWidth), 1)
        let byLength = max(Int((Double(count) / maxRowsPerColumn).rounded(.up)), 1)
        return max(1, min(byWidth, byLength))
    }

    /// 一列に積む行数の目安。これを超えたら列を増やす。
    static let maxRowsPerColumn: Double = 24

    /// その領域に島を何列並べるか。`cells`と重みの計算で同じ数を使う。
    private static func columnCount(for count: Int, width: Double) -> Int {
        max(1, min(count, Int(width / minIslandWidth)))
    }

    /// 島一つぶんの幅。
    private static func columnWidth(for count: Int, in width: Double, gap: Double) -> Double {
        let columns = Double(columnCount(for: count, width: width))
        return max((width - gap * (columns - 1)) / columns, 1)
    }

    /// 島がまともに見えるための最小の高さ。名前の帯と、中身の一行分。
    ///
    /// これを割ると、名前すら出ない箱が並ぶ。中身の量で場所を配ると、2個しか入って
    /// いない束が31ptまで痩せて一つも出なくなった。配る前にここを確保する。
    public static let minIslandHeight: Double = islandTitleHeight + islandInset.height * 2 + rowHeight

    /// 入れ子のまま枠を割る（`A ∈ B` を、Bの枠の内側にAの枠として描くための下ごしらえ）。
    ///
    /// 各段で領域を枡に割り、子を持つグループはその枡をさらに「自分のメンバーの場所」と
    /// 「子の場所」に分ける。親の`frame`は子を含む外周で、`contentFrame`が自分の行の場所。
    ///
    /// 子に場所を譲るので、親自身のメンバーは入りきらないことがある（「ほか N」になる）。
    /// **入れ子の形が見えることを優先する** — 親子が同列に並んでいると、それは嘘になる。
    private static func nestedIslands(
        of parent: String?,
        in area: CGRect,
        groups: WorkspaceItemGroups,
        ownCounts: [String: Int],
        missing: [String: [String]],
        depth: Int
    ) -> [Island] {
        let names = depth == 0
            // 最上位は、共有でつながったものを隣に寄せた順で並べる（橋を短くする）
            ? groups.adjacencyOrderedNames().filter { groups.depth(of: $0) == 0 }
            : groups.children(of: parent)
        guard !names.isEmpty else { return [] }

        // 中身の多い島ほど場所を取る。幅は先に決める — 何列に割れるかで要る高さが変わる。
        let gap: Double = depth == 0 ? 12 : 8
        let cellWidth = columnWidth(for: names.count, in: area.width, gap: gap)
        let weights = names.map {
            weight(of: $0, in: groups, ownCounts: ownCounts, missing: missing, width: cellWidth)
        }
        let boxes = cells(weights: weights, in: area, gap: gap)
        guard boxes.count == names.count else { return [] }

        var result: [Island] = []
        for (name, box) in zip(names, boxes) {
            let children = groups.children(of: name)
            let inset = box.insetBy(dx: islandInset.width, dy: islandInset.height)
            // 余白を引いて潰れる枠でも、島そのものは作る（同じ理由）。
            if children.isEmpty || inset.isNull || inset.height <= 0 {
                result.append(Island(
                    name: name,
                    frame: box,
                    contentFrame: box,
                    depth: depth,
                    overflow: 0,
                    missing: missing[name]?.count ?? 0
                ))
                // 子がいるのに場所が無いときは、子も同じ枠に重ねず諦める（描けない）。
                continue
            }

            // 自分の行と子の場所を、それぞれが欲しい高さで分ける。
            //
            // 「子の場所を残すため、自分は最大でも枠の四割まで」と決め打っていた。
            // 子が小さくても親の直下が四割で頭打ちになり、空いているのに親の
            // メンバーが「ほか N」に落ちた。枡の大きさを中身の量で配るように
            // した以上、この中でも同じ配り方をするのが筋。
            let notes = missing[name]?.isEmpty == false ? 1.0 : 0.0
            let ownColumns = Double(columnsInside(count: ownCounts[name] ?? 0, width: box.width))
            let ownRows = (Double(ownCounts[name] ?? 0) / ownColumns).rounded(.up) + notes
            let ownWanted = islandTitleHeight + islandInset.height * 2 + rowHeight * ownRows
            let childrenWanted = children.reduce(0.0) {
                $0 + weight(
                    of: $1,
                    in: groups,
                    ownCounts: ownCounts,
                    missing: missing,
                    width: max(inset.width - islandInset.width * 2, 1)
                )
            } + Double(children.count - 1) * 8
            // 入るなら両方に欲しいだけ渡す。按分すると、端数のせいで親の最後の一行が
            // 落ちる（実測: 10個入れた親が4個しか出なかった）。
            let floor = islandTitleHeight + islandInset.height * 2
            let ownHeight = inset.height >= ownWanted + childrenWanted
                ? ownWanted
                : max(share(inset.height, among: [ownWanted, childrenWanted])[0], floor)
            let contentFrame = CGRect(
                x: box.minX,
                y: box.minY,
                width: box.width,
                height: max(ownHeight, floor)
            )
            let childArea = CGRect(
                x: inset.minX,
                y: contentFrame.maxY,
                width: inset.width,
                height: max(inset.maxY - contentFrame.maxY, 0)
            )

            result.append(Island(
                name: name,
                frame: box,
                contentFrame: contentFrame,
                depth: depth,
                overflow: 0,
                missing: missing[name]?.count ?? 0
            ))
            result += nestedIslands(
                of: name,
                in: childArea,
                groups: groups,
                ownCounts: ownCounts,
                missing: missing,
                depth: depth + 1
            )
        }
        return result
    }

    /// 領域に島を並べる。入れ子の各段でこれを呼ぶ。
    ///
    /// `weights`は各島が欲しい高さ（`weight(of:)`が中身の量から出す）。
    private static func cells(
        weights: [Double],
        in area: CGRect,
        gap: Double = 12
    ) -> [CGRect] {
        let count = weights.count
        // 潰れた領域でも枡は返す。ここで空を返すと島そのものが消え、
        // 「グループがあるのに何も見えない」になる。
        guard count > 0, area.width > 0 else { return [] }

        // 島の高さは**中身の量そのもの**。画面の高さに合わせて引き伸ばさない。
        //
        // 行の格子に揃えていたので、同じ行の島が全部同じ高さになり、5項目の島が
        // 385pt、隣の行の4項目の島が154ptという並びになっていた。同じ種類のものが
        // 理由なく2.5倍違うのが、この画面でいちばん強い「作りかけ」の合図だった。
        //
        // 列は幅で決めて、次の島はいちばん空いている列へ積む（新聞の段組みと同じ）。
        // 入りきらないぶんは紙が縦に伸びる。
        let columns = columnCount(for: count, width: area.width)
        let columnWidth = columnWidth(for: count, in: area.width, gap: gap)
        var used = [Double](repeating: 0, count: columns)
        var cells: [CGRect] = []
        for weight in weights {
            let column = used.enumerated().min { lhs, rhs in
                // 高さが同じなら左から埋める。同じフォルダなら同じ地図になるように。
                lhs.element == rhs.element ? lhs.offset < rhs.offset : lhs.element < rhs.element
            }?.offset ?? 0
            let top = area.minY + used[column] + (used[column] > 0 ? gap : 0)
            cells.append(CGRect(
                x: area.minX + (columnWidth + gap) * Double(column),
                y: top,
                width: columnWidth,
                height: max(weight, minIslandHeight)
            ))
            used[column] = top - area.minY + max(weight, minIslandHeight)
        }
        return cells
    }

    /// 使わなくなった格子の割り方。`gridShape`の試験が参照している。
    private static func gridCells(
        weights: [Double],
        in area: CGRect,
        gap: Double
    ) -> [CGRect] {
        let count = weights.count
        guard count > 0, area.width > 0, area.height > 0 else { return [] }
        let shape = gridShape(count: count, aspect: area.width / area.height, width: area.width)

        if shape.columns == 1, count > 1 {
            let usable = max(area.height - gap * Double(count - 1), 0)
            let heights = share(usable, among: weights)
            var y = area.minY
            return heights.map { height in
                let cell = CGRect(x: area.minX, y: y, width: area.width, height: height)
                y += height + gap
                return cell
            }
        }
        // 潰れた枡でも返す。狭いからと 島を落とすと「グループがあるのに何も
        // 見えない」になる。中身が入らないことは`place`が「ほか N」として言う。
        let cellWidth = max((area.width - gap * Double(shape.columns - 1)) / Double(shape.columns), 0)

        // 行の高さは、その行でいちばん中身の多い島に合わせて配る。均等に割ると、
        // 8個入った島と2個の島が同じ高さになり、多いほうだけが「ほか N」で隠れた。
        // 幅は揃えたままにする — 列ごとに幅が違うと、島によって名前の読める長さが
        // 変わって、地図の中で場所によって情報量が違うことになる。
        let usableHeight = max(area.height - gap * Double(shape.rows - 1), 0)
        var rowWeights = [Double](repeating: 0, count: shape.rows)
        for index in 0..<count {
            let row = min(index / shape.columns, shape.rows - 1)
            rowWeights[row] = max(rowWeights[row], weights[index])
        }
        var rowTop: [Double] = []
        var rowHeight: [Double] = []
        var y = area.minY
        for height in share(usableHeight, among: rowWeights) {
            rowTop.append(y)
            rowHeight.append(height)
            y += height + gap
        }

        return (0..<count).map { index in
            let row = min(index / shape.columns, shape.rows - 1)
            // 蛇行して折り返す。行優先で素直に並べると、行末のグループと次の行頭のグループが
            // 対角に離れる。共有のあるグループを隣の番号にしても、それが画面で隣に
            // ならず橋が地図を横断した。
            let raw = index % shape.columns
            let column = row.isMultiple(of: 2) ? raw : shape.columns - 1 - raw
            return CGRect(
                x: area.minX + (cellWidth + gap) * Double(column),
                y: rowTop[row],
                width: cellWidth,
                height: rowHeight[row]
            )
        }
    }

    /// 高さを配る。`wanted`は「そのぶんあれば中身が全部入る」高さ。
    ///
    /// 足りるときは欲しいだけ渡し、余りは中身の多い順に足す（空きを一箇所に
    /// 寄せない）。足りないときは、まず**どの島も名前と一行は出せる高さ**を
    /// 確保してから、残りを比で配る。比だけで配ると、2個しか入っていない束が
    /// 名前の帯も入らない高さまで痩せて、中身が一つも出なくなる。
    private static func share(_ available: Double, among wanted: [Double]) -> [Double] {
        guard !wanted.isEmpty, available > 0 else {
            return [Double](repeating: 0, count: wanted.count)
        }
        var result = [Double](repeating: 0, count: wanted.count)
        var remaining = available
        var open = Set(wanted.indices)

        // 少なく欲しいものから満たす。均等割りで足りるものは、その欲しい高さで
        // 確定して、浮いたぶんを残りに回す。比だけで配ると、2個しか入っていない束が
        // 名前の帯も入らない高さまで痩せて中身が一つも出なくなった。大きい島は
        // 元々「ほか N」で続きを示せるので、削るならそちら。
        while !open.isEmpty {
            let fair = remaining / Double(open.count)
            let satisfied = open.filter { wanted[$0] <= fair }
            guard !satisfied.isEmpty else {
                // どれも欲しい高さに届かない。ここは等分しかない。
                for index in open { result[index] = fair }
                remaining = 0
                break
            }
            for index in satisfied {
                result[index] = wanted[index]
                remaining -= wanted[index]
            }
            open.subtract(satisfied)
        }

        // 余ったら、欲しがっている割合で足す。空きを一箇所に寄せない。
        if remaining > 0.01 {
            let total = max(wanted.reduce(0, +), 0.0001)
            for index in wanted.indices {
                result[index] += remaining * (wanted[index] / total)
            }
        }
        return result
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
    /// 三つ以上のグループに属する項目の置き場所は、属する島の中心の重心にしている。
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
        (islands, nodes, bridges, newGroupSlot, contentHeight) = Self.build(
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

    public enum Direction: Equatable, Sendable {
        case up, down, left, right

        var isVertical: Bool { self == .up || self == .down }
    }

    /// 矢印キーの行き先。位置で決める。
    ///
    /// 配列の前後で決めると、島をまたぐ瞬間に画面の反対側へ飛ぶ（`nodes`は島ごとに
    /// 並んでいて、島の並びは蛇行しているため）。目で見えている通りに動かしたいので、
    /// **その向きにあるもののうち、いちばん近いもの**を選ぶ。
    ///
    /// 横のずれに許容を持たせているのは、島の中の行と境界に立つ点で横位置が違うから。
    /// 厳密に真上・真下だけを見ると、境界の点から島へ戻れなくなる。
    public func node(from name: String, towards direction: Direction) -> Node? {
        guard let current = node(named: name) else { return nodes.first }
        let origin = current.position

        let candidates = nodes.filter { node in
            guard node.name != name else { return false }
            let dx = node.position.x - origin.x
            let dy = node.position.y - origin.y
            let along = direction.isVertical ? dy : dx
            let across = direction.isVertical ? dx : dy
            let forward = switch direction {
            case .down, .right: along > 1
            case .up, .left: along < -1
            }
            // 進む向きの距離に応じて、横のずれを許す幅を広げる。近いものは真っ直ぐ、
            // 遠いものは斜めでも拾う。
            return forward && abs(across) <= max(abs(along) * 1.2, 44)
        }

        return candidates.min {
            hypot($0.position.x - origin.x, $0.position.y - origin.y)
                < hypot($1.position.x - origin.x, $1.position.y - origin.y)
        }
    }

    /// その点にある島。ドロップ先を決めるのに使う。
    ///
    /// 入れ子では親の枠が子を含むので、**いちばん内側（深い）島**を返す。親の枠に
    /// 落ちたつもりで子に入る、あるいはその逆を防ぐ。
    public func island(at point: CGPoint) -> Island? {
        islands.filter { $0.frame.contains(point) }.max { $0.depth < $1.depth }
    }
}
