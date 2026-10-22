import SwiftUI
import WatchKit

struct WatchNowView: View {
    @Environment(\.watchCompactLayout) private var compactLayout
    let client: WatchSessionClient
    let workout: WatchActiveWorkout
    @State private var adjustingSet: WatchSetState?

    private var completedPreviousExercise: WatchExerciseState? {
        guard let next = workout.nextIncompleteSet, next.exerciseIndex > 0, next.setIndex == 0 else { return nil }
        let previous = workout.exercises[next.exerciseIndex - 1]
        return !previous.sets.isEmpty && previous.sets.allSatisfy(\.isCompleted) ? previous : nil
    }

    private var showsChip: Bool {
        guard let next = workout.nextIncompleteSet else { return false }
        return completedPreviousExercise != nil || workout.exercises[next.exerciseIndex].supersetID != nil
    }

    var body: some View {
        WatchPage {
            VStack(spacing: 4) {
                WatchRing(fraction: Double(workout.completedSets) / Double(max(1, workout.totalSets)), size: showsChip ? 42 : 64) {
                    VStack(spacing: 1) {
                        Text("\(workout.completedSets)/\(workout.totalSets)").font(compactLayout || showsChip ? .caption : .headline)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        if completedPreviousExercise == nil {
                            WatchElapsed(startedAt: workout.startedAt).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.5)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(workout.completedSets) of \(workout.totalSets) sets complete")
                if let next = workout.nextIncompleteSet {
                    let exercise = workout.exercises[next.exerciseIndex]
                    if let previous = completedPreviousExercise {
                        Label("\(previous.name) complete", systemImage: "checkmark")
                            .font(.caption2).foregroundStyle(.green)
                    }
                    if let label = WatchPresentation.supersetLabel(for: exercise, in: workout) {
                        Label(label, systemImage: "link").font(.caption2).foregroundStyle(.cyan)
                    }
                    Button {
                        adjustingSet = next.set
                    } label: {
                        VStack(spacing: 2) {
                            Text(exercise.name).font(.headline)
                            Text("\(WatchPresentation.prescription(next.set, unit: client.state.unitRaw)) · Set \(next.setIndex + 1)/\(exercise.sets.count)")
                                .font(.caption)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Adjust \(exercise.name), \(WatchPresentation.prescription(next.set, unit: client.state.unitRaw)), set \(next.setIndex + 1) of \(exercise.sets.count)")
                    .accessibilityIdentifier("watchAdjustButton")
                } else if workout.exercises.isEmpty || workout.totalSets == 0 {
                    Text("Add exercises on iPhone").font(.headline).multilineTextAlignment(.center)
                } else {
                    Label("All sets complete", systemImage: "checkmark").font(.headline)
                    Text("Swipe to Summary to save.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } actions: {
            if let next = workout.nextIncompleteSet {
                Button {
                    if client.completeSet(setID: next.set.id, weight: next.set.weight, reps: next.set.reps) {
                        WKInterfaceDevice.current().play(.success)
                    }
                } label: {
                    Text(workout.restSeconds > 0 && workout.completedSets + 1 < workout.totalSets ? "Done — Start Rest" : "Done")
                }
                .buttonStyle(WatchPill())
                .accessibilityIdentifier("watchCompleteSetButton")
            }
        }
        .sheet(item: $adjustingSet) { set in
            if let next = workout.nextIncompleteSet, next.set.id == set.id {
                WatchAdjustView(client: client, workoutID: workout.id,
                                exerciseName: workout.exercises[next.exerciseIndex].name, set: set)
            }
        }
        .onChange(of: workout.nextIncompleteSet?.set.id) { _, id in
            if adjustingSet?.id != id { adjustingSet = nil }
        }
        .onAppear {
            #if DEBUG
            if ["adjust", "adjust-invalid"].contains(WatchPreviewFixture.screen) { adjustingSet = workout.nextIncompleteSet?.set }
            #endif
        }
    }
}
