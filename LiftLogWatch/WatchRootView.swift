import SwiftUI
import WatchKit

struct WatchRootView: View {
    @Bindable var client: WatchSessionClient
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            content.environment(\.watchCompactLayout, geometry.size.width < 190)
        }
    }

    private var content: some View {
        NavigationStack {
            Group {
                if client.showSaved {
                    WatchSavedView { client.showSaved = false }
                } else if let workout = client.visibleWorkout {
                    WatchActiveView(client: client, workout: workout)
                        .id(workout.id)
                } else {
                    WatchStartView(client: client)
                }
            }
            .background(.black)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !client.isReachable && client.hasPendingActions {
                    Label("Will sync to iPhone", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .alert("iPhone connection", isPresented: Binding(get: { client.errorMessage != nil }, set: {
                if !$0 { client.errorMessage = nil }
            })) {
                Button("OK", role: .cancel) { client.errorMessage = nil }
            } message: {
                Text(client.errorMessage ?? "")
            }
        }
        .modifier(WatchPreviewAccessibility())
        .task(id: RestAlertContext(state: client.alertState, isReachable: client.isReachable)) {
            await client.synchronizeAlerts()
        }
        .onAppear {
            #if DEBUG
            if WatchPreviewFixture.screen == "saved" { client.showSaved = true }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.refreshConnection() }
        }
    }
}

private struct RestAlertContext: Equatable {
    let state: WatchWorkoutState
    let isReachable: Bool
}

private enum WorkoutPage: Hashable { case now, controls, rest }

private struct RestDeadline: Equatable {
    let id: UUID?
    let endsAt: Date?
    let isActive: Bool
}

private struct WatchActiveView: View {
    let client: WatchSessionClient
    let workout: WatchActiveWorkout
    @State private var page: WorkoutPage = .now
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $page) {
            WatchNowView(client: client, workout: workout).tag(WorkoutPage.now)
            WatchControlsView(client: client, workout: workout).tag(WorkoutPage.controls)
            if let endsAt = workout.restEndsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if endsAt > context.date {
                        WatchRestView(client: client, workout: workout, now: context.date, endsAt: endsAt)
                    } else {
                        WatchRestDoneView(client: client, workout: workout)
                    }
                }
                .tag(WorkoutPage.rest)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text(page == .controls ? "Summary" : workout.name).font(.caption2).foregroundStyle(.white)
            }
        }
        .onChange(of: workout.restTimerID, initial: true) { _, timerID in
            page = timerID == nil ? .now : .rest
            #if DEBUG
            if ["controls", "finish", "discard"].contains(WatchPreviewFixture.screen) { page = .controls }
            #endif
        }
        .task(id: RestDeadline(id: workout.restTimerID, endsAt: workout.restEndsAt, isActive: scenePhase == .active)) {
            guard scenePhase == .active, let id = workout.restTimerID, let deadline = workout.restEndsAt else { return }
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                client.restDidExpire(id: id)
            } catch is CancellationError {
                // Navigation, a new deadline, or wrist-down cancels this wait. Dates survive it.
            } catch { return }
        }
    }
}

struct WatchStartView: View {
    @Environment(\.watchCompactLayout) private var compactLayout
    let client: WatchSessionClient

    var body: some View {
        Group {
            if client.state.templates.isEmpty && !client.hasReceivedContext {
                ContentUnavailableView("Open Lift Log on iPhone", systemImage: "iphone", description: Text("Your templates and active workout will appear here."))
            } else {
                TabView {
                    ForEach(client.state.templates) { template in
                        card(name: template.name, detail: "\(template.exerciseCount) exercises · \(template.setCount) sets") {
                            client.send(.startTemplate(id: template.id))
                        }
                    }
                    card(name: "Empty Workout", detail: "Add exercises on iPhone") {
                        client.send(.startEmpty)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("Lift Log").font(.caption2).foregroundStyle(.white)
            }
        }
    }

    private func card(name: String, detail: String, start: @escaping () -> Void) -> some View {
        WatchPage {
            VStack(spacing: compactLayout ? 4 : 8) {
                WatchRing(fraction: 0, size: 54) {
                    Image(systemName: "dumbbell.fill").font(.title2).foregroundStyle(.green)
                }.accessibilityHidden(true)
                Text(name).font(.headline).multilineTextAlignment(.center)
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } actions: {
            Button("Start", systemImage: "play.fill", action: start)
                .buttonStyle(WatchPill())
                .disabled(client.hasPendingActions)
                .accessibilityLabel("Start \(name)")
                .accessibilityIdentifier("watchStartButton")
        }
    }
}

struct WatchSavedView: View {
    let done: () -> Void
    var body: some View {
        WatchPage(showsPages: false) {
            VStack(spacing: 8) {
                WatchRing(fraction: 1, size: 70) {
                    Image(systemName: "checkmark").font(.title).foregroundStyle(.green)
                }.accessibilityHidden(true)
                Text("Workout saved").font(.headline)
                Text("Full summary on iPhone.").font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        } actions: {
            Button("Done", action: done).buttonStyle(WatchPill())
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("Lift Log").font(.caption2).foregroundStyle(.white)
            }
        }
    }
}
