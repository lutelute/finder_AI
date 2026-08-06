import CoreGraphics
import Foundation

/// 画面の端に出しっぱなしにするフォルダ。
///
/// サイドバーのピン（`WorkspacePins`、30件）とは別の集合にしてある。ピンは
/// 「よく行く場所」の索引で、多くても困らない。こちらは画面の縁という限られた
/// 場所を占めるので、増えるほど1つあたりが押しにくくなる——目的も適正な数も違う
/// ものを、同じ配列で兼ねさせない。
public struct WorkspaceEdgeTabs: Equatable, Sendable {
    private var paths: [String] = []

    /// 画面の高さに素直に収まり、どれがどれか目で追える上限。
    public static let capacity = 8

    public init() {}

    public init(paths: [String]) {
        for path in paths where !self.paths.contains(path) {
            self.paths.append(path)
        }
        if self.paths.count > Self.capacity {
            self.paths = Array(self.paths.prefix(Self.capacity))
        }
    }

    public var urls: [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public var storedPaths: [String] { paths }

    public var isEmpty: Bool { paths.isEmpty }

    public var isFull: Bool { paths.count >= Self.capacity }

    public func contains(_ url: URL) -> Bool {
        paths.contains(url.standardizedFileURL.path)
    }

    /// 追加できなかったとき（すでに在る／上限）はfalse。
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !paths.contains(path), paths.count < Self.capacity else { return false }
        paths.append(path)
        return true
    }

    @discardableResult
    public mutating func remove(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let index = paths.firstIndex(of: path) else { return false }
        paths.remove(at: index)
        return true
    }

    public mutating func toggle(_ url: URL) {
        if contains(url) {
            remove(url)
        } else {
            add(url)
        }
    }
}

/// 画面端のポップアップでの並べ方。
///
/// ブラウザ本体の並べ替えとは別に持つ。端から覗く一覧は「最近いじったもの」を
/// 上に置きたいことが多く、ウインドウの一覧と同じ順にしたいとは限らない。
public enum WorkspaceEdgeTabSort: String, CaseIterable, Sendable {
    case name
    case modified
    case size

    public var title: String {
        switch self {
        case .name: "名前"
        case .modified: "変更日"
        case .size: "サイズ"
        }
    }
}

extension WorkspaceEdgeTabSort {
    /// フォルダを先に固めるのはFinderと同じ。並べ替えの軸が何であれ、フォルダと
    /// ファイルが混ざると目で追えない。
    public func sorted(_ items: [WorkspaceItem], ascending: Bool) -> [WorkspaceItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ordered: Bool
            switch self {
            case .name:
                ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified:
                let left = lhs.modifiedAt ?? .distantPast
                let right = rhs.modifiedAt ?? .distantPast
                if left == right {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                ordered = left < right
            case .size:
                let left = lhs.fileSize ?? 0
                let right = rhs.fileSize ?? 0
                if left == right {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                ordered = left < right
            }
            return ascending ? ordered : !ordered
        }
    }
}

/// 一覧の行に触れたとき、そのウインドウをどう見せるか。
///
/// 前面へ浮かせるのがいちばん確かだが、そのあいだ他のアプリを覆う。覆わずに
/// 済ませたいときのために、示すだけ・見せるだけ・何もしない、を並べて選べる
/// ようにしてある。
public enum WorkspaceWindowPeek: String, CaseIterable, Sendable {
    /// 位置に枠を重ねる。重なりには一切触らない。
    case outline
    /// 中身の縮小を一覧の横に出す。画面収録の許可が要る。
    case thumbnail
    /// 何もしない。押してはじめて前に出る。
    case off
    /// そのウインドウを前面へ浮かせ、あわせて枠で囲む。
    ///
    /// 前に出すだけだと、覗いた1枚と元から手前にいた1枚の区別が付かない。
    /// 枠が付いていれば、どれが覗いているものかは見た瞬間に分かる。
    case lift

    public var title: String {
        switch self {
        case .outline: "枠で場所を示すだけ"
        case .thumbnail: "縮小して中身を見せる"
        case .off: "何もしない（押したときだけ）"
        case .lift: "前面に出して枠で囲む"
        }
    }
}

/// 明るさの選び方。ファイル一覧とターミナルで別々に持つ。
///
/// 一覧は明るく、ターミナルは暗く——という組み合わせが要る。片方だけ変えたい
/// のに両方変わってしまうと、どちらかを諦めることになる。
public enum WorkspaceAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }
}

/// タブを出す画面の縁。
public enum WorkspaceScreenEdge: String, CaseIterable, Sendable {
    case left
    case right

    public var opposite: WorkspaceScreenEdge {
        self == .left ? .right : .left
    }
}

/// 常駐タブと、そこから開くポップアップの位置を決める純粋な計算。
///
/// 画面座標だけで完結させてある。Finderのウインドウに合わせて重ねる旧ドロワー
/// （`PanelPlacementCalculator`）はAccessibilityの許可が要ったが、こちらは
/// `NSScreen.visibleFrame`しか見ないので追加の権限がいらない。
public enum EdgeTabPlacement {
    /// タブ1枚の大きさ。細長い帯で、掴む的として小さすぎない幅。
    public static let tabWidth: CGFloat = 30
    public static let tabHeight: CGFloat = 58
    /// タブどうしは詰めて置く。あいだを空けると、そこだけ触れても反応しない
    /// 帯になり、袖のどこに当たったかで結果が変わる。
    public static let tabSpacing: CGFloat = 0
    /// 展開したポップアップ。
    ///
    /// 幅は「プレビューが読める」ことから決めている。300ptだとサムネイルが小さく、
    /// 中身を確かめるという用が足りない。
    public static let popoverWidth: CGFloat = 380
    /// これ以上は縮めない高さ。
    ///
    /// 中身が少ないときにここまで引き伸ばすのではなく、あくまで下限。プレビューを
    /// 抱える一覧では余裕が要るが、行だけを積む画面では中身の高さがそのまま
    /// 出るほうがいい——5行しかないのに200ptの箱が開くと、下半分が空く。
    public static let popoverMinimumHeight: CGFloat = 72
    public static let popoverMaximumHeight: CGFloat = 640

    public static func stripSize(tabCount: Int) -> CGSize {
        let count = max(0, tabCount)
        let height = CGFloat(count) * tabHeight + CGFloat(max(0, count - 1)) * tabSpacing
        return CGSize(width: tabWidth, height: height)
    }

    /// タブの帯は画面の縁に貼り付き、縦は中央に置く。
    ///
    /// 中央なのは、上端はメニューバーとノッチ、下端はDockに取られていて、
    /// どちらの端も「常にそこにある」と言えないから。
    /// `preferredCenterY`を渡すと、その高さを中心に置く。
    ///
    /// 隠れた帯を呼び出すとき、縁のどこに当てたかに寄せるために使う。画面の
    /// 中央に固定していると、上や下の縁で呼び出しても帯は真ん中に現れ、そこへ
    /// カーソルを運ぶ前に引っ込む——「出たのに触れない」になる。
    public static func stripFrame(
        tabCount: Int,
        edge: WorkspaceScreenEdge,
        visibleFrame: CGRect,
        preferredCenterY: CGFloat? = nil
    ) -> CGRect? {
        let size = stripSize(tabCount: tabCount)
        guard size.height > 0, visibleFrame.height >= size.height else { return nil }
        let x = edge == .right
            ? visibleFrame.maxX - size.width
            : visibleFrame.minX
        let center = preferredCenterY ?? visibleFrame.midY
        let lowest = visibleFrame.minY
        let highest = visibleFrame.maxY - size.height
        let y = min(max(center - size.height / 2, lowest), highest)
        return CGRect(x: x, y: y, width: size.width, height: size.height).integral
    }

    /// 展開したポップアップは、押したタブの高さに頭を合わせて画面の内側へ開く。
    ///
    /// 画面からはみ出す場合は上下にずらして収める。ずらしてなお入らないときは
    /// 縮める——縁に貼り付いたUIで「画面外に出て読めない」が最も困る失敗。
    public static func popoverFrame(
        anchor: CGRect,
        preferredHeight: CGFloat,
        edge: WorkspaceScreenEdge,
        visibleFrame: CGRect
    ) -> CGRect {
        let height = min(
            max(min(preferredHeight, popoverMaximumHeight), popoverMinimumHeight),
            visibleFrame.height
        )
        let x = edge == .right
            ? anchor.minX - popoverWidth
            : anchor.maxX
        let unclampedY = anchor.maxY - height
        let y = min(max(unclampedY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: popoverWidth, height: height).integral
    }

    /// 行数から見積もったポップアップの高さ。
    public static func popoverHeight(rowCount: Int, rowHeight: CGFloat, chrome: CGFloat) -> CGFloat {
        CGFloat(max(rowCount, 1)) * rowHeight + chrome
    }

    /// 縁に触れたと見なす幅。狙って当てられるだけの太さがあり、画面端を素通り
    /// する動きでは踏まない程度。
    public static let triggerThickness: CGFloat = 3

    /// 隠したときに縁へ残す取っ手の幅。
    public static let handleWidth: CGFloat = 4

    /// 自動的に隠したときの帯の位置。取っ手のぶんだけ画面に残す。
    ///
    /// 丸ごと画面の外へ出す作りから改めた。完全に消すと、どこに当てれば戻るのかが
    /// 画面のどこにも書かれていないことになり、当たり判定を広げる・当てた高さに
    /// 出す・出した直後は引っ込めない、と仕掛けを足すほど動きが読めなくなった
    /// （実際に「暴れる」「操作しづらい」状態になった）。
    ///
    /// 4pt見えていれば狙える。狙えるなら、マウス座標の監視も追随もいらない——
    /// 取っ手に触れたかどうかは、ふつうのトラッキングで分かる。
    public static func hiddenStripFrame(
        visible: CGRect,
        edge: WorkspaceScreenEdge
    ) -> CGRect {
        var frame = visible
        frame.origin.x = edge == .right
            ? visible.maxX - handleWidth
            : visible.minX - visible.width + handleWidth
        return frame
    }

    /// 隠れた帯を呼び戻す当たり判定。
    ///
    /// 縦は帯の高さではなく、画面の高さから決める。帯は58ptしかないので、その
    /// 前後だけを見ていると、1440ptの画面では右端の一点を狙わせることになり、
    /// 「端に当てているのに出ない」になる（実際にそうなった）。画面の中央側の
    /// 半分を受け口にして、端に手を振り切れば当たるようにする。
    ///
    /// 中央側の一部だけに絞らないのは、絞った版を実際に使うと「端に当てたのに
    /// 出ない」が残ったため。縁に手を振り切れば当たる、が要る。隅だけは
    /// Mission Controlのホットコーナーに譲る。
    public static let cornerReserve: CGFloat = 8

    public static func triggerContains(
        mouse: CGPoint,
        stripFrame: CGRect,
        edge: WorkspaceScreenEdge,
        visibleFrame: CGRect,
        verticalSlack: CGFloat? = nil
    ) -> Bool {
        let top: CGFloat
        let bottom: CGFloat
        if let verticalSlack {
            top = min(stripFrame.maxY + verticalSlack, visibleFrame.maxY - cornerReserve)
            bottom = max(stripFrame.minY - verticalSlack, visibleFrame.minY + cornerReserve)
        } else {
            top = visibleFrame.maxY - cornerReserve
            bottom = visibleFrame.minY + cornerReserve
        }
        guard mouse.y >= bottom, mouse.y <= top else { return false }
        switch edge {
        case .right:
            return mouse.x >= visibleFrame.maxX - triggerThickness
        case .left:
            return mouse.x <= visibleFrame.minX + triggerThickness
        }
    }
}
