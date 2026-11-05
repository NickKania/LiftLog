import XCTest
import UIKit
@testable import LiftLog

final class AssistantRequestActivityTests: XCTestCase {
    @MainActor
    func testCompletionEndsActivityOnceAndIgnoresLateExpiration() {
        var expiration: (@MainActor () -> Void)?
        var expirations = 0
        var ended: [UIBackgroundTaskIdentifier] = []
        let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
        let activity = AssistantRequestActivity(onExpiration: { expirations += 1 }, end: { ended.append($0) })
        activity.start { expiration = $0; return identifier }
        activity.start { _ in XCTFail("An activity must not be started twice"); return .invalid }
        activity.finish()
        activity.finish()
        expiration?()
        XCTAssertEqual(ended, [identifier])
        XCTAssertEqual(expirations, 0)
    }

    @MainActor
    func testExpirationInterruptsThenEndsActivityOnce() {
        var expiration: (@MainActor () -> Void)?
        var events: [String] = []
        let activity = AssistantRequestActivity(onExpiration: { events.append("interrupted") }, end: { _ in events.append("ended") })
        activity.start { expiration = $0; return UIBackgroundTaskIdentifier(rawValue: 42) }
        expiration?()
        expiration?()
        activity.finish()
        XCTAssertEqual(events, ["interrupted", "ended"])
    }

    @MainActor
    func testDeniedActivityDoesNotCancelForegroundRequestOrEndInvalidIdentifier() {
        let activity = AssistantRequestActivity(onExpiration: { XCTFail("No allowance was granted") },
            end: { _ in XCTFail("There is no activity to end") })
        activity.start { _ in .invalid }
        activity.finish()
    }
}
