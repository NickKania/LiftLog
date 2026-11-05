import SwiftUI

struct RootView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(ChatGPTAccountStore.self) private var chatGPT
    @Environment(WorkoutAssistant.self) private var assistant
    @Environment(\.scenePhase) private var scenePhase
    @State private var showWorkout = false
    @State private var pendingSummaryID: UUID?
    @State private var summaryWorkout: WorkoutSession?

    private var providerRefreshIdentity: String {
        assistant.selectedProvider == .appleFoundationModels
            ? "apple:\(assistant.appleFoundationModelsAvailability.isAvailable)"
            : "chatGPT:\(chatGPT.revision)"
    }

    var body: some View {
        TabView {
            NavigationStack {
                WorkoutHomeView(showWorkout: $showWorkout)
            }
            .tabItem { Label("Workout", systemImage: "dumbbell.fill") }
            NavigationStack { WorkoutHistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            NavigationStack { HealthDashboardView() }
                .tabItem { Label("Health", systemImage: "heart.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
            NavigationStack { AssistantView() }
                .tabItem { Label("Assistant", systemImage: "sparkles") }
        }
        .fullScreenCover(isPresented: $showWorkout, onDismiss: {
            if let id = pendingSummaryID {
                summaryWorkout = store.history.first { $0.id == id }
                pendingSummaryID = nil
            }
        }) {
            NavigationStack {
                ActiveWorkoutView { pendingSummaryID = $0 }
            }
        }
        .sheet(item: $summaryWorkout) { workout in
            NavigationStack {
                WorkoutSummaryView(workoutID: workout.id, automaticallyGenerate: true)
            }
        }
        .onOpenURL { url in
            if url.scheme == "liftlog", url.host == "workout", store.activeWorkout != nil {
                showWorkout = true
            }
        }
        .task(id: providerRefreshIdentity) {
            if assistant.selectedProvider == .appleFoundationModels || chatGPT.canUsePlan {
                await assistant.refreshModels()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { assistant.refreshProviderAvailability() }
        }
    }
}

struct SettingsView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(WorkoutAssistant.self) private var assistant
    @Environment(ChatGPTAccountStore.self) private var accounts

    var body: some View {
        LiftForm {
            Section {
                Picker("Unit", selection: Binding(get: { store.unit }, set: { store.setUnit($0) })) {
                    Text("Pounds (lb)").tag(WeightUnit.lb)
                    Text("Kilograms (kg)").tag(WeightUnit.kg)
                }
                .accessibilityIdentifier("weightUnitPicker")
            } header: {
                Text("Weight")
            } footer: {
                Text("Current template weights convert to this unit. Saved versions, active workouts, and history keep their recorded unit.")
            }
            AssistantProviderSettingsView()
            Section {
                if assistant.selectedProvider == .chatGPT {
                    Picker("Default model", selection: Binding(
                        get: { store.defaultAssistantModel ?? "" },
                        set: { store.setDefaultAssistantModel($0) }
                    )) {
                        Text("Automatic").tag("")
                        ForEach(assistant.models) { model in Text(model.displayName).tag(model.slug) }
                        if let saved = store.defaultAssistantModel, !assistant.models.contains(where: { $0.slug == saved }) {
                            Text("\(saved) (unavailable)").tag(saved)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("assistantDefaultModelPicker")
                    .disabled(assistant.isLoadingModels)
                    if assistant.isLoadingModels {
                        ProgressView("Loading available models")
                    } else if accounts.canUsePlan && assistant.models.isEmpty {
                        Button("Reload models") { Task { await assistant.refreshModels() } }
                        if let error = assistant.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    }
                } else {
                    LabeledContent("Model", value: "Apple system model")
                        .accessibilityIdentifier("assistantSystemModelLabel")
                }
                NavigationLink("Workout summaries") {
                    WorkoutSummarySettingsView()
                }
                .accessibilityIdentifier("workoutSummarySettingsLink")
            } header: {
                Text("Assistant")
            } footer: {
                Text(assistant.selectedProvider == .appleFoundationModels
                     ? "Apple Intelligence uses the system’s on-device model. Your ChatGPT default model preference is retained separately."
                     : (accounts.canUsePlan
                        ? "Used for new chats. Automatic chooses an available model. If your default is unavailable, new chats use Automatic."
                        : "Connect an eligible ChatGPT account to choose a default for new chats."))
            }
            Section("ChatGPT") {
                NavigationLink("ChatGPT Account") {
                    LiftForm { ChatGPTAccountSettingsView() }
                        .navigationTitle("ChatGPT Account")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .accessibilityIdentifier("chatGPTSettingsLink")
            }
            CloudBackupSettingsView()
            Section("About") {
                NavigationLink("Credits & Licenses") {
                    CatalogCreditsView()
                }
                .accessibilityIdentifier("catalogCreditsSettingsLink")
            }
        }
        .workoutErrorAlert()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkoutHomeView: View {
    @Environment(WorkoutStore.self) private var store
    @Binding var showWorkout: Bool
    @State private var editingTemplate: WorkoutTemplate?
    @State private var planningTemplate: WorkoutTemplate?
    @State private var creatingTemplate = false
    @State private var deletingTemplate: WorkoutTemplate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ready for your next session?")
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Choose a routine or build your workout as you go.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                if let workout = store.activeWorkout {
                    Button { showWorkout = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("Workout in progress", systemImage: "bolt.fill").font(.caption.bold())
                                Text(workout.name).font(.title3.bold())
                                Text("Tap to continue logging your sets").font(.subheadline)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill").font(.title)
                        }
                        .foregroundStyle(.primary)
                        .padding(10)
                    }
                    .liftGlassButton()
                    .tint(Color(.label))
                    .controlSize(.large)
                    .accessibilityIdentifier("resumeWorkoutButton")
                } else {
                    Button {
                        store.startWorkout(template: nil)
                        if store.activeWorkout != nil { showWorkout = true }
                    } label: {
                        Label("Start an Empty Workout", systemImage: "plus")
                            .font(.headline).frame(maxWidth: .infinity).padding(8)
                    }
                    .liftGlassButton(prominent: true)
                    .controlSize(.large)
                    .accessibilityIdentifier("startEmptyWorkoutButton")
                }
                HStack {
                    Text("My Templates").font(.title2.bold())
                    Spacer()
                    Button { creatingTemplate = true } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                        .liftGlassButton()
                        .tint(Color(.label))
                        .accessibilityLabel("Create template")
                        .accessibilityIdentifier("createTemplateButton")
                }
                if store.templates.isEmpty {
                    ContentUnavailableView("Your routine starts here", systemImage: "square.stack.3d.up", description: Text("Create a template with your favorite exercises and sets."))
                }
                ForEach(store.templates) { template in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(template.name).font(.title3.weight(.semibold))
                                if let version = template.currentVersion {
                                    Text("Version \(version.number) · Default")
                                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(LiftTheme.insetSurface, in: Capsule())
                                        .accessibilityIdentifier("currentTemplateVersion-\(template.id)")
                                }
                                Text("\(template.exercises.count) exercises · \(template.exercises.reduce(0) { $0 + $1.sets.count }) sets")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("Plan Next Workout", systemImage: "arrow.up.right") { planningTemplate = template }
                                Button("Edit Template", systemImage: "pencil") { editingTemplate = template }
                                Button("Delete Template", systemImage: "trash", role: .destructive) { deletingTemplate = template }
                            } label: {
                                Image(systemName: "ellipsis").foregroundStyle(.primary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .tint(Color(.label))
                            .accessibilityLabel("Options for \(template.name)")
                        }
                        Text(template.exercises.map { $0.exercise.name }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        HStack {
                            Button("Plan Next Workout", systemImage: "arrow.up.right") { planningTemplate = template }
                                .accessibilityIdentifier("planTemplate-\(template.id)")
                            Spacer()
                            NavigationLink {
                                TemplateVersionHistoryView(templateID: template.id, showWorkout: $showWorkout)
                            } label: {
                                Label("Versions", systemImage: "clock.arrow.circlepath")
                            }
                            .accessibilityIdentifier("templateVersions-\(template.id)")
                        }
                        .font(.subheadline)
                        Button {
                            store.startWorkout(template: template)
                            if store.activeWorkout != nil { showWorkout = true }
                        } label: {
                            Label("Start Workout", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .liftGlassButton()
                        .tint(Color(.label))
                        .controlSize(.large)
                        .disabled(store.activeWorkout != nil)
                        .accessibilityIdentifier("startTemplate-\(template.id)")
                    }
                    .padding(20)
                    .background(LiftTheme.surface, in: RoundedRectangle(cornerRadius: LiftTheme.cardRadius))
                }
            }
            .padding(20)
        }
        .liftCanvas()
        .workoutErrorAlert(enabled: !creatingTemplate && editingTemplate == nil && planningTemplate == nil && !showWorkout)
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $creatingTemplate) { TemplateEditorView(template: nil, unit: store.unit) }
        .sheet(item: $editingTemplate) { TemplateEditorView(template: $0, unit: store.unit) }
        .sheet(item: $planningTemplate) { TemplateEditorView(template: $0, planningNextWorkout: true, unit: store.unit) }
        .confirmationDialog("Delete template?", isPresented: Binding(get: { deletingTemplate != nil }, set: { if !$0 { deletingTemplate = nil } }), titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) {
                if let template = deletingTemplate { store.deleteTemplate(id: template.id) }
                deletingTemplate = nil
            }
        } message: { Text("Your completed workouts will remain in history.") }
    }
}
