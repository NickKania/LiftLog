import Charts
import SwiftUI

struct WorkoutHeartRateView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let workout: WorkoutSession
    @State private var health: WorkoutHeartRateStore
    @State private var filter: SetHeartRateFilter = .allTimestamped
    @State private var selectedSetID: UUID?

    init(workout: WorkoutSession, healthDataProvider: (any WorkoutHealthDataProviding)? = nil) {
        self.workout = workout
        _health = State(initialValue: WorkoutHeartRateStore(provider: healthDataProvider ?? Self.makeProvider()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if health.isLoading {
                ProgressView("Reading Apple Health…")
                Button("Cancel") { health.cancel() }
                    .liftGlassButton()
                    .accessibilityIdentifier("cancelWorkoutHeartRateButton")
            } else if let error = health.errorMessage {
                Text(error).foregroundStyle(.secondary)
                Button("Retry", action: load).liftGlassButton(prominent: true)
            } else if let correlation = health.correlation {
                if correlation.heartRateSamples.isEmpty {
                    Text("Apple Health returned no heart rate readings for this workout. Check your read permissions and allow time for Apple Watch to sync. Readings may also be unavailable if a Watch workout wasn’t recorded.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Retry", action: load).liftGlassButton()
                } else {
                    results(correlation)
                }
            } else {
                Text("Load Apple Health to align heart rate readings with your sets. Readings stay in memory on this device and aren't saved or backed up.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Load Apple Health", systemImage: "heart", action: load)
                    .liftGlassButton(prominent: true)
                    .accessibilityIdentifier("loadWorkoutHeartRateButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .onAppear { health.updateWorkout(workout) }
        .onChange(of: workout) { _, workout in health.updateWorkout(workout) }
        .onDisappear { health.cancel() }
        .onChange(of: health.correlation?.hasMarkedSets) { _, hasMarkedSets in
            filter = hasMarkedSets == true ? .markedOnly : .allTimestamped
            selectedSetID = nil
        }
        .onChange(of: filter) { _, _ in selectedSetID = nil }
    }

    private static func makeProvider() -> any WorkoutHealthDataProviding {
        #if DEBUG
        if HealthDashboardUITestFixture.isEnabled { return HealthDashboardUITestFixture.makeHealthDataProvider() }
        #endif
        return AppleHealthDataProvider()
    }

    private func load() {
        health.updateWorkout(workout)
        health.load()
    }

    private var metricsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
    }

    private func results(_ correlation: WorkoutHeartRateCorrelation) -> some View {
        let sets = correlation.sets.filter { filter == .allTimestamped || $0.isMarked }
        let selectedIndex = sets.firstIndex { $0.id == selectedSetID } ?? sets.startIndex
        let selectedSet = sets.indices.contains(selectedIndex) ? sets[selectedIndex] : nil

        return VStack(alignment: .leading, spacing: 12) {
            metricsLayout {
                metric("Session Avg HR", value: correlation.sessionAverageHeartRate, pill: true)
                metric("Session Peak HR", value: correlation.sessionPeakHeartRate, pill: true)
            }
            if correlation.hasTimestampedSets {
                Picker("Show sets", selection: $filter) {
                    ForEach(SetHeartRateFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("workoutHeartRateFilterPicker")
            }

            Text("Heart Rate Timeline").font(.headline)
            timeline(correlation, sets: sets, selection: selectedSet?.id)

            if let selectedSet {
                metricsLayout {
                    Button("Previous Set", systemImage: "chevron.left") {
                        selectedSetID = sets[selectedIndex - 1].id
                    }
                    .disabled(selectedIndex == sets.startIndex)
                    .liftGlassButton()
                    .accessibilityIdentifier("workoutHeartRatePreviousSetButton")
                    Button("Next Set", systemImage: "chevron.right") {
                        selectedSetID = sets[selectedIndex + 1].id
                    }
                    .disabled(selectedIndex + 1 == sets.endIndex)
                    .liftGlassButton()
                    .accessibilityIdentifier("workoutHeartRateNextSetButton")
                }

                setMetrics(selectedSet)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LiftTheme.insetSurface, in: RoundedRectangle(cornerRadius: 12))

                Text("Set Breakdown").font(.headline)
                ForEach(sets) { set in
                    Divider()
                    setMetrics(set)
                }
            } else if correlation.hasTimestampedSets {
                Text("There are no marked sets with timestamps. Choose All sets to see the available set breakdown.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("This workout was recorded without per-set timestamps. Future completed workouts will align sets automatically.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Text("Negative 60s recovery values show how many bpm heart rate fell after the set peak. Apple Watch measures heart rate about every five seconds during an active Watch workout; background readings are less frequent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func timeline(_ correlation: WorkoutHeartRateCorrelation, sets: [SetHeartRateMetrics],
                          selection: UUID?) -> some View {
        let end = max(correlation.endedAt, correlation.startedAt.addingTimeInterval(1))
        let singleSample = correlation.heartRateSamples.count == 1

        return Chart {
            ForEach(sets) { set in
                let selected = set.id == selection
                let color = set.isMarked || selected ? Color.pink : Color.secondary
                if set.windowKind == .timed && set.duration > 0 {
                    RectangleMark(xStart: .value("Set start", set.windowStart),
                                  xEnd: .value("Set finish", set.windowEnd))
                        .foregroundStyle(color.opacity(selected ? 0.36 : 0.16))
                        .accessibilityHidden(true)
                } else {
                    RuleMark(x: .value("Set finish", set.windowEnd))
                        .foregroundStyle(color.opacity(selected ? 1 : 0.6))
                        .lineStyle(StrokeStyle(lineWidth: selected ? 2 : 1, dash: [4, 3]))
                        .accessibilityHidden(true)
                }
            }
            ForEach(Array(correlation.heartRateSamples.enumerated()), id: \.offset) { _, sample in
                if singleSample {
                    PointMark(x: .value("Time", sample.date), y: .value("Heart rate", sample.value))
                        .foregroundStyle(Color.pink)
                } else {
                    AreaMark(x: .value("Time", sample.date), y: .value("Heart rate", sample.value))
                        .foregroundStyle(Color.pink.opacity(0.10))
                        .accessibilityHidden(true)
                    LineMark(x: .value("Time", sample.date), y: .value("Heart rate", sample.value))
                        .foregroundStyle(Color.pink)
                }
            }
        }
        .chartXScale(domain: correlation.startedAt...end)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute(), centered: true)
                    .font(.caption2)
            }
        }
        .chartYAxisLabel("bpm")
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 240 : 170)
        .accessibilityLabel("Workout heart rate timeline")
        .accessibilityIdentifier("workoutHeartRateChart")
    }

    private func setMetrics(_ set: SetHeartRateMetrics) -> some View {
        let weight = set.weight.formatted(.number.precision(.fractionLength(0...2)))
        let window = set.windowKind == .timed ? "Timed \(workoutSetDuration(set.duration))" : "Est. window"
        return VStack(alignment: .leading, spacing: 5) {
            Text("\(set.exerciseName) · Set \(set.setNumber)").font(.subheadline.weight(.semibold))
            Text("\(weight) \(set.unit.rawValue) × \(set.reps) · \(window)")
                .font(.caption).foregroundStyle(.secondary)
            metricsLayout {
                metric("Avg HR", value: set.averageHeartRate)
                metric("Peak HR", value: set.peakHeartRate)
                metric("60s Recovery", value: set.recoveryDrop60s.map { -$0 }, signed: true)
            }
        }
    }

    private func metric(_ title: String, value: Double?, signed: Bool = false, pill: Bool = false) -> some View {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        let reading = value.map {
            "\($0.formatted(signed ? format.sign(strategy: .always(includingZero: false)) : format)) bpm"
        } ?? "Unavailable"

        return VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(reading).fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption)
        .padding(pill ? 8 : 0)
        .background(pill ? LiftTheme.insetSurface : .clear, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
