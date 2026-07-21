import AppKit
@testable import FinderAIApp
import Testing

@Suite("Finder-like inline rename")
@MainActor
struct FinderInlineRenameTests {
    @Test("only a plain click on the already selected name can request rename")
    func renameGestureRequiresAnExistingSingleSelection() {
        #expect(FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: true,
            selectionCount: 1,
            clickCount: 1,
            modifierFlags: [],
            hitName: true
        ))
        #expect(!FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: false,
            selectionCount: 1,
            clickCount: 1,
            modifierFlags: [],
            hitName: true
        ))
        #expect(!FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: true,
            selectionCount: 2,
            clickCount: 1,
            modifierFlags: [],
            hitName: true
        ))
        #expect(!FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: true,
            selectionCount: 1,
            clickCount: 1,
            modifierFlags: [.shift],
            hitName: true
        ))
        #expect(!FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: true,
            selectionCount: 1,
            clickCount: 1,
            modifierFlags: [],
            hitName: false
        ))
    }

    @Test("the second event of a double-click remains an open action")
    func doubleClickDoesNotRequestRename() {
        #expect(!FinderLikeRenameGesture.permitsRename(
            wasSelectedBeforeClick: true,
            selectionCount: 1,
            clickCount: 2,
            modifierFlags: [],
            hitName: true
        ))
    }

    @Test("file rename selects the basename while folders select the whole name")
    func renameSelectionProtectsTheExtension() {
        #expect(FinderInlineRenameField.renameSelectionRange(
            for: "設計書.final.pdf",
            isDirectory: false
        ) == NSRange(location: 0, length: ("設計書.final" as NSString).length))
        #expect(FinderInlineRenameField.renameSelectionRange(
            for: "Folder.with.dots",
            isDirectory: true
        ) == NSRange(location: 0, length: ("Folder.with.dots" as NSString).length))
        #expect(FinderInlineRenameField.renameSelectionRange(
            for: ".gitignore",
            isDirectory: false
        ) == NSRange(location: 0, length: (".gitignore" as NSString).length))
    }

}
