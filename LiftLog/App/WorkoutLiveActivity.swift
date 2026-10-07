import ActivityKit
import OSLog
import UIKit

/// Serializes updates so finishing, restoring, or quickly completing sets cannot
/// leave an older update on the Lock Screen. The persisted workout is authoritative.
@MainActor
final class WorkoutLiveActivity {
    private var desired: WorkoutActivitySnapshot?
    private var isActive = false
    private var revision = 0
    private var synchronizationTask: Task<Void, Never>?
    private var activity: Activity<WorkoutActivityAttributes>?
    private var observedWorkoutID: UUID?
    private var dismissedWorkoutID: UUID?
    private let defaults = UserDefaults.standard
    private let requestedWorkoutKey = "liveActivity.requestedWorkoutID"
    private let logger = Logger(subsystem: "nkania.WeightsTracker", category: "LiveActivity")

    func synchronize(_ snapshot: WorkoutActivitySnapshot?, isActive: Bool) {
        desired = snapshot
        self.isActive = isActive
        revision += 1
        guard synchronizationTask == nil else { return }
        synchronizationTask = Task {
            // Keep in-flight ActivityKit updates alive when the phone locks.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Workout Live Activity")
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                synchronizationTask = nil
            }
            while true {
                let currentRevision = revision
                await reconcile()
                if currentRevision == revision { return }
            }
        }
    }

    private func reconcile() async {
        let snapshot = desired
        let workoutID = snapshot?.workoutID
        if observedWorkoutID != workoutID {
            observedWorkoutID = workoutID
            dismissedWorkoutID = nil
        }

        if let activity, activity.attributes.workoutID == workoutID,
           activity.activityState == .dismissed || activity.activityState == .ended {
            dismissedWorkoutID = workoutID
            self.activity = nil
        }

        let existing = Activity<WorkoutActivityAttributes>.activities
        var matching = activity.flatMap { $0.attributes.workoutID == workoutID ? $0 : nil }
        for candidate in existing {
            if candidate.attributes.workoutID == workoutID,
               matching == nil, candidate.activityState == .active || candidate.activityState == .stale {
                matching = candidate
            } else if candidate.id != matching?.id {
                await candidate.end(nil, dismissalPolicy: .immediate)
            }
        }
        if let activity, activity.attributes.workoutID != workoutID,
           !existing.contains(where: { $0.id == activity.id }) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = matching

        guard let snapshot else {
            defaults.removeObject(forKey: requestedWorkoutKey)
            return
        }
        let content = ActivityContent(state: snapshot, staleDate: nil)
        if let matching {
            if matching.content.state != snapshot { await matching.update(content) }
        } else if isActive, dismissedWorkoutID != workoutID,
                  defaults.string(forKey: requestedWorkoutKey) != snapshot.workoutID.uuidString,
                  ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: WorkoutActivityAttributes(workoutID: snapshot.workoutID),
                                                content: content, pushType: nil)
                // If iOS or the person removes this activity, relaunching the
                // app must not immediately recreate it for the same workout.
                defaults.set(snapshot.workoutID.uuidString, forKey: requestedWorkoutKey)
            } catch {
                // Live Activity permission or availability must never block logging.
                logger.warning("Could not start workout Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
