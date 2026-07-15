import FinderAICore
import Foundation
@testable import FinderAIApp
import Testing

@Suite("Control center guidance")
struct ControlCenterPresentationTests {
    @Test("permission state has one clear primary action")
    func permissionGuidance() {
        let presentation = ControlCenterPresentation.make(for: .permissionRequired)
        #expect(presentation.tone == .attention)
        #expect(presentation.permissionButtonIsProminent)
        #expect(!presentation.finderButtonIsEnabled)
        #expect(presentation.title.contains("初期設定"))
    }

    @Test("Finder waiting states offer a usable next action")
    func finderGuidance() {
        let noWindow = ControlCenterPresentation.make(for: .noFinderWindow)
        let hidden = ControlCenterPresentation.make(for: .hidden)

        #expect(noWindow.finderButtonIsEnabled)
        #expect(hidden.finderButtonIsEnabled)
        #expect(noWindow.tone == .waiting)
        #expect(hidden.tone == .waiting)
    }

    @Test("tracking state explains the actual folder and shortcut")
    func readyGuidance() {
        let snapshot = FinderSnapshot(
            axFrame: .init(x: 10, y: 20, width: 800, height: 600),
            folderURL: URL(fileURLWithPath: "/tmp/日本語 folder", isDirectory: true)
        )
        let presentation = ControlCenterPresentation.make(for: .tracking(snapshot))

        #expect(presentation.tone == .ready)
        #expect(presentation.finderButtonIsEnabled)
        #expect(presentation.detail.contains("/tmp/日本語 folder"))
        #expect(presentation.detail.contains("⌃⌥Space"))
    }

    @Test("control center only interrupts when setup needs an action")
    func automaticVisibility() {
        let snapshot = FinderSnapshot(
            axFrame: .init(x: 10, y: 20, width: 800, height: 600),
            folderURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        #expect(ControlCenterPresentation.shouldShowAutomatically(for: .permissionRequired))
        #expect(ControlCenterPresentation.shouldShowAutomatically(for: .noFinderWindow))
        #expect(!ControlCenterPresentation.shouldShowAutomatically(for: .hidden))
        #expect(!ControlCenterPresentation.shouldShowAutomatically(for: .tracking(snapshot)))
    }
}
