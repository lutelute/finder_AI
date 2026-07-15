import Foundation
import FinderAICore

@MainActor
protocol FinderTracking: AnyObject {
    var state: FinderTrackingState { get }
    var onStateChange: ((FinderTrackingState) -> Void)? { get set }

    func start(promptForPermission: Bool)
    func recheckPermission(prompt: Bool)
    func refresh()
    func stop()
}
