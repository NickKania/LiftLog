import SwiftUI
import WatchKit

struct WatchAdjustView: View {
    let client: WatchSessionClient
    let workoutID: UUID
    let exerciseName: String
    let set: WatchSetState
    @State private var reps: Double
    @State private var weight: Double
    @State private var adjustsWeight = false
    @FocusState private var crownFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(client: WatchSessionClient, workoutID: UUID, exerciseName: String, set: WatchSetState) {
        self.client = client
        self.workoutID = workoutID
        self.exerciseName = exerciseName
        self.set = set
        _reps = State(initialValue: max(0, Double(set.reps)))
        _weight = State(initialValue: set.weight)
    }

    private var maximumReps: Double { max(200, Double(set.reps)) }
    private var maximumWeight: Double { max(2000, set.weight) }
    private var weightStep: Double { client.state.unitRaw == "kg" ? 1 : 2.5 }
    private var crownValue: Binding<Double> {
        Binding(get: { adjustsWeight ? weight : reps }, set: { value in
            if adjustsWeight { weight = value } else { reps = value.rounded() }
        })
    }

    var body: some View {
        WatchPage(showsPages: false) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        adjustsWeight = false
                        crownFocused = true
                    } label: {
                        Text("\(Int(reps)) reps").font(.title2).foregroundStyle(adjustsWeight ? .white : .green)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Reps")
                    .accessibilityValue("\(Int(reps))")
                    .accessibilityHint("Turn Digital Crown to adjust reps")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: reps = min(maximumReps, reps + 1)
                        case .decrement: reps = max(0, reps - 1)
                        @unknown default: break
                        }
                    }
                    Button {
                        adjustsWeight = true
                        crownFocused = true
                    } label: {
                        Text("\(WatchPresentation.number(weight)) \(client.state.unitRaw)")
                            .foregroundStyle(adjustsWeight ? .green : .white)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Weight")
                    .accessibilityValue("\(WatchPresentation.number(weight)) \(client.state.unitRaw)")
                    .accessibilityHint("Tap to adjust weight with Digital Crown")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: weight = min(maximumWeight, weight + weightStep)
                        case .decrement: weight = max(0, weight - weightStep)
                        @unknown default: break
                        }
                    }
                }
                if reps < 1 {
                    Text("Reps must be greater than zero.").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("Crown changes \(adjustsWeight ? "weight" : "reps")").font(.caption2).foregroundStyle(.secondary)
                }
                Text("Target \(WatchPresentation.number(set.targetWeight ?? set.weight)) × \(set.targetReps ?? set.reps)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } actions: {
            VStack(spacing: 4) {
                Button("Log Set") {
                    guard client.state.active?.id == workoutID,
                          client.state.active?.nextIncompleteSet?.set.id == set.id else { dismiss(); return }
                    if client.send(.completeSet(setID: set.id, weight: weight, reps: Int(reps))) {
                        WKInterfaceDevice.current().play(.success)
                        dismiss()
                    }
                }
                .buttonStyle(WatchPill())
                .disabled(reps < 1)
                .accessibilityIdentifier("watchCompleteSetButton")
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(WatchPill(color: .white.opacity(0.12), foreground: .white))
            }
        }
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(crownValue, from: 0, through: adjustsWeight ? maximumWeight : maximumReps,
                              by: adjustsWeight ? weightStep : 1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear {
            crownFocused = true
            #if DEBUG
            if WatchPreviewFixture.screen == "adjust-invalid" { reps = 0 }
            #endif
        }
        .navigationTitle(exerciseName)
    }
}
