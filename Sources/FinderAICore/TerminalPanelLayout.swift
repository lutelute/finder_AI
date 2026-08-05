import CoreGraphics
import Foundation

/// ターミナルパネルがウインドウのどの辺に付くか。
///
/// 下辺は横に長く縦が短い。行が折り返さない代わりに、スクロールバックが数行しか
/// 見えない。縦長のログ（ビルド出力、AIセッション）を追うときは右辺のほうが読める
/// ので、どちらかを選べるようにしている。
public enum TerminalPanelEdge: String, CaseIterable, Sendable {
    case bottom
    case right

    public var opposite: TerminalPanelEdge {
        self == .bottom ? .right : .bottom
    }
}

/// パネルの「厚み」（下辺なら高さ、右辺なら幅）を決める純粋な計算。
///
/// ウインドウ側は制約の張り替えだけを受け持ち、どこまで太らせてよいかの判断は
/// すべてここにある。辺ごとに下限が違うのは、80桁のターミナルが潰れない幅と、
/// 数行が読める高さが別物だから。
public enum TerminalPanelLayout {
    /// 畳んだときに残るヘッダーの厚み。下辺ならバーの高さ、右辺なら縦ストリップの幅。
    public static let collapsedThickness: CGFloat = 34

    public static func minimumThickness(for edge: TerminalPanelEdge) -> CGFloat {
        switch edge {
        case .bottom: 160
        case .right: 280
        }
    }

    public static func maximumThickness(for edge: TerminalPanelEdge) -> CGFloat {
        switch edge {
        case .bottom: 600
        case .right: 720
        }
    }

    public static func defaultThickness(for edge: TerminalPanelEdge) -> CGFloat {
        switch edge {
        case .bottom: 300
        case .right: 420
        }
    }

    /// 相手（ファイル一覧）に残さなければならない寸法を差し引いた上で、要求された
    /// 厚みを許容範囲へ収める。
    ///
    /// `available`が0のとき（まだレイアウトされていないウインドウ）は辺の上限だけで
    /// 判断する。両方を満たせないほど狭いウインドウでも、下限を返して必ず使える値に
    /// する——ここでnilを返すと呼び出し側が制約を張れずレイアウトが壊れる。
    public static func clamped(
        _ proposed: CGFloat,
        edge: TerminalPanelEdge,
        available: CGFloat,
        browserMinimum: CGFloat
    ) -> CGFloat {
        let floor = minimumThickness(for: edge)
        let ceiling = available > 0
            ? min(maximumThickness(for: edge), available - browserMinimum)
            : maximumThickness(for: edge)
        guard ceiling > floor else { return floor }
        return min(max(proposed, floor), ceiling)
    }

    /// ヘッダーのダブルクリックで巡る段階。
    public enum Snap: Sendable {
        case collapsed
        case half
        case full
    }

    /// その段階の厚み。`collapsed`だけは「閉じる」という別の操作なのでnilを返す。
    public static func thickness(
        for snap: Snap,
        edge: TerminalPanelEdge,
        available: CGFloat,
        browserMinimum: CGFloat
    ) -> CGFloat? {
        switch snap {
        case .collapsed:
            return nil
        case .half:
            let half = available > 0 ? available / 2 : defaultThickness(for: edge)
            return clamped(half, edge: edge, available: available, browserMinimum: browserMinimum)
        case .full:
            return clamped(
                maximumThickness(for: edge),
                edge: edge,
                available: available,
                browserMinimum: browserMinimum
            )
        }
    }

    /// 畳む→半分→最大→畳む、の巡回。
    ///
    /// 現在地は「今の厚み」から読み取るので、手でドラッグして半端な大きさにした
    /// あとでも、次のダブルクリックは必ず一段大きい側へ進む。半分と最大が同じ値に
    /// なるほど窓が狭いときは、開く／畳むの2段階に自然に縮退する。
    public static func nextSnap(
        currentThickness: CGFloat,
        isExpanded: Bool,
        edge: TerminalPanelEdge,
        available: CGFloat,
        browserMinimum: CGFloat
    ) -> Snap {
        guard isExpanded else { return .half }
        let full = thickness(
            for: .full,
            edge: edge,
            available: available,
            browserMinimum: browserMinimum
        ) ?? maximumThickness(for: edge)
        let half = thickness(
            for: .half,
            edge: edge,
            available: available,
            browserMinimum: browserMinimum
        ) ?? defaultThickness(for: edge)
        // 1ptの誤差はドラッグの丸めで普通に出るので、等号ではなく近傍で見る。
        if currentThickness >= full - 2 { return .collapsed }
        if currentThickness >= half - 2 { return .full }
        return .half
    }
}
