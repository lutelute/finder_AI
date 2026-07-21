import AppKit

/// The small bit of policy behind Finder's rename gesture.
///
/// A name may be edited only when it was already the sole selection before this
/// click. The first click therefore selects, a later click starts editing, and a
/// double-click remains available for opening the item.
enum FinderLikeRenameGesture {
    static func permitsRename(
        wasSelectedBeforeClick: Bool,
        selectionCount: Int,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags,
        hitName: Bool
    ) -> Bool {
        let selectionModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        return wasSelectedBeforeClick
            && selectionCount == 1
            && clickCount == 1
            && modifierFlags.intersection(selectionModifiers).isEmpty
            && hitName
    }
}

/// Finder reserves Return for renaming the current item. Opening stays on a
/// double-click or Command-Down, while Space keeps Quick Look. Keeping this
/// policy in one place prevents list, column, and gallery from drifting apart.
enum FinderLikeBrowserKeyAction: Equatable {
    case rename
    case quickLook
    case forwardToAppKit
}

enum FinderLikeBrowserKeyboard {
    static func action(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> FinderLikeBrowserKeyAction {
        let commandModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        guard modifierFlags.intersection(commandModifiers).isEmpty else {
            return .forwardToAppKit
        }
        switch charactersIgnoringModifiers {
        case "\r", "\u{3}":
            return .rename
        case " ":
            return .quickLook
        default:
            return .forwardToAppKit
        }
    }
}

/// Delays a potential rename by the system double-click interval. If another
/// click arrives, views cancel this work and AppKit gets to perform its normal
/// double-click action instead.
@MainActor
final class FinderLikeRenameScheduler {
    private var pending: DispatchWorkItem?

    func schedule(_ action: @escaping @MainActor () -> Void) {
        cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval,
            execute: work
        )
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// A label at rest and a native text editor while renaming. All three browser
/// modes use this field so Return, Escape, focus loss, and extension selection
/// behave consistently.
@MainActor
final class FinderInlineRenameField: NSTextField, NSTextFieldDelegate {
    private var displayedValue = ""
    private var editingValue = ""
    private var restingTextColor: NSColor?
    private var finishHandler: ((String) -> Void)?
    private(set) var isRenaming = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        lineBreakMode = .byTruncatingMiddle
        setLabelAppearance()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ value: String) {
        cancelEditing()
        displayedValue = value
        stringValue = value
        toolTip = value
    }

    func beginEditing(
        name: String,
        isDirectory: Bool,
        onCommit: @escaping (String) -> Void
    ) {
        guard !isRenaming else { return }
        displayedValue = stringValue
        editingValue = name
        restingTextColor = textColor
        finishHandler = onCommit
        isRenaming = true
        stringValue = name
        toolTip = nil
        isEditable = true
        isSelectable = true
        isBordered = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        focusRingType = .default
        lineBreakMode = .byClipping

        guard window?.makeFirstResponder(self) == true else {
            cancelEditing()
            return
        }
        currentEditor()?.selectedRange = Self.renameSelectionRange(
            for: name,
            isDirectory: isDirectory
        )
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true, restoreBrowserFocus: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false, restoreBrowserFocus: true)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing(commit: true, restoreBrowserFocus: false)
    }

    private func finishEditing(commit: Bool, restoreBrowserFocus: Bool) {
        guard isRenaming else { return }
        let proposedName = stringValue
        let oldDisplay = displayedValue
        let handler = finishHandler
        isRenaming = false
        finishHandler = nil
        stringValue = oldDisplay
        toolTip = oldDisplay
        setLabelAppearance()
        if restoreBrowserFocus {
            window?.makeFirstResponder(nearestBrowserView())
        }

        if commit, proposedName != editingValue {
            handler?(proposedName)
        }
    }

    private func cancelEditing() {
        guard isRenaming else { return }
        isRenaming = false
        finishHandler = nil
        stringValue = displayedValue
        toolTip = displayedValue
        setLabelAppearance()
    }

    private func setLabelAppearance() {
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        if let restingTextColor { textColor = restingTextColor }
        focusRingType = .none
        lineBreakMode = .byTruncatingMiddle
    }

    private func nearestBrowserView() -> NSView? {
        var candidate = superview
        while let view = candidate {
            if view is NSTableView || view is NSCollectionView { return view }
            candidate = view.superview
        }
        return superview
    }

    static func renameSelectionRange(for name: String, isDirectory: Bool) -> NSRange {
        let fullLength = (name as NSString).length
        guard !isDirectory else { return NSRange(location: 0, length: fullLength) }
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else {
            return NSRange(location: 0, length: fullLength)
        }
        return NSRange(
            location: 0,
            length: max(0, fullLength - (pathExtension as NSString).length - 1)
        )
    }
}
