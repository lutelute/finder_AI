import Foundation

public struct WorkspaceNavigator: Equatable, Sendable {
    public private(set) var currentDirectory: URL
    public private(set) var backHistory: [URL] = []
    public private(set) var forwardHistory: [URL] = []

    public init(initialDirectory: URL) {
        currentDirectory = initialDirectory.standardizedFileURL
    }

    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }
    public var canGoUp: Bool { currentDirectory.pathComponents.count > 1 }

    public mutating func navigate(to directory: URL) {
        let target = directory.standardizedFileURL
        guard target != currentDirectory else { return }
        backHistory.append(currentDirectory)
        if backHistory.count > 100 { backHistory.removeFirst(backHistory.count - 100) }
        currentDirectory = target
        forwardHistory.removeAll()
    }

    @discardableResult
    public mutating func goBack() -> URL? {
        guard let target = backHistory.popLast() else { return nil }
        forwardHistory.append(currentDirectory)
        currentDirectory = target
        return target
    }

    @discardableResult
    public mutating func goForward() -> URL? {
        guard let target = forwardHistory.popLast() else { return nil }
        backHistory.append(currentDirectory)
        currentDirectory = target
        return target
    }

    @discardableResult
    public mutating func goUp() -> URL? {
        guard canGoUp else { return nil }
        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
        navigate(to: parent)
        return parent
    }

    /// Keeps navigation valid when a displayed ancestor folder is renamed.
    /// History entries under that folder move with it as well; retaining their
    /// old paths would make Back or Forward lead to locations that no longer
    /// exist.
    @discardableResult
    public mutating func relocatePathPrefix(from source: URL, to destination: URL) -> Bool {
        let oldCurrent = currentDirectory
        currentDirectory = Self.replacingPathPrefix(
            in: currentDirectory,
            from: source,
            to: destination
        )
        backHistory = backHistory.map {
            Self.replacingPathPrefix(in: $0, from: source, to: destination)
        }
        forwardHistory = forwardHistory.map {
            Self.replacingPathPrefix(in: $0, from: source, to: destination)
        }
        return currentDirectory != oldCurrent
    }

    private static func replacingPathPrefix(
        in target: URL,
        from source: URL,
        to destination: URL
    ) -> URL {
        let targetComponents = target.standardizedFileURL.pathComponents
        let sourceComponents = source.standardizedFileURL.pathComponents
        guard targetComponents.starts(with: sourceComponents) else {
            return target.standardizedFileURL
        }
        return targetComponents.dropFirst(sourceComponents.count).reduce(
            destination.standardizedFileURL
        ) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.standardizedFileURL
    }
}

public enum WorkspaceNameValidator {
    public static func validated(_ proposedName: String) -> String? {
        guard !proposedName.isEmpty,
              !proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proposedName != ".",
              proposedName != "..",
              !proposedName.contains("/"),
              !proposedName.contains(":"),
              !proposedName.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        return proposedName
    }
}
