import SwiftUI

let chatGPTUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

struct AssistantView: View {
    @Environment(ChatGPTAccountStore.self) private var accounts
    @Environment(WorkoutAssistant.self) private var assistant
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("liftlog.assistant.welcomeShown") private var welcomeShown = false
    @State private var composer = ""
    @State private var showAccountSettings = false
    @State private var showWelcome = false
    @State private var proposalError: String?
    @State private var previousAccountIdentity: String?
    @State private var selectedReferences: [AssistantWorkoutReference] = []
    @State private var showReferencePicker = false
    @State private var referenceMentionDraft: String?
    @State private var restoreComposerAfterReferencePicker = false
    @State private var showChats = false
    @State private var drafts: [UUID: ChatDraft] = [:]
    @State private var draftProvider: AssistantProvider?
    @FocusState private var composerFocused: Bool

    private struct ChatDraft {
        let text: String
        let references: [AssistantWorkoutReference]
    }

    private var accountIdentity: String {
        if assistant.selectedProvider == .appleFoundationModels { return AssistantProvider.appleFoundationModels.rawValue }
        return "\(accounts.currentAccount?.id ?? "none"):\(accounts.currentAccount?.isConnected ?? false):\(accounts.canUsePlan)"
    }

    private var canUseProvider: Bool {
        assistant.selectedProvider == .chatGPT ? accounts.canUsePlan : assistant.appleFoundationModelsAvailability.isAvailable
    }

    private var scrollsProviderControls: Bool {
        dynamicTypeSize.isAccessibilitySize || assistant.storageErrorMessage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if !scrollsProviderControls {
                providerBar
            }
            if canUseProvider {
                if !scrollsProviderControls { modelBar }
                transcript
                    .id(assistant.selectedChatID)
                composerBar
            } else if !assistant.messages.isEmpty {
                transcript
                    .id(assistant.selectedChatID)
                if assistant.selectedProvider == .chatGPT {
                    ChatGPTSignInButton().padding()
                } else {
                    Button("Check availability") { assistant.refreshProviderAvailability() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("assistantRefreshAvailabilityButton")
                }
            } else if assistant.selectedProvider == .appleFoundationModels {
                localUnavailableView
            } else {
                connectionView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(assistant.selectedChat?.title ?? "Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Chats", systemImage: "bubble.left.and.bubble.right") {
                    composerFocused = false
                    showChats = true
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("assistantChatsButton")
            }
            if canUseProvider {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { startNewChat() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("assistantNewChatButton")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Assistant settings", systemImage: "gearshape") { showAccountSettings = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("assistantAccountButton")
            }
        }
        .sheet(isPresented: $showChats) {
            AssistantChatListView(onSelect: { id in
                assistant.selectChat(id)
                showChats = false
            }, onCreate: {
                startNewChat()
                showChats = false
            })
        }
        .sheet(isPresented: $showAccountSettings) {
            NavigationStack {
                Form {
                    AssistantProviderSettingsView()
                    ChatGPTAccountSettingsView()
                }
                    .navigationTitle("Assistant Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showAccountSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showWelcome) {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.blue).accessibilityHidden(true)
                Text("You’re using your ChatGPT plan").font(.title2.bold())
                Text("Assistant requests count toward your ChatGPT plan’s usage limits. You can manage your usage in ChatGPT.")
                    .foregroundStyle(.secondary)
                Link("Manage usage in ChatGPT", destination: chatGPTUsageURL)
                Button("Got it") { showWelcome = false }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("assistantWelcomeGotItButton")
            }.padding(24).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showReferencePicker, onDismiss: {
            referenceMentionDraft = nil
            if restoreComposerAfterReferencePicker, canUseProvider, !assistant.isWorking {
                composerFocused = true
            }
            restoreComposerAfterReferencePicker = false
        }) {
            AssistantReferencePicker(
                provider: assistant.selectedProvider,
                references: assistant.availableReferences,
                selectedReferences: selectedReferences.map(currentReference),
                isDisabled: assistant.isWorking,
                onSelect: { references in
                    selectedReferences = references
                    if !references.isEmpty, referenceMentionDraft == composer, composer.hasSuffix("@") {
                        composer.removeLast()
                    }
                    showReferencePicker = false
                },
                onCancel: { showReferencePicker = false }
            )
        }
        .task(id: accountIdentity) {
            assistant.reconcileAccount()
            if let previousAccountIdentity, previousAccountIdentity != accountIdentity {
                clearDraft()
                drafts = [:]
            }
            previousAccountIdentity = accountIdentity
            draftProvider = assistant.selectedProvider
            presentWelcomeIfNeeded()
        }
        .onChange(of: assistant.selectedProvider) { _, provider in
            composerFocused = false
            clearDraft()
            drafts = [:]
            draftProvider = provider
            proposalError = nil
            showWelcome = false
        }
        .onChange(of: showAccountSettings) { _, isPresented in
            if !isPresented { presentWelcomeIfNeeded() }
        }
        .onChange(of: assistant.selectedChatID) { oldID, newID in
            guard draftProvider == assistant.selectedProvider else {
                clearDraft()
                drafts = [:]
                draftProvider = assistant.selectedProvider
                return
            }
            if let oldID { drafts[oldID] = ChatDraft(text: composer, references: selectedReferences) }
            composerFocused = false
            clearDraft()
            if let newID, let draft = drafts[newID] {
                composer = draft.text
                selectedReferences = draft.references
            }
            proposalError = nil
        }
        .onChange(of: composer) { oldValue, newValue in
            // Only a newly appended standalone @ opens the picker. Email addresses,
            // pasted text, and canceled mention drafts remain ordinary text.
            guard composerFocused, !assistant.isWorking, !showReferencePicker,
                  newValue == oldValue + "@",
                  oldValue.isEmpty || oldValue.last?.isWhitespace == true else { return }
            referenceMentionDraft = newValue
            restoreComposerAfterReferencePicker = true
            composerFocused = false
            showReferencePicker = true
        }
        .alert("Could not update workout", isPresented: Binding(get: { proposalError != nil }, set: { if !$0 { proposalError = nil } })) {
            Button("OK") { proposalError = nil }
        } message: { Text(proposalError ?? "") }
    }

    private func presentWelcomeIfNeeded() {
        guard assistant.selectedProvider == .chatGPT, accounts.canUsePlan, !welcomeShown, !showAccountSettings else { return }
        showWelcome = true
        welcomeShown = true
    }

    private func clearDraft() {
        composer = ""
        selectedReferences = []
        referenceMentionDraft = nil
        restoreComposerAfterReferencePicker = false
        showReferencePicker = false
    }

    private func startNewChat() {
        assistant.createChat()
        if assistant.models.isEmpty { Task { await assistant.refreshModels() } }
    }

    private func currentReference(_ reference: AssistantWorkoutReference) -> AssistantWorkoutReference {
        assistant.availableReferences.first { $0.key == reference.key } ?? reference
    }

    private var localUnavailableView: some View {
        ScrollView {
            VStack(spacing: 0) {
                if scrollsProviderControls { providerBar }
                VStack(alignment: .leading, spacing: 20) {
                    AssistantNotice(title: "On-device assistant unavailable",
                                    message: assistant.appleFoundationModelsAvailability.explanation,
                                    systemImage: "iphone")
                        .accessibilityIdentifier("assistantLocalUnavailableNotice")
                    Text("Apple’s Foundation Models use Apple Intelligence on a supported iPhone with iOS 26 or later. When available, questions and selected data are processed on this device, offline and without a ChatGPT account.")
                        .foregroundStyle(.secondary)
                    Button("Check availability") { assistant.refreshProviderAvailability() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("assistantRefreshAvailabilityButton")
                    Text("You can choose ChatGPT above to use an eligible account. Lift Log never switches providers automatically. Workout logging and history remain available offline.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
    }

    private var connectionView: some View {
        ScrollView {
            VStack(spacing: 0) {
                if scrollsProviderControls { providerBar }
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 36)).foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your training, in perspective.").font(.title2.bold())
                        Text("Ask about your workout history, see your progress, or review a suggested change to your routine.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Grounded in your recorded workouts", systemImage: "chart.xyaxis.line")
                        Label("Review changes before applying them", systemImage: "checkmark.shield")
                        Label("Uses your eligible ChatGPT plan", systemImage: "person.crop.circle.badge.checkmark")
                    }.font(.subheadline)
                    Text("Your submitted question and relevant workout data are shared with OpenAI. Apple Health is included only when you select a Health tag using @ and send that message. Workout logging stays on your device and works offline.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("assistantPrivacyDisclosure")
                    ChatGPTSignInButton()
                    if let error = accounts.errorMessage {
                        AssistantNotice(title: "Connection unavailable", message: error, systemImage: "exclamationmark.circle")
                    }
                    Text("Charts are available. General image generation is unavailable through the ChatGPT plan preview.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
    }

    private var modelBar: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedModelControls
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        planStatus
                        Spacer(minLength: 8)
                        if assistant.selectedProvider == .chatGPT || assistant.models.isEmpty { modelPicker }
                    }
                    stackedModelControls
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 2)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var stackedModelControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            planStatus
            if assistant.selectedProvider == .chatGPT || assistant.models.isEmpty { modelPicker }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerBar: some View {
        AssistantProviderPicker()
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground))
    }

    @ViewBuilder private var planStatus: some View {
        if assistant.selectedProvider == .appleFoundationModels {
            Label("On-device · Works offline", systemImage: "iphone")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .accessibilityIdentifier("assistantOnDeviceBadge")
        } else {
            HStack(spacing: 4) {
                Label("ChatGPT plan", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistantPlanBadge")
                Link(destination: chatGPTUsageURL) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Manage usage in ChatGPT")
                .accessibilityIdentifier("assistantPlanManageUsageLink")
            }
        }
    }

    private var modelPicker: some View {
        Group {
            if assistant.isLoadingModels {
                ProgressView().accessibilityLabel("Loading available models")
            } else if !assistant.models.isEmpty {
                Menu {
                    ForEach(assistant.models) { model in
                        Button {
                            assistant.selectedModel = model.slug
                        } label: {
                            if model.slug == assistant.selectedModel {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedModelName)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption).accessibilityHidden(true)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .font(.subheadline)
                .disabled(assistant.isWorking)
                .accessibilityLabel("Model, \(selectedModelName)")
                .accessibilityValue(selectedModelName)
                .accessibilityIdentifier("assistantModelPicker")
            } else {
                Button("Reload models") { Task { await assistant.refreshModels() } }
                    .font(.caption).frame(minHeight: 44)
                    .accessibilityIdentifier("assistantReloadModelsButton")
            }
        }
    }

    private var selectedModelName: String {
        assistant.models.first { $0.slug == assistant.selectedModel }?.displayName ?? assistant.selectedModel
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if scrollsProviderControls {
                        // Large controls stay fully sized and scroll out of the way
                        // instead of reserving most of a small phone's viewport.
                        providerBar
                        if canUseProvider { modelBar }
                    }
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if assistant.selectedProvider == .appleFoundationModels, !assistant.appleFoundationModelsAvailability.isAvailable {
                            AssistantNotice(title: "On-device assistant unavailable",
                                            message: assistant.appleFoundationModelsAvailability.explanation,
                                            systemImage: "iphone")
                                .accessibilityIdentifier("assistantLocalUnavailableNotice")
                        }
                        if assistant.messages.isEmpty {
                            emptyTranscript
                        }
                        ForEach(assistant.messages) { message in
                            messageView(message)
                        }
                        if let error = assistant.errorMessage, error != assistant.storageErrorMessage {
                            VStack(alignment: .leading, spacing: 12) {
                                AssistantNotice(title: assistant.usageLimitReached ? "ChatGPT usage limit reached" : "Assistant unavailable", message: error, systemImage: "exclamationmark.circle")
                                    .accessibilityIdentifier("assistantRequestErrorNotice")
                                if assistant.usageLimitReached {
                                    Link("Manage usage in ChatGPT", destination: chatGPTUsageURL)
                                        .accessibilityIdentifier("assistantManageUsageLink")
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("assistantBottom")
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .task(id: assistant.isWorking) {
                guard !assistant.isWorking, !assistant.messages.isEmpty else { return }
                // Artifacts and streamed text resize the lazy stack. Scroll once after the
                // completed response has laid out, instead of scrolling inside each update.
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, !assistant.isWorking else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("assistantBottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to learn?").font(.title3.bold())
            Text("Ask about completed workouts, request a progress chart, or propose a routine adjustment.")
                .foregroundStyle(.secondary)
            ForEach(suggestedQuestions, id: \.self) { question in
                Button {
                    composer = question
                    composerFocused = true
                } label: {
                    HStack {
                        Text(question).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                    }.font(.subheadline).padding(12)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Text(assistant.selectedProvider == .appleFoundationModels
                 ? "Questions and selected data stay on this iPhone. Use @ to add Apple Health for a selected workout. Review proposed changes before applying them. No ChatGPT account is needed, and Lift Log never switches providers automatically."
                 : "Charts use recorded completed sets. Use @ to add Apple Health for a selected workout. General image generation is unavailable through the ChatGPT plan preview.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("assistantCapabilitiesDisclosure")
        }.assistantCard()
            .accessibilityIdentifier("assistantEmptyState")
    }

    @ViewBuilder private func messageView(_ message: WorkoutAssistantMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.text.isEmpty || !message.references.isEmpty, message.chart == nil, message.proposal == nil {
                AssistantMessageView(message: message, isWorking: assistant.isWorking)
            }
            if let chart = message.chart { AssistantChartView(chart: chart) }
            if let proposal = message.proposal {
                AssistantProposalView(proposal: proposal, isWorking: assistant.isWorking || !canUseProvider, apply: {
                    do { try assistant.applyProposal(proposal.id) }
                    catch { proposalError = error.localizedDescription }
                }, discard: {
                    do { try assistant.rejectProposal(proposal.id) }
                    catch { proposalError = error.localizedDescription }
                })
            }
        }.id(message.id)
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assistant.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Working with your workout data…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("assistantWorkingIndicator")
            }
            if !selectedReferences.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedReferences, id: \.key) { reference in
                            HStack(spacing: 8) {
                                AssistantReferenceLabel(reference: currentReference(reference))
                                    .frame(width: 240, alignment: .leading)
                                    // Measure wrapped text at the constrained width before sizing the tag.
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("assistantSelectedReference.\(reference.key)")
                                Button {
                                    selectedReferences.removeAll { $0.key == reference.key }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, height: 44)
                                }
                                .buttonStyle(.plain)
                                .disabled(assistant.isWorking)
                                .accessibilityLabel("Remove \(reference.name), \(reference.subtitle)")
                                .accessibilityIdentifier("assistantRemoveReference.\(reference.key)")
                            }
                            .padding(.leading, 10).padding(.trailing, 4)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityIdentifier("assistantSelectedReferences")
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    referenceMentionDraft = nil
                    restoreComposerAfterReferencePicker = true
                    composerFocused = false
                    showReferencePicker = true
                } label: {
                    Image(systemName: "at").font(.headline).frame(width: 44, height: 44)
                        .foregroundStyle(.tint)
                        .background(Color.blue.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(assistant.isWorking)
                .accessibilityLabel("Tag a workout, template or Apple Health data")
                .accessibilityIdentifier("assistantAddReferenceButton")
                TextField("Ask about your workouts", text: $composer, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .focused($composerFocused)
                    .accessibilityIdentifier("assistantComposer")
                if assistant.isWorking {
                    Button { assistant.cancel() } label: {
                        Image(systemName: "stop.fill").font(.headline).frame(width: 44, height: 44)
                            .foregroundStyle(.tint)
                            .background(Color.blue.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel response")
                    .accessibilityIdentifier("assistantCancelButton")
                } else {
                    Button {
                        let question = composer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !question.isEmpty else { return }
                        if assistant.send(question, references: selectedReferences) {
                            clearDraft()
                            composerFocused = false
                        }
                    } label: {
                        Image(systemName: "arrow.up").font(.headline)
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .background(Color.accentColor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(canSendQuestion ? 1 : 0.4)
                    .disabled(!canSendQuestion)
                    .accessibilityLabel("Send question")
                    .accessibilityIdentifier("assistantSendButton")
                }
            }
            Text(composerPrivacyDisclosure)
                .font(.caption2).foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityIdentifier("assistantComposerPrivacyDisclosure")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var canSendQuestion: Bool {
        canUseProvider && !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !assistant.selectedModel.isEmpty && !assistant.isLoadingModels && !assistant.usageLimitReached
            && (assistant.selectedProvider == .chatGPT || assistant.canUseSelectedProvider)
    }

    private var suggestedQuestions: [String] {
        ["Chart my training volume", "How has my bench press progressed?", "Help me adjust my next workout"]
    }

    private var composerPrivacyDisclosure: String {
        if assistant.selectedProvider == .appleFoundationModels {
            return selectedReferences.contains { $0.kind == .health }
                ? "Sending reads Apple Health for tagged sessions and processes it on this iPhone for this message. Health questions and replies aren’t saved."
                : "Questions and selected data stay on this iPhone. Works offline. Health requires an @ Health tag."
        }
        return selectedReferences.contains { $0.kind == .health }
            ? "Sending reads Apple Health for tagged sessions and shares it with OpenAI for this message. Health replies and charts aren’t saved."
            : "Question + relevant workout data shared with OpenAI. Health requires an @ Health tag."
    }
}

private struct AssistantNotice: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }.assistantCard()
            .accessibilityElement(children: .combine)
    }
}

extension View {
    func assistantCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
