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
                WatchRing(fraction: endsAt.timeIntervalSince(now) / Double(max(1, workout.restSeconds)), color: .orange, size: 60) {
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
                    if let id = workout.restTimerID {
                        client.send(.extendRest(workoutID: workout.id, restTimerID: id, seconds: 30))
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

struct WatchRestDoneView: View {
    let client: WatchSessionClient
    let workout: WatchActiveWorkout

    var body: some View {
        WatchPage {
            VStack(spacing: 4) {
                Label("Rest complete", systemImage: "bell.badge.fill").font(.headline).foregroundStyle(.green)
                WatchNextSetLabel(workout: workout, unit: client.state.unitRaw)
            }
            .multilineTextAlignment(.center)
        } actions: {
            VStack(spacing: 4) {
                Button("Go — Set \((workout.nextIncompleteSet?.setIndex ?? 0) + 1)") {
                    if let id = workout.restTimerID {
                        client.send(.skipRest(workoutID: workout.id, restTimerID: id))
                    }
                }
                .buttonStyle(WatchPill())
                .disabled(workout.restTimerID == nil)
                .accessibilityIdentifier("watchSkipRestButton")
                Button("+0:30 Rest") {
                    if let id = workout.restTimerID {
                        client.send(.extendRest(workoutID: workout.id, restTimerID: id, seconds: 30))
                    }
                }
                .buttonStyle(WatchPill(color: .white.opacity(0.12), foreground: .white))
                .disabled(workout.restTimerID == nil)
                .accessibilityIdentifier("watchExtendRestButton")
            }
        }
    }
}
