import SwiftUI

/// Text stays local while a number is incomplete, so typing a decimal never resets the field.
struct SetInputRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let number: Int
    let unit: WeightUnit
    let weight: Double
    let reps: Int
    var repsTitle = "Reps"
    var targetReps: Int? = nil
    var targetWeight: Double? = nil
    var completed: Bool? = nil
    let onChange: (Double, Int) -> Void
    var onCompletion: (() -> Void)? = nil
    var onValidity: ((Bool) -> Void)? = nil
    var isMarkedForHeartRate = false
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var onToggleHeartRateMark: (() -> Void)? = nil
    var onStartSetTimer: (() -> Void)? = nil
    var onCancelSetTimer: (() -> Void)? = nil
    @State private var weightText = ""
    @State private var repsText = ""
    @State private var initialized = false

    private var parsedWeight: Double? {
        SetInputValidation.weight(from: weightText)
    }
    private var parsedReps: Int? {
        SetInputValidation.reps(from: repsText)
    }
    private var valid: Bool { parsedWeight != nil && parsedReps != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let inputLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            if dynamicTypeSize.isAccessibilitySize {
                HStack {
                    setNumber("Set \(number)")
                    if hasHeartRateMenu {
                        heartRateMenu {
                            Image(systemName: isMarkedForHeartRate || isTiming ? "heart.fill" : "heart")
                                .foregroundStyle(isMarkedForHeartRate || isTiming ? Color.pink : .secondary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                }
            }
            inputLayout {
                if !dynamicTypeSize.isAccessibilitySize {
                    if hasHeartRateMenu {
                        heartRateMenu {
                            setNumber("\(number)")
                                .overlay(alignment: .topTrailing) {
                                    if isMarkedForHeartRate || isTiming {
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(Color.pink)
                                            .offset(x: 8, y: -3)
                                    }
                                }
                                .frame(minWidth: 32, minHeight: 44)
                        }
                    } else {
                        setNumber("\(number)").frame(width: 26, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Weight (\(unit.rawValue))").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("0", text: $weightText)
                        .keyboardType(.decimalPad)
                        .disabled(completed == true)
                        .padding(.horizontal, 10).padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .background(LiftTheme.insetSurface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Weight for set \(number), \(unit.rawValue)")
                        .accessibilityIdentifier("setWeight-\(number)")
                    if let targetWeight {
                        Text("Target: \(targetWeight.formatted(.number.precision(.fractionLength(0...2)))) \(unit.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("setTargetWeight-\(number)")
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text(repsTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(repsTitle, text: $repsText)
                        .keyboardType(.numberPad)
                        .disabled(completed == true)
                        .padding(.horizontal, 10).padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .background(LiftTheme.insetSurface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("\(repsTitle) for set \(number)")
                        .accessibilityIdentifier("setReps-\(number)")
                    if let targetReps {
                        Text("Target: \(targetReps)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("setTargetReps-\(number)")
                    }
                }
                .frame(maxWidth: .infinity)
                if let completed {
                    Button {
                        if completed || valid { onCompletion?() }
                    } label: {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(completed ? Color.green : Color.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!completed && !valid)
                    .accessibilityLabel(completed ? "Mark set \(number) incomplete" : "Complete set \(number)")
                    .accessibilityIdentifier("completeSet-\(number)")
                }
            }
            .textFieldStyle(.plain)
            .monospacedDigit()
            .padding(.vertical, 3)
            heartRateStatus
            if initialized && !valid {
                Text("Enter a weight of 0 or more and at least 1 rep.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            guard !initialized else { return }
            weightText = formattedWeight
            repsText = String(reps)
            initialized = true
            onValidity?(valid)
        }
        .onChange(of: weightText) { _, _ in commit() }
        .onChange(of: repsText) { _, _ in commit() }
        .onChange(of: weight) { _, _ in
            // Preserve partially typed decimals when their numeric value is unchanged.
            if parsedWeight != weight { weightText = formattedWeight }
        }
        .onChange(of: reps) { _, _ in
            if parsedReps != reps { repsText = String(reps) }
        }
    }

    private var hasHeartRateMenu: Bool { onToggleHeartRateMark != nil || onStartSetTimer != nil }
    private var isTiming: Bool { completed == false && startedAt != nil }

    private func setNumber(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isTiming ? Color.pink : .secondary)
    }

    private func heartRateMenu<Badge: View>(@ViewBuilder badge: () -> Badge) -> some View {
        Menu {
            if completed == false, let onStartSetTimer {
                Button("Start Timed Set", systemImage: "heart.circle.fill", action: onStartSetTimer)
                    .disabled(isTiming)
            }
            if let onToggleHeartRateMark {
                Button(isMarkedForHeartRate ? "Remove Heart Rate Mark" : "Mark for Heart Rate",
                       systemImage: isMarkedForHeartRate ? "heart.slash" : "heart", action: onToggleHeartRateMark)
            }
            if isTiming, let onCancelSetTimer {
                Button("Cancel Set Timer", systemImage: "xmark.circle", action: onCancelSetTimer)
            }
        } label: {
            badge().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Heart rate options for set \(number)")
        .accessibilityValue(isTiming ? "Timing set" : (isMarkedForHeartRate ? "Marked for heart rate" : "Unmarked"))
        .accessibilityIdentifier("setHeartRateMenu-\(number)")
    }

    @ViewBuilder private var heartRateStatus: some View {
        if isTiming, let startedAt {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 5) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .accessibilityHidden(true)
                        Text("Timing set · \(workoutSetDuration(context.date.timeIntervalSince(startedAt)))")
                    }
                    .monospacedDigit()
                    .foregroundStyle(Color.pink)
                }
                if let onCancelSetTimer {
                    Button("Cancel", action: onCancelSetTimer)
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("cancelSetTimer-\(number)")
                }
            }
            .font(.caption)
        } else {
            let duration = startedAt.flatMap { start in completedAt.map { $0.timeIntervalSince(start) } }
            if isMarkedForHeartRate || duration != nil {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    if isMarkedForHeartRate {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .accessibilityHidden(true)
                            Text("Marked for HR")
                        }
                        .foregroundStyle(Color.pink)
                    }
                    if let duration {
                        Text("Timed \(workoutSetDuration(duration))").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var formattedWeight: String {
        weight == weight.rounded() && weight < 1e15 ? String(format: "%.0f", weight) : String(weight)
    }

    private func commit() {
        guard initialized else { return }
        onValidity?(valid)
        if let parsedWeight, let parsedReps, parsedWeight != weight || parsedReps != reps {
            onChange(parsedWeight, parsedReps)
        }
    }
}

func workoutSetDuration(_ interval: TimeInterval) -> String {
    guard interval.isFinite, interval < Double(Int.max) else { return "Unavailable" }
    let seconds = Int(max(0, interval))
    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
}

struct SetColumnHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let unit: WeightUnit
    var completion = false
    var repsTitle = "REPS"
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text("Sets · \(unit.rawValue)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                columns
            }
        }
        .font(.caption2.bold()).foregroundStyle(.secondary)
    }

    private var columns: some View {
        HStack(spacing: 12) {
            Text("SET").frame(width: 26)
            Text(unit.rawValue.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
            Text(repsTitle).frame(maxWidth: .infinity, alignment: .leading)
            if completion { Image(systemName: "checkmark").frame(width: 44) }
        }
        .font(.caption2.bold()).foregroundStyle(.secondary)
    }
}

private struct WorkoutErrorAlert: ViewModifier {
    @Environment(WorkoutStore.self) private var store
    let enabled: Bool

    func body(content: Content) -> some View {
        content.alert("Unable to save", isPresented: Binding(
            get: { enabled && store.errorMessage != nil },
            set: { if !$0 && enabled { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Please try again.") }
    }
}

extension View {
    func workoutErrorAlert(enabled: Bool = true) -> some View {
        modifier(WorkoutErrorAlert(enabled: enabled))
    }
}
