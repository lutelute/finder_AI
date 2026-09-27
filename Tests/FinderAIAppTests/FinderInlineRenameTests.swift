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

    @Test("the caret stays in view while moving through a name wider than the field")
    func inlineEditorKeepsCaretVisibleInLongName() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // 欄は120pt。名前はその何倍も長い。
        let field = FinderInlineRenameField(frame: NSRect(x: 20, y: 30, width: 120, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let name = String(repeating: "とても長いファイル名", count: 4) + ".pdf"
        field.show(name)
        field.beginEditing(name: name, isDirectory: false) { _ in }
        let editor = try #require(field.currentEditor() as? NSTextView)

        // 選択を解いて右へ進み、末尾まで行く。Finderと同じ動きをそのまま撃つ。
        editor.moveRight(nil)
        for _ in 0..<8 { editor.moveRight(nil) }
        #expect(Self.caretIsInside(field, editor: editor), "右へ数歩でカーソルが欄の外へ出た")
        editor.moveToEndOfDocument(nil)
        #expect(Self.caretIsInside(field, editor: editor), "末尾でカーソルが欄の外へ出た")
        editor.moveToBeginningOfDocument(nil)
        #expect(Self.caretIsInside(field, editor: editor), "先頭へ戻ってもカーソルが欄の外のまま")

        // 編集をやめたら、字送りは外れて中ほどを省くラベルに戻る。
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(field.cell?.isScrollable == false)
        #expect(field.lineBreakMode == .byTruncatingMiddle)
    }

    /// 挿入点の画面上の位置を欄の座標へ戻し、欄の中にあるかを見る。
    /// 字送り（スクロール）が効いていれば、どこへ動いても中に収まる。
    private static func caretIsInside(_ field: NSTextField, editor: NSTextView) -> Bool {
        let range = NSRange(location: editor.selectedRange().location, length: 0)
        let screenRect = editor.firstRect(forCharacterRange: range, actualRange: nil)
        guard let window = field.window else { return false }
        let inWindow = window.convertFromScreen(screenRect)
        let inField = field.convert(inWindow, from: nil)
        return field.bounds.insetBy(dx: -1, dy: -1).contains(NSPoint(x: inField.midX, y: inField.midY))
    }

}
