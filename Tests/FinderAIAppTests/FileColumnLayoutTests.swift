import AppKit
import Testing

@testable import FinderAIApp

/// The authored widths add up to 850pt and the gutters add 68 more, so the row
/// wants 918pt however narrow the list is. Beside the default 210pt sidebar that
/// fits and there is even 36pt to spare; beside a 299pt one it does not, and the
/// list carried a permanent horizontal scroller with 種類 pushed off-screen.
///
/// Two separate things were wrong, and only the second causes the scroller:
/// surplus width went to 種類 instead of 名前, and nothing ever handled a
/// *shortfall* — AppKit redistributes width only when a table is resized, never
/// on the first layout, and never below a column's authored width. 名前 is
/// therefore sized explicitly on every layout, which covers both directions.
@MainActor
@Suite("File list column geometry")
struct FileColumnLayoutTests {
    private typealias Browser = WorkspaceBrowserViewController

    /// Window width minus sidebar, divider and vertical scroller.
    private func viewport(window: CGFloat, sidebar: CGFloat) -> CGFloat {
        window - sidebar - 1 - 15
    }

    private func columns() -> [NSTableColumn] {
        Browser.makeFileColumns()
    }

    /// Mirrors `layoutFileColumns()` with the table's real 17pt gutters.
    private func sizedColumns(viewport: CGFloat) -> [NSTableColumn] {
        let columns = columns()
        let name = columns[0]
        name.width = Browser.nameColumnWidth(
            viewport: viewport,
            fixedColumnsTotal: columns.dropFirst().reduce(0) { $0 + $1.width },
            gutters: 17 * CGFloat(columns.count),
            minimum: name.minWidth
        )
        return columns
    }

    private func total(_ columns: [NSTableColumn]) -> CGFloat {
        columns.reduce(0) { $0 + $1.width } + 17 * CGFloat(columns.count)
    }

    @Test("名前 fills the row exactly across every sidebar width")
    func nameFillsTheRow() {
        // Sidebar is clamped to 160...360 and the window cannot go below 820pt.
        for sidebar in [160, 210, 299, 360] as [CGFloat] {
            let width = viewport(window: 1180, sidebar: sidebar)
            let sized = sizedColumns(viewport: width)
            #expect(
                abs(total(sized) - width) < 0.5,
                "sidebar \(sidebar)pt leaves \(width - total(sized))pt unused or overflowing"
            )
            #expect(sized[0].width > sized[3].width, "名前 should outgrow 種類")
        }
    }

    /// Measured on a real window: 名前 was 433pt with the scroller and is 380pt
    /// without it. Removing the scroller costs name width at a wide sidebar and
    /// gains it at a narrow one, and that trade is the point of the change — a
    /// regression here would most likely show up as one direction silently
    /// swallowing the other.
    @Test("名前 grows past its authored width only when the row has surplus")
    func theTradeIsExplicit() {
        let roomy = sizedColumns(viewport: viewport(window: 1180, sidebar: 210))[0].width
        let tight = sizedColumns(viewport: viewport(window: 1180, sidebar: 299))[0].width
        #expect(roomy > 430, "a default sidebar leaves surplus, so 名前 exceeds 430pt")
        #expect(tight < 430, "a 299pt sidebar cannot fit 430pt without a scroller")
        #expect(tight >= 220)
    }

    @Test("the fixed columns keep their authored widths")
    func fixedColumnsAreUntouched() {
        let sized = sizedColumns(viewport: viewport(window: 1180, sidebar: 299))
        #expect(sized[1].width == 175, "変更日")
        #expect(sized[2].width == 100, "サイズ")
        #expect(sized[3].width == 145, "種類")
    }

    @Test("名前 stops at its minimum rather than collapsing or going negative")
    func nameRespectsItsMinimum() {
        // The tightest reachable layout: smallest window, widest sidebar.
        let sized = sizedColumns(viewport: viewport(window: 820, sidebar: 360))
        #expect(sized[0].width == 220)
    }

    @Test("a real table lays out without horizontal overflow at the reported size")
    func liveTableDoesNotOverflow() {
        let width = viewport(window: 1180, sidebar: 299)
        let table = NSTableView()
        sizedColumns(viewport: width).forEach(table.addTableColumn)
        table.columnAutoresizingStyle = Browser.fileColumnAutoresizing

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.layoutSubtreeIfNeeded()

        #expect(
            table.frame.width <= width + 0.5,
            "table wants \(table.frame.width)pt inside a \(width)pt list"
        )
    }
}
