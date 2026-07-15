import FinderAICore

enum ControlCenterTone: Equatable {
    case attention
    case waiting
    case ready
}

struct ControlCenterPresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String
    let tone: ControlCenterTone
    let permissionButtonIsProminent: Bool
    let finderButtonIsEnabled: Bool

    static func shouldShowAutomatically(for state: FinderTrackingState) -> Bool {
        switch state {
        case .permissionRequired, .noFinderWindow:
            true
        case .hidden, .tracking:
            false
        }
    }

    static func make(for state: FinderTrackingState) -> Self {
        switch state {
        case .permissionRequired:
            return Self(
                title: "初期設定が必要です",
                detail: "AccessibilityでFinderAIをONにすると、前面のFinder下部へTerminalハンドルを表示できます。要求する権限はこれだけです。",
                symbolName: "exclamationmark.shield.fill",
                tone: .attention,
                permissionButtonIsProminent: true,
                finderButtonIsEnabled: false
            )
        case .noFinderWindow:
            return Self(
                title: "Finderウインドウを開いてください",
                detail: "権限は利用できます。下のボタンからFinderを開くと、ウインドウ下部にTerminalハンドルが現れます。",
                symbolName: "folder.fill.badge.questionmark",
                tone: .waiting,
                permissionButtonIsProminent: false,
                finderButtonIsEnabled: true
            )
        case .hidden:
            return Self(
                title: "Finderを前面にすると準備完了です",
                detail: "FinderAIは別アプリの上に残らないよう待機しています。「Finderで使い始める」を押してください。",
                symbolName: "rectangle.on.rectangle",
                tone: .waiting,
                permissionButtonIsProminent: false,
                finderButtonIsEnabled: true
            )
        case .tracking(let snapshot):
            let path = snapshot.folderURL.path(percentEncoded: false)
            return Self(
                title: "準備完了",
                detail: "追跡中: \(path)\nFinder下部の「TERMINAL」バーまたは⌃⌥Spaceで開閉できます。",
                symbolName: "checkmark.circle.fill",
                tone: .ready,
                permissionButtonIsProminent: false,
                finderButtonIsEnabled: true
            )
        }
    }
}
