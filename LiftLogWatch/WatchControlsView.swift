import SwiftUI

struct WatchControlsView: View {
    @Environment(\.watchCompactLayout) private var compactLayout
    let client: WatchSessionClient
    let workout: WatchActiveWorkout
    @State private var confirmingFinish = false
    @State private var confirmingDiscard = false

    var body: some View {
        WatchPage {
            stats
        } actions: {
            VStack(spacing: 4) {
                Button("Finish…") { confirmingFinish = true }
                    .buttonStyle(WatchPill(color: workout.canFinish ? .green : .gray))
                    .disabled(!workout.canFinish)
                    .accessibilityIdentifier("watchFinishButton")
                Button("Discard…", role: .destructive) { confirmingDiscard = true }
                    .buttonStyle(WatchPill(color: .white.opacity(0.12), foreground: .red))
                    .accessibilityIdentifier("watchDiscardButton")
            }
        }
        .sheet(isPresented: $confirmingFinish) {
            WatchPage(showsPages: false) {
                VStack(spacing: compactLayout ? 0 : 4) {
                    Text("Finish \(workout.name)?").font(.headline)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            WatchElapsed(startedAt: workout.startedAt)
                            Text("· \(workout.completedSets) sets · \(WatchPresentation.volume(workout, unit: client.state.unitRaw))")
                        }
                        .fixedSize()
                        VStack(spacing: 2) {
                            WatchElapsed(startedAt: workout.startedAt)
                            Text("\(workout.completedSets) sets · \(WatchPresentation.volume(workout, unit: client.state.unitRaw))")
                        }
                    }
                    .font(.caption2)
                    Text("Only completed sets are saved.").font(compactLayout ? .caption2 : .caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            } actions: {
                VStack(spacing: 4) {
                    Button("Save Workout") {
                        if client.send(.finish(workoutID: workout.id)) { confirmingFinish = false }
                    }
                    .buttonStyle(WatchPill())
                    .accessibilityIdentifier("watchSaveWorkoutButton")
                    Button("Keep Training", role: .cancel) { confirmingFinish = false }
                        .buttonStyle(WatchPill(color: .white.opacity(0.12), foreground: .white))
                }
            }
        }
        .confirmationDialog("Discard workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) { client.send(.discard(workoutID: workout.id)) }
            Button("Keep Training", role: .cancel) { }
        } message: {
            Text("This workout and all of its logged sets will be deleted.")
        }
        .onAppear {
            #if DEBUG
            confirmingFinish = WatchPreviewFixture.screen == "finish"
            confirmingDiscard = WatchPreviewFixture.screen == "discard"
            #endif
        }
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Elapsed") { WatchElapsed(startedAt: workout.startedAt) }
            LabeledContent("Sets", value: "\(workout.completedSets)/\(workout.totalSets)")
            LabeledContent("Volume", value: WatchPresentation.volume(workout, unit: client.state.unitRaw))
        }
        .font(.caption2)
    }
}
