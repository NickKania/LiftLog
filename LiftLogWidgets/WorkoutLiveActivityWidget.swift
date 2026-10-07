import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LiftLogWidgetBundle: WidgetBundle {
    var body: some Widget { WorkoutLiveActivityWidget() }
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutActivityCard(state: context.state)
                .activityBackgroundTint(Color(red: 0.06, green: 0.09, blue: 0.12).opacity(0.94))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(WorkoutActivityAttributes.workoutURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Lift Log", systemImage: "dumbbell.fill")
                        .font(.headline).foregroundStyle(activityBlue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedTime(context.state.startedAt)
                        .font(.headline.monospacedDigit())
                        .frame(width: 85, alignment: .trailing)
                        .accessibilityLabel("Total workout time")
                        .accessibilityValue(elapsedTime(context.state.startedAt))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        restBar(context.state)
                        upcomingSet(context.state)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundStyle(activityBlue)
            } compactTrailing: {
                Group {
                    if let interval = context.state.restInterval {
                        Text(timerInterval: interval, countsDown: true)
                    } else {
                        elapsedTime(context.state.startedAt)
                    }
                }
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(activityBlue)
                .frame(width: 52)
                .minimumScaleFactor(0.7)
            } minimal: {
                Image(systemName: "dumbbell.fill").foregroundStyle(activityBlue)
            }
            .widgetURL(WorkoutActivityAttributes.workoutURL)
            .keylineTint(activityBlue)
        }
    }
}

private let activityBlue = Color(red: 0.20, green: 0.67, blue: 1)

private struct WorkoutActivityCard: View {
    let state: WorkoutActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "dumbbell.fill")
                    .font(.headline)
                    .foregroundStyle(activityBlue)
                    .frame(width: 34, height: 34)
                    .background(activityBlue.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lift Log").font(.subheadline.bold())
                    Text(state.workoutName).font(.caption).foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("WORKOUT TIME").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    elapsedTime(state.startedAt).font(.title3.monospacedDigit().bold())
                        .frame(width: 90, alignment: .trailing)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel("Total workout time")
                        .accessibilityValue(elapsedTime(state.startedAt))
                }
            }
            restBar(state)
            upcomingSet(state)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private func elapsedTime(_ start: Date) -> Text {
    // The interval also handles a restored start date in the future, without
    // counting backwards, and keeps ticking while the app is suspended.
    Text(timerInterval: start...start.addingTimeInterval(8 * 60 * 60), countsDown: false)
}

@ViewBuilder
private func restBar(_ state: WorkoutActivitySnapshot) -> some View {
    if let interval = state.restInterval {
        ZStack {
            Color.white.opacity(0.12)
            ProgressView(timerInterval: interval, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(activityBlue)
                .scaleEffect(x: 1, y: 8)
            HStack {
                Text("REST").font(.system(size: 10, weight: .bold))
                Spacer()
                Text(timerInterval: interval, countsDown: true)
                    .font(.subheadline.monospacedDigit().bold())
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .foregroundStyle(.white)
        }
        .frame(height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rest remaining")
        .accessibilityValue(Text(timerInterval: interval, countsDown: true))
    } else {
        HStack(spacing: 6) {
            Image(systemName: state.nextSet == nil ? "checkmark.circle.fill" : "bolt.fill")
            Text(state.nextSet == nil ? (state.totalSets == 0 ? "Add an exercise to begin" : "All sets complete") : "Ready for your next set")
        }
        .font(.caption.bold())
        .foregroundStyle(activityBlue)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 12)
        .background(activityBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

@ViewBuilder
private func upcomingSet(_ state: WorkoutActivitySnapshot) -> some View {
    if let next = state.nextSet {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("NEXT").font(.system(size: 9, weight: .bold)).foregroundStyle(activityBlue)
                Text(next.exerciseName).font(.subheadline.bold()).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(next.prescription).font(.caption.monospacedDigit())
                Spacer(minLength: 8)
                Text(next.position).font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    } else {
        Text(state.totalSets == 0 ? "Open Lift Log to plan your workout" : "\(state.completedSets) sets logged · Finish in Lift Log")
            .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
    }
}

#Preview("Resting", as: .content, using: WorkoutActivityAttributes(workoutID: UUID())) {
    WorkoutLiveActivityWidget()
} contentStates: {
    WorkoutActivitySnapshot(workoutID: UUID(), workoutName: "Upper Body", startedAt: .now.addingTimeInterval(-2675),
                            restInterval: Date.now...Date.now.addingTimeInterval(120),
                            nextSet: .init(exerciseName: "Dumbbell Bench Press", weight: 37.5, unit: "lb", reps: 10, number: 3, total: 4),
                            completedSets: 2, totalSets: 12)
}
