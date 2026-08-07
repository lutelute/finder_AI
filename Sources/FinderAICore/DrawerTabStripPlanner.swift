import CoreGraphics

/// タブ帯に何本まで並べ、どこまで削るかの決定。
///
/// 帯は「表示中の全セッション」を映すので、窓を10枚も20枚も開く使い方では
/// 横がすぐ埋まる。埋まったときに隠れたメニューへ逃がすのではなく、
/// 名前を落とし、印だけにして、それでも入らないぶんだけを数で示す——
/// 見えているものが増えるほうが、開いて探すより早い。
public enum DrawerTabStripPlanner {
    /// 1本のタブをどこまで見せるか。
    public enum TabDisplay: Equatable, Sendable {
        /// 名前とフォルダ。
        case full
        /// 名前だけ。フォルダは落とす。
        case nameOnly
        /// 種類の印だけ。名前はツールチップへ回す。
        case iconOnly

        public var width: CGFloat {
            switch self {
            case .full: 148
            case .nameOnly: 92
            case .iconOnly: 30
            }
        }
    }

    public struct Plan: Equatable, Sendable {
        /// 並べるタブの見せ方。
        public let display: TabDisplay
        /// 帯に出す本数。
        public let visibleCount: Int
        /// 入り切らず数だけ示すぶん。
        public let overflow: Int

        public init(display: TabDisplay, visibleCount: Int, overflow: Int) {
            self.display = display
            self.visibleCount = visibleCount
            self.overflow = overflow
        }
    }

    public static let spacing: CGFloat = 4
    /// あふれたぶんを示すチップ（「＋N」）の幅。
    public static let overflowChipWidth: CGFloat = 40

    /// - Parameters:
    ///   - availableWidth: タブに使える横幅。
    ///   - rowCount: 何段に積めるか。右辺の細いパネルでは段を増やして稼ぐ。
    public static func plan(
        tabCount: Int,
        availableWidth: CGFloat,
        rowCount: Int = 1
    ) -> Plan {
        guard tabCount > 0 else {
            return Plan(display: .full, visibleCount: 0, overflow: 0)
        }
        let rows = max(1, rowCount)

        // 削らずに済む見せ方を上から順に探す。名前が出ているほうが速い。
        for display in [TabDisplay.full, .nameOnly, .iconOnly] {
            if capacity(width: availableWidth, tabWidth: display.width) * rows >= tabCount {
                return Plan(display: display, visibleCount: tabCount, overflow: 0)
            }
        }

        // 印だけにしても入らない。チップのぶんを空けて、残りを数で示す。
        //
        // どんなに狭くても1本は残す。全部を数へ送ると「今どれを見ているか」が
        // 帯から消え、押す先も無くなる——狭いときほど、今いる1本だけは
        // 見えていないと困る（並びは今いる場所を先頭にしてある）。
        let widthForTabs = availableWidth - overflowChipWidth - spacing
        let fits = capacity(width: widthForTabs, tabWidth: TabDisplay.iconOnly.width) * rows
        let visible = max(1, min(tabCount, fits))
        return Plan(
            display: .iconOnly,
            visibleCount: visible,
            overflow: tabCount - visible
        )
    }

    /// その幅に何本入るか。並びの間隔は本数-1個ぶん。
    private static func capacity(width: CGFloat, tabWidth: CGFloat) -> Int {
        guard width > 0, tabWidth > 0 else { return 0 }
        let count = Int(((width + spacing) / (tabWidth + spacing)).rounded(.down))
        return max(0, count)
    }
}
