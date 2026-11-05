import SwiftUI

private struct WatchCompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var watchCompactLayout: Bool {
        get { self[WatchCompactLayoutKey.self] }
        set { self[WatchCompactLayoutKey.self] = newValue }
    }
}

/// Presentation only; all workout mutations remain in the phone or the tested shared mirror.
enum WatchPresentation {
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func prescription(_ set: WatchSetState, unit: String) -> String {
        "\(number(set.weight)) \(unit) × \(set.reps)"
    }

    static func nextPrescription(_ workout: WatchActiveWorkout, unit: String) -> String {
        guard let next = workout.nextIncompleteSet else { return "All planned sets complete" }
        return "\(workout.exercises[next.exerciseIndex].name) Set \(next.setIndex + 1) — \(prescription(next.set, unit: unit))"
    }

    static func supersetLabel(for exercise: WatchExerciseState, in workout: WatchActiveWorkout) -> String? {
        guard let group = exercise.supersetID else { return nil }
        var groups: [UUID] = []
        for entry in workout.exercises {
            if let id = entry.supersetID, !groups.contains(id) { groups.append(id) }
        }
        guard let index = groups.firstIndex(of: group) else { return nil }
        let letter = UnicodeScalar(65 + index).map(String.init) ?? "\(index + 1)"
        return "Superset \(letter)"
    }

    static func volume(_ workout: WatchActiveWorkout, unit: String) -> String {
        let volume = workout.exercises.flatMap(\.sets).filter(\.isCompleted).reduce(0) { $0 + $1.weight * Double($1.reps) }
        return "\(number(volume)) \(unit)"
    }

    static func remaining(_ deadline: Date, at now: Date) -> String {
        let seconds = Int(max(0, min(3600, ceil(deadline.timeIntervalSince(now)))))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

struct WatchRing<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.watchCompactLayout) private var compactLayout
    let fraction: Double
    var color: Color = .green
    var size: CGFloat = 88
    @ViewBuilder let content: Content
    private var ringSize: CGFloat { compactLayout ? min(size, 42) : size }
    // Fit the entire two-line label inside a square inscribed in the inner circle,
    // with breathing room beyond the stroke. Compact rings also scale the type.
    private var centerSize: CGFloat { (ringSize - 9 - 6) / sqrt(2) }
    private var centerScale: CGFloat { ringSize < 55 ? 0.65 : 0.8 }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: 12) {
                ring.frame(width: 24, height: 24).padding(5).accessibilityHidden(true)
                content
            }
        } else {
            ZStack {
                ring
                content
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: centerSize / centerScale, height: centerSize / centerScale)
                    .scaleEffect(centerScale)
                    .frame(width: centerSize, height: centerSize)
            }
            .frame(width: ringSize, height: ringSize)
            .padding(5)
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 9)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .accessibilityHidden(true)
        }
    }
}

struct WatchNextSetLabel: View {
    @Environment(\.watchCompactLayout) private var compactLayout
    let workout: WatchActiveWorkout
    let unit: String
    var prefix = ""

    var body: some View {
        if let next = workout.nextIncompleteSet {
            VStack(spacing: 2) {
                if compactLayout {
                    Text("\(prefix)\(workout.exercises[next.exerciseIndex].name)").font(.caption2)
                    Text("Set \(next.setIndex + 1) — \(WatchPresentation.prescription(next.set, unit: unit))").font(.caption2)
                } else {
                    Text("\(prefix)\(workout.exercises[next.exerciseIndex].name) · Set \(next.setIndex + 1)").font(.caption2)
                    Text(WatchPresentation.prescription(next.set, unit: unit)).font(.caption)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
    }
}

struct WatchPill: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var color: Color = .green
    var foreground: Color = .black
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6)
            .background(color.opacity(configuration.isPressed ? 0.65 : 1), in: Capsule())
            .foregroundStyle(foreground)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct WatchElapsed: View {
    let startedAt: Date
    var body: some View {
        Text(startedAt, style: .timer)
            .monospacedDigit()
            .accessibilityLabel("Elapsed time")
    }
}

/// Keep primary actions above the page indicator while the information scrolls at large sizes.
struct WatchPage<Content: View, Actions: View>: View {
    @Environment(\.watchCompactLayout) private var compactLayout
    var showsPages = true
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    content.frame(maxWidth: .infinity).padding(.horizontal, 4)
                        .id("watch-page-content")
                }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--watch-preview-scroll-bottom") {
                        await Task.yield()
                        proxy.scrollTo("watch-page-content", anchor: .bottom)
                    }
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            actions.padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, showsPages ? 18 : (compactLayout ? 4 : 8))
        .ignoresSafeArea(.container, edges: .bottom)
        .modifier(WatchPreviewAccessibility())
    }
}

/// watchOS simulator cannot set accessibility categories, and sheets reset the inherited size.
struct WatchPreviewAccessibility: ViewModifier {
    func body(content: Content) -> some View {
        content.transformEnvironment(\.dynamicTypeSize) { size in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--watch-preview-accessibility") {
                size = .accessibility3
            }
            #endif
        }
    }
}
