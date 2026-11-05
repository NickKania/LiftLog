import SwiftUI

/// A deliberately narrow export: no notes, assistant responses, or Health readings.
struct WorkoutShareView: View {
    let workout: WorkoutSession

    @Environment(\.dismiss) private var dismiss
    @State private var format = WorkoutShareFormat.story
    @State private var image: UIImage?
    @State private var renderingFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Image format", selection: $format) {
                    ForEach(WorkoutShareFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("workoutShareFormat")

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(cardDescription)
                        .accessibilityIdentifier("workoutSharePreview")
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview("Workout statistics", image: Image(uiImage: image))) {
                        Label("Share image", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .liftGlassButton(prominent: true)
                    .controlSize(.large)
                    .accessibilityIdentifier("shareWorkoutImageButton")
                } else if renderingFailed {
                    Text("Couldn’t create the image. Please try again.")
                    Button("Try again", action: render)
                } else {
                    ProgressView("Creating image…")
                }

                Text("Share to an available app, or save the image and add it to your story. Destinations depend on the apps installed on your iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Includes the workout name, date, and statistics shown above, plus performed exercises in Story format. Notes, coaching insights, and Apple Health data are never included.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .liftCanvas()
        .navigationTitle("Share Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("closeWorkoutShareButton")
            }
        }
        .task(id: format) { render() }
    }

    private var cardDescription: String {
        let totals = WorkoutSummaryAnalytics.totals(for: workout)
        let exercises = format == .story ? " Exercises: \(WorkoutShareCard.exerciseNames(workout))." : ""
        return "\(workout.name), \(workout.startedAt.formatted(date: .abbreviated, time: .omitted)). \(totals.completedSets) completed sets, \(totals.totalReps) reps. Volume \(totals.volume.formatted(.number.precision(.fractionLength(0...1)))) \(workout.unit.rawValue) × reps. Duration \(WorkoutShareCard.duration(workout)).\(exercises)"
    }

    @MainActor
    private func render() {
        image = nil
        let renderer = ImageRenderer(content: WorkoutShareCard(workout: workout, format: format)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 3
        image = renderer.uiImage
        renderingFailed = image == nil
    }
}

private enum WorkoutShareFormat: String, CaseIterable, Identifiable {
    case story = "Story · 9:16"
    case square = "Square · 1:1"
    var id: Self { self }
    var height: CGFloat { self == .story ? 640 : 360 }
}

/// Fixed export typography is independent of device text size; the surrounding controls scale normally.
private struct WorkoutShareCard: View {
    let workout: WorkoutSession
    let format: WorkoutShareFormat
    private let accent = Color(red: 0.77, green: 0.96, blue: 0.40)

    var body: some View {
        let totals = WorkoutSummaryAnalytics.totals(for: workout)
        VStack(alignment: .leading, spacing: format == .story ? 28 : 16) {
            HStack(spacing: 7) {
                Image(systemName: "dumbbell.fill")
                Text("LIFT LOG").tracking(3)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(accent)
            if format == .story { Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) {
                Text("WORKOUT COMPLETE").font(.system(size: 10, weight: .bold)).tracking(2)
                    .foregroundStyle(accent)
                Text(workout.name)
                    .font(.system(size: format == .story ? 38 : 28, weight: .bold, design: .rounded))
                    .lineLimit(3).minimumScaleFactor(0.5)
                Text(workout.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            Rectangle().fill(accent.opacity(0.5)).frame(height: 1)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: format == .story ? 28 : 14) {
                stat(String(totals.completedSets), label: "COMPLETED SETS")
                stat(String(totals.totalReps), label: "REPS")
                stat(totals.volume.formatted(.number.precision(.fractionLength(0...1))), label: "\(workout.unit.rawValue.uppercased()) × REPS")
                stat(Self.duration(workout), label: "DURATION")
            }
            if format == .story {
                VStack(alignment: .leading, spacing: 8) {
                    Text("EXERCISES").font(.system(size: 9, weight: .semibold)).tracking(1)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(Self.exerciseNames(workout))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(5)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            Text("Every rep counts.").font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(28)
        .frame(width: 360, height: format.height, alignment: .leading)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.20, blue: 0.19), Color(red: 0.04, green: 0.07, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    static func exerciseNames(_ workout: WorkoutSession) -> String {
        workout.exercises.filter { $0.sets.contains(where: \.isCompleted) }
            .map { $0.exercise.name }.joined(separator: " · ")
    }

    static func duration(_ workout: WorkoutSession) -> String {
        guard let finish = workout.finishedAt else { return "Unavailable" }
        return HealthDashboardFormatting.duration(finish.timeIntervalSince(workout.startedAt))
    }
}
