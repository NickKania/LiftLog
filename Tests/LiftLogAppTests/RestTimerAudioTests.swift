import AVFoundation
import XCTest
@testable import LiftLog

final class RestTimerAudioTests: XCTestCase {
    @MainActor
    func testBundledChimePlaysToCompletion() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: RestTimerSoundPlayer.resourceName, withExtension: nil))
        let asset = try AVAudioPlayer(contentsOf: url)
        XCTAssertGreaterThan(asset.duration, 0.5)
        XCTAssertLessThan(asset.duration, 30, "The same chime must be valid as a notification sound")

        let sound = RestTimerSoundPlayer()
        try sound.play()
        XCTAssertTrue(sound.isPlaying, "The player must remain alive for the entire chime")
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(sound.isPlaying)
    }

    @MainActor
    func testRestExpiryUsesNormalAudioPlaybackAndMixesWithMusic() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.soloAmbient)
        let alerts = RestTimerAlerts()
        defer { alerts.synchronize(nil) }
        alerts.synchronize(WorkoutRestTimer(completedSetID: UUID(), endsAt: Date().addingTimeInterval(0.2)))
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(session.category, .playback, "Rest chimes must use media volume and play in silent mode")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers), "Rest chimes must preserve other apps' music")
    }

    @MainActor
    func testReturningAfterForegroundExpiryDoesNotRepeatChime() async throws {
        var playCount = 0
        let alerts = RestTimerAlerts(playSound: { playCount += 1 })
        defer { alerts.synchronize(nil) }
        alerts.synchronize(WorkoutRestTimer(completedSetID: UUID(), endsAt: Date().addingTimeInterval(0.1)))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(playCount, 1)

        alerts.setActive(false)
        alerts.setActive(true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(playCount, 1)
    }

    @MainActor
    func testSkippingRestCancelsChime() async throws {
        var playCount = 0
        let alerts = RestTimerAlerts(playSound: { playCount += 1 })
        alerts.synchronize(WorkoutRestTimer(completedSetID: UUID(), endsAt: Date().addingTimeInterval(0.1)))
        alerts.synchronize(nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(playCount, 0)
    }

    @MainActor
    func testFailedPlaybackCanRetryOnReturn() async throws {
        var attempts = 0
        let alerts = RestTimerAlerts(playSound: {
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadUnknown) }
        })
        defer { alerts.synchronize(nil) }
        alerts.synchronize(WorkoutRestTimer(completedSetID: UUID(), endsAt: Date().addingTimeInterval(0.1)))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(attempts, 1)

        alerts.setActive(false)
        alerts.setActive(true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(attempts, 2, "A failed playback must not mark the rest alert as delivered")
    }
}
