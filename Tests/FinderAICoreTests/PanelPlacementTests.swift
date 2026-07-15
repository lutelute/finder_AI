import CoreGraphics
import Testing
@testable import FinderAICore

private let testScreen = ScreenGeometry(
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
    primaryScreenMaxY: 900
)

@Test func collapsedDrawerLivesInsideBottomOfFinder() throws {
    let result = try #require(PanelPlacementCalculator.placement(
        finderAXFrame: CGRect(x: 100, y: 100, width: 900, height: 600),
        screen: testScreen,
        isExpanded: false,
        requestedExpandedHeight: 280
    ))

    #expect(result.frame == CGRect(x: 100, y: 200, width: 900, height: 34))
}

@Test func expandedHeightNeverFallsBelowDocumentedMinimum() throws {
    let result = try #require(PanelPlacementCalculator.placement(
        finderAXFrame: CGRect(x: 100, y: 100, width: 600, height: 210),
        screen: testScreen,
        isExpanded: true,
        requestedExpandedHeight: 600
    ))

    #expect(result.frame.height == 160)
    #expect(result.effectiveExpandedHeight == 160)
}

@Test func finderTooShortForMinimumExpandedHeightFailsClosed() {
    #expect(PanelPlacementCalculator.placement(
        finderAXFrame: CGRect(x: 100, y: 100, width: 600, height: 150),
        screen: testScreen,
        isExpanded: true,
        requestedExpandedHeight: 280
    ) == nil)
}

@Test func offscreenFinderIsClippedToVisibleScreen() throws {
    let result = try #require(PanelPlacementCalculator.placement(
        finderAXFrame: CGRect(x: -100, y: 100, width: 500, height: 400),
        screen: testScreen,
        isExpanded: false,
        requestedExpandedHeight: 280
    ))

    #expect(result.frame.minX == 0)
    #expect(result.frame.width == 400)
}

@Test func tinyFinderDoesNotProducePanel() {
    #expect(PanelPlacementCalculator.placement(
        finderAXFrame: CGRect(x: 0, y: 0, width: 50, height: 50),
        screen: testScreen,
        isExpanded: true,
        requestedExpandedHeight: 280
    ) == nil)
}

@Test func fullScreenHeuristicHidesScreenCoveringFinder() {
    #expect(PanelPlacementCalculator.isProbablyFullScreen(
        finderAXFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        primaryScreenMaxY: 900
    ))
}

@Test func fullScreenHeuristicKeepsOrdinaryMaximizedFinder() {
    #expect(!PanelPlacementCalculator.isProbablyFullScreen(
        finderAXFrame: CGRect(x: 0, y: 25, width: 1440, height: 875),
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        primaryScreenMaxY: 900
    ))
}
