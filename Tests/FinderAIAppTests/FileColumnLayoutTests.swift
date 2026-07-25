import AppKit
import Testing

@testable import FinderAIApp

/// The authored widths add up to 850pt and the gutters add 68 more, which only
/// just fits beside a default sidebar. Widening the sidebar — an ordinary thing
/// to do — pushed the total past the viewport, and because the slack went to the
/// *last* column the list showed a permanent horizontal scroller while long file
/// names truncated and 種類 ("PPTX ファイル") sat on empty space.
///
/// AppKit's autoresizing does not fix this on its own: it redistributes width
/// only when a table is resized, never on the first layout, and it never shrinks
/// a column below its authored width. 名前 therefore gets sized explicitly.
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
