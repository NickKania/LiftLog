import SwiftUI

struct RootView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(ChatGPTAccountStore.self) private var chatGPT
    @Environment(WorkoutAssistant.self) private var assistant
    @State private var showWorkout = false

    var body: some View {
        TabView {
            NavigationStack {
                WorkoutHomeView(showWorkout: $showWorkout)
            }
            .tabItem { Label("Workout", systemImage: "dumbbell.fill") }
            NavigationStack { WorkoutHistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
            NavigationStack { AssistantView() }
                .tabItem { Label("Assistant", systemImage: "sparkles") }
        }
        .fullScreenCover(isPresented: $showWorkout) {
            NavigationStack { ActiveWorkoutView() }
        }
        .task(id: chatGPT.revision) {
            if chatGPT.canUsePlan { await assistant.refreshModels() }
        }
    }
}

struct SettingsView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(WorkoutAssistant.self) private var assistant
    @Environment(ChatGPTAccountStore.self) private var accounts

    var body: some View {
        Form {
            Section {
                Picker("Unit", selection: Binding(get: { store.unit }, set: { store.setUnit($0) })) {
                    Text("Pounds (lb)").tag(WeightUnit.lb)
                    Text("Kilograms (kg)").tag(WeightUnit.kg)
                }
                .accessibilityIdentifier("weightUnitPicker")
            } header: {
                Text("Weight")
            } footer: {
                Text("Template weights convert to this unit. Active workouts and history keep their recorded unit.")
            }
            Section {
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
            } header: {
                Text("Assistant")
            } footer: {
                Text(accounts.canUsePlan
                     ? "Used for new chats. Automatic chooses an available model. If your default is unavailable, new chats use Automatic."
                     : "Connect an eligible ChatGPT account to choose a default for new chats.")
            }
            Section("ChatGPT") {
                NavigationLink("ChatGPT Account") {
                    Form { ChatGPTAccountSettingsView() }
                        .navigationTitle("ChatGPT Account")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .accessibilityIdentifier("chatGPTSettingsLink")
            }
            CloudBackupSettingsView()
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
    @State private var creatingTemplate = false
    @State private var deletingTemplate: WorkoutTemplate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make every set count.").font(.title2.bold())
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
                        .foregroundStyle(.white)
                        .padding(20)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .accessibilityIdentifier("resumeWorkoutButton")
                } else {
                    Button {
                        store.startWorkout(template: nil)
                        if store.activeWorkout != nil { showWorkout = true }
                    } label: {
                        Label("Start an Empty Workout", systemImage: "plus")
                            .font(.headline).frame(maxWidth: .infinity).padding(8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("startEmptyWorkoutButton")
                }
                HStack {
                    Text("My Templates").font(.title2.bold())
                    Spacer()
                    Button { creatingTemplate = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
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
                                Text(template.name).font(.headline)
                                Text("\(template.exercises.count) exercises · \(template.exercises.reduce(0) { $0 + $1.sets.count }) sets")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("Edit Template", systemImage: "pencil") { editingTemplate = template }
                                Button("Delete Template", systemImage: "trash", role: .destructive) { deletingTemplate = template }
                            } label: { Image(systemName: "ellipsis").padding(8) }
                            .accessibilityLabel("Options for \(template.name)")
                        }
                        Text(template.exercises.map { $0.exercise.name }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        Button {
                            store.startWorkout(template: template)
                            if store.activeWorkout != nil { showWorkout = true }
                        } label: {
                            Label("Start Workout", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.activeWorkout != nil)
                        .accessibilityIdentifier("startTemplate-\(template.id)")
                    }
                    .padding(18)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .workoutErrorAlert(enabled: !creatingTemplate && editingTemplate == nil && !showWorkout)
        .navigationTitle("Workout")
        .sheet(isPresented: $creatingTemplate) { TemplateEditorView(template: nil) }
        .sheet(item: $editingTemplate) { TemplateEditorView(template: $0) }
        .confirmationDialog("Delete template?", isPresented: Binding(get: { deletingTemplate != nil }, set: { if !$0 { deletingTemplate = nil } }), titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) {
                if let template = deletingTemplate { store.deleteTemplate(id: template.id) }
                deletingTemplate = nil
            }
        } message: { Text("Your completed workouts will remain in history.") }
    }
}
