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

    @Test("Return renames and Space opens Quick Look in every browser mode")
    func finderKeyboardActions() {
        #expect(FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: "\r",
            modifierFlags: []
        ) == .rename)
        #expect(FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: "\u{3}",
            modifierFlags: [.numericPad]
        ) == .rename)
        #expect(FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: " ",
            modifierFlags: []
        ) == .quickLook)
        #expect(FinderLikeBrowserKeyboard.action(
            charactersIgnoringModifiers: "\r",
            modifierFlags: [.command]
        ) == .forwardToAppKit)
    }

    @Test("the inline editor really gains focus, selects the basename, and commits Return")
    func inlineEditorFocusAndCommit() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = FinderInlineRenameField(frame: NSRect(x: 20, y: 30, width: 280, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var committed: String?
        field.show("設計書.final.pdf")

        field.beginEditing(name: field.stringValue, isDirectory: false) {
            committed = $0
        }

        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(field.isRenaming)
        #expect(editor.selectedRange() == NSRange(
            location: 0,
            length: ("設計書.final" as NSString).length
        ))
        field.stringValue = "新しい名前.pdf"
        #expect(field.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(!field.isRenaming)
        #expect(committed == "新しい名前.pdf")
    }

    @Test("Escape cancels inline rename without changing the item")
    func inlineEditorEscapeCancels() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = FinderInlineRenameField(frame: NSRect(x: 20, y: 30, width: 280, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var commitCount = 0
        field.show("元の名前")
        field.beginEditing(name: field.stringValue, isDirectory: true) { _ in
            commitCount += 1
        }
        let editor = try #require(field.currentEditor() as? NSTextView)
        field.stringValue = "変更途中"

        #expect(field.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(!field.isRenaming)
        #expect(field.stringValue == "元の名前")
        #expect(commitCount == 0)
    }

}
