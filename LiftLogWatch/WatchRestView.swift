import SwiftUI

struct WatchRestView: View {
    @Environment(\.watchCompactLayout) private var compactLayout
    let client: WatchSessionClient
    let workout: WatchActiveWorkout
    let now: Date
    let endsAt: Date

    var body: some View {
        WatchPage {
            VStack(spacing: 8) {
                WatchRing(fraction: endsAt.timeIntervalSince(now) / Double(max(1, workout.restDurationSeconds ?? workout.restSeconds)), color: .orange, size: 60) {
                    VStack(spacing: 1) {
                        Text(WatchPresentation.remaining(endsAt, at: now)).font(.system(compactLayout ? .caption : .title3, design: .rounded, weight: .bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("REST").font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rest remaining")
                .accessibilityValue(WatchPresentation.remaining(endsAt, at: now))
                WatchNextSetLabel(workout: workout, unit: client.state.unitRaw, prefix: "Next: ")
            }
        } actions: {
            HStack(spacing: 6) {
                Button("+30s") {
                    if let action = client.state.restExtensionAction(by: 30, at: Date(), newTimerID: UUID()) {
                        client.send(action)
                    }
                }
                .buttonStyle(WatchPill(color: .gray))
                .disabled(workout.restTimerID == nil)
                .accessibilityIdentifier("watchExtendRestButton")
                Button("Skip") {
                    if let id = workout.restTimerID {
                        client.send(.skipRest(workoutID: workout.id, restTimerID: id))
                    }
                }
                .buttonStyle(WatchPill(color: .orange))
                .disabled(workout.restTimerID == nil)
                .accessibilityIdentifier("watchSkipRestButton")
            }
        }
    }
}
