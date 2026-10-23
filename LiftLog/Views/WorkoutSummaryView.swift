import SwiftUI

/// Presents local workout facts immediately and keeps the optional AI request behind
/// one explicit action. The response is owned by `WorkoutSummaryStore` and is never
/// written into workout history.
struct WorkoutSummaryView: View {
    let workoutID: UUID
    let automaticallyGenerate: Bool

    @Environment(WorkoutStore.self) private var store
    @Environment(WorkoutAssistant.self) private var assistant
    @Environment(ChatGPTAccountStore.self) private var accounts
    @Environment(WorkoutSummaryStore.self) private var summary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    @State private var includeHealth = false
    @State private var selectedModel = ""
    @State private var didAutoGenerate = false
    @State private var loadingModels = false
    @State private var generationTask: Task<Void, Never>?
    @State private var automaticTask: Task<Void, Never>?
    @State private var modelReloadTask: Task<Void, Never>?
    @State private var isScreenActive = false
    @State private var activeRequestIncludesHealth = false

    init(workoutID: UUID, automaticallyGenerate: Bool = false) {
        self.workoutID = workoutID
        self.automaticallyGenerate = automaticallyGenerate
    }

    private var workout: WorkoutSession? {
        store.history.first { $0.id == workoutID }
    }

    private var hasModel: Bool {
        assistant.models.contains { $0.slug == selectedModel }
    }

    private var canUseProvider: Bool {
        assistant.selectedProvider == .chatGPT ? accounts.canUsePlan : assistant.appleFoundationModelsAvailability.isAvailable
    }

    private var canGenerate: Bool {
        workout != nil && canUseProvider && hasModel && !summary.isWorking
            && (assistant.selectedProvider == .chatGPT || assistant.canUseSelectedProvider)
    }

    private var hasCurrentSummary: Bool {
        summary.workoutID == workoutID
    }

    private var currentText: String {
        hasCurrentSummary ? summary.text : ""
    }

    private var currentError: String? {
        hasCurrentSummary ? summary.errorMessage : nil
    }

    private var currentHealthNotice: String? {
        hasCurrentSummary ? summary.healthNotice : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let workout {
                    workoutFacts(workout)
                } else {
                    ContentUnavailableView("Workout unavailable", systemImage: "questionmark.folder",
                                          description: Text("This workout is no longer in your saved history."))
                }
                AssistantProviderPicker()

                if workout != nil, hasCurrentSummary && summary.isWorking {
                    workingState
                } else if workout != nil, let error = currentError {
                    errorState(error, previousText: currentText.isEmpty ? nil : currentText)
                } else if workout != nil, !currentText.isEmpty {
                    summaryResult
                } else {
                    EmptyView()
                }
                if workout != nil, !(hasCurrentSummary && summary.isWorking) {
                    requestCard
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Workout Summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    summary.cancel()
                    dismiss()
                }
                .accessibilityIdentifier("closeWorkoutSummaryButton")
            }
        }
        .task {
            isScreenActive = true
            if let existingWorkoutID = summary.workoutID, existingWorkoutID != workoutID {
                summary.cancel()
            }
            await prepareModelsAndAutomaticRequest()
        }
        .onChange(of: assistant.models) { _, _ in
            guard isScreenActive else { return }
            chooseModelIfNeeded()
            // Keep catalog-triggered automatic work owned by the screen. If the
            // sheet disappears while the catalog request is settling, the task
            // is cancelled before it can start a new summary request.
            guard !summary.isWorking else { return }
            automaticTask?.cancel()
            automaticTask = Task { await startAutomaticIfEligible() }
        }
        .onChange(of: assistant.selectedProvider) { _, _ in
            generationTask?.cancel()
            automaticTask?.cancel()
            modelReloadTask?.cancel()
            summary.providerWillChange()
            selectedModel = ""
            includeHealth = false
            activeRequestIncludesHealth = false
            loadingModels = false
            // Provider changes need a new explicit Generate action in this sheet.
            didAutoGenerate = true
            chooseModelIfNeeded()
        }
        .onChange(of: workout) { _, _ in
            generationTask?.cancel()
            automaticTask?.cancel()
            summary.cancel()
        }
        .onDisappear {
            isScreenActive = false
            generationTask?.cancel()
            generationTask = nil
            automaticTask?.cancel()
            automaticTask = nil
            modelReloadTask?.cancel()
            modelReloadTask = nil
            summary.cancel()
        }
    }

    @ViewBuilder
    private func workoutFacts(_ workout: WorkoutSession) -> some View {
        let completedSets = workout.exercises.reduce(0) { count, exercise in
            count + exercise.sets.filter(\.isCompleted).count
        }
        let volume = workout.exercises.reduce(0.0) { total, exercise in
            total + exercise.sets.filter(\.isCompleted).reduce(0.0) { $0 + $1.weight * Double($1.reps) }
        }
        let duration = workout.finishedAt.map { HealthDashboardFormatting.duration($0.timeIntervalSince(workout.startedAt)) } ?? "Unavailable"
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(workout.name).font(.title2.bold())
                Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    facts(completedSets: completedSets, exerciseCount: workout.exercises.count,
                          volume: volume, unit: workout.unit, duration: duration)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    facts(completedSets: completedSets, exerciseCount: workout.exercises.count,
                          volume: volume, unit: workout.unit, duration: duration)
                }
            }
            Text("Volume is calculated as weight × reps for completed sets.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workoutSummarySavedStats")
    }

    @ViewBuilder
    private func facts(completedSets: Int, exerciseCount: Int, volume: Double, unit: WeightUnit, duration: String) -> some View {
        fact(value: "\(completedSets)", label: "completed sets", identifier: "workoutSummarySetCount")
        fact(value: "\(exerciseCount)", label: exerciseCount == 1 ? "exercise" : "exercises", identifier: "workoutSummaryExerciseCount")
        fact(value: volume.formatted(.number.precision(.fractionLength(0...1))), label: "\(unit.rawValue) × reps", identifier: "workoutSummaryVolume")
        fact(value: duration, label: "duration", identifier: "workoutSummaryDuration")
    }

    private func fact(value: String, label: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var requestCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Optional coaching insights", systemImage: "sparkles")
                .font(.headline)
            Text(requestDisclosure)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("workoutSummaryDisclosure")

            if assistant.selectedProvider == .appleFoundationModels, !assistant.appleFoundationModelsAvailability.isAvailable {
                Label(assistant.appleFoundationModelsAvailability.explanation, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workoutSummaryProviderUnavailable")
                Button("Check availability") { assistant.refreshProviderAvailability() }
                    .accessibilityIdentifier("workoutSummaryRefreshAvailabilityButton")
            }
            if canUseProvider {
                modelPicker
                Toggle(isOn: $includeHealth) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include Apple Health")
                        Text(assistant.selectedProvider == .appleFoundationModels
                             ? "Processes session-scoped heart rate, energy, or steps on this iPhone only for this request. It is not saved."
                             : "Shares session-scoped heart rate, energy, or steps with OpenAI only for this request. It is not saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("workoutSummaryIncludeHealthToggle")

                if let notice = currentHealthNotice {
                    Label(notice, systemImage: "heart.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workoutSummaryHealthNotice")
                }

                Button {
                    generate(includeHealth: includeHealth)
                } label: {
                    Label(currentError == nil ? "Generate insights" : "Try again", systemImage: currentError == nil ? "sparkles" : "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canGenerate)
                .accessibilityIdentifier(currentError == nil ? "workoutSummaryGenerateButton" : "workoutSummaryRetryButton")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workoutSummaryRequestCard")
    }

    private var modelPicker: some View {
        Group {
            if assistant.models.isEmpty {
                if loadingModels {
                    ProgressView("Loading available models")
                } else {
                    Text("No model is available yet. Try reloading the selected provider’s models.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error = assistant.errorMessage {
                        Text(error)
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("workoutSummaryModelError")
                    }
                    Button("Reload models") {
                        modelReloadTask?.cancel()
                        modelReloadTask = Task { await reloadModels() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workoutSummaryReloadModelsButton")
                }
            } else if assistant.selectedProvider == .appleFoundationModels {
                Label("Apple system model · On-device", systemImage: "iphone")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workoutSummarySystemModel")
            } else {
                Picker("Model", selection: $selectedModel) {
                    ForEach(assistant.models) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("workoutSummaryModelPicker")
            }
        }
    }

    private var workingState: some View {
        let progressLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 14) {
            progressLayout {
                ProgressView()
                    .accessibilityHidden(true)
                Text("Generating insights…")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workoutSummaryProgress")
            Text(activeRequestIncludesHealth ? "Apple Health is included only because you selected it for this request." : "Using workout data and comparable saved sessions.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !currentText.isEmpty {
                AssistantMarkdownView(text: currentText)
                    .accessibilityIdentifier("workoutSummaryText")
            }
            Button("Stop") { summary.cancel() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workoutSummaryStopButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workoutSummaryWorkingCard")
    }

    private var summaryResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your insights", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            AssistantMarkdownView(text: summary.text)
                .accessibilityIdentifier("workoutSummaryText")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorState(_ error: String, previousText: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Couldn’t generate insights", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(error).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("workoutSummaryError")
            if let previousText {
                Label("Previous insights", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                AssistantMarkdownView(text: previousText)
                    .accessibilityIdentifier("workoutSummaryPreviousText")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func prepareModelsAndAutomaticRequest() async {
        guard canUseProvider else { return }
        let provider = assistant.selectedProvider
        if assistant.models.isEmpty {
            await reloadModels()
        }
        guard !Task.isCancelled, provider == assistant.selectedProvider else { return }
        chooseModelIfNeeded()
        await startAutomaticIfEligible()
    }

    private func reloadModels() async {
        guard isScreenActive, canUseProvider, !loadingModels else { return }
        let provider = assistant.selectedProvider
        loadingModels = true
        await assistant.refreshModels()
        guard provider == assistant.selectedProvider, !Task.isCancelled else { return }
        loadingModels = false
        chooseModelIfNeeded()
        await startAutomaticIfEligible()
    }

    private func startAutomaticIfEligible() async {
        guard isScreenActive, !Task.isCancelled, automaticallyGenerate, store.automaticWorkoutSummaries,
              canUseProvider, !didAutoGenerate, !summary.isWorking else { return }
        chooseModelIfNeeded()
        guard hasModel else { return }
        // Mark only when a real model is available and the request is about to start;
        // a failed model catalog load can therefore be retried.
        didAutoGenerate = true
        activeRequestIncludesHealth = false
        // Automatic summaries are deliberately workout-only. Health always requires
        // the separate toggle and Generate button to authorize the read and send.
        await summary.generate(workoutID: workoutID, model: selectedModel, includeHealth: false)
    }

    private func chooseModelIfNeeded() {
        guard selectedModel.isEmpty || !assistant.models.contains(where: { $0.slug == selectedModel }) else { return }
        selectedModel = assistant.models.first(where: { assistant.selectedProvider == .chatGPT && $0.slug == store.defaultAssistantModel })?.slug
            ?? assistant.models.first?.slug ?? ""
    }

    private func generate(includeHealth: Bool) {
        chooseModelIfNeeded()
        guard isScreenActive, canGenerate else { return }
        // Health consent is for one request. A later retry must opt in again.
        activeRequestIncludesHealth = includeHealth
        self.includeHealth = false
        generationTask?.cancel()
        let model = selectedModel
        generationTask = Task {
            await summary.generate(workoutID: workoutID, model: model, includeHealth: includeHealth)
        }
    }

    private var requestDisclosure: String {
        if assistant.selectedProvider == .appleFoundationModels {
            return "Apple Intelligence processes this workout and up to eight comparable saved sessions on this iPhone when you choose Generate or enable automatic summaries. Works offline without a ChatGPT account. Lift Log never switches to ChatGPT automatically."
        }
        return accounts.canUsePlan
            ? "Workout data is sent to OpenAI when you choose Generate or enable automatic summaries. The request uses this workout and up to eight comparable saved sessions. Your workout remains available offline either way."
            : "Connect an eligible ChatGPT account in Settings, or choose Apple Intelligence for on-device insights when available. Your saved workout facts remain available offline."
    }
}
