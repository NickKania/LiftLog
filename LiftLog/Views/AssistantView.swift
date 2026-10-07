import SwiftUI

let chatGPTUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

struct AssistantView: View {
    @Environment(ChatGPTAccountStore.self) private var accounts
    @Environment(WorkoutAssistant.self) private var assistant
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
    @FocusState private var composerFocused: Bool

    private struct ChatDraft {
        let text: String
        let references: [AssistantWorkoutReference]
    }

    private var accountIdentity: String {
        "\(accounts.currentAccount?.id ?? "none"):\(accounts.currentAccount?.isConnected ?? false):\(accounts.canUsePlan)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if accounts.canUsePlan {
                modelBar
                transcript
                    .id(assistant.selectedChatID)
                composerBar
            } else if !assistant.messages.isEmpty {
                transcript
                    .id(assistant.selectedChatID)
                ChatGPTSignInButton().padding()
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
            if accounts.canUsePlan {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { startNewChat() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("assistantNewChatButton")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("ChatGPT Account", systemImage: "person.crop.circle") { showAccountSettings = true }
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
                Form { ChatGPTAccountSettingsView() }
                    .navigationTitle("ChatGPT Account")
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
            if restoreComposerAfterReferencePicker, accounts.canUsePlan, !assistant.isWorking {
                composerFocused = true
            }
            restoreComposerAfterReferencePicker = false
        }) {
            AssistantReferencePicker(
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
            presentWelcomeIfNeeded()
        }
        .onChange(of: showAccountSettings) { _, isPresented in
            if !isPresented { presentWelcomeIfNeeded() }
        }
        .onChange(of: assistant.selectedChatID) { oldID, newID in
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
        guard accounts.canUsePlan, !welcomeShown, !showAccountSettings else { return }
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

    private var connectionView: some View {
        ScrollView {
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

    private var modelBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                planStatus
                Spacer(minLength: 8)
                modelPicker
            }
            VStack(alignment: .leading, spacing: 4) {
                planStatus
                modelPicker
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16).padding(.vertical, 2)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var planStatus: some View {
        HStack(spacing: 4) {
            Label("ChatGPT plan", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                .fixedSize()
                .accessibilityIdentifier("assistantPlanBadge")
            Link(destination: chatGPTUsageURL) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Manage usage in ChatGPT")
            .accessibilityIdentifier("assistantPlanManageUsageLink")
        }
    }

    private var modelPicker: some View {
        Group {
            if assistant.isLoadingModels {
                ProgressView().accessibilityLabel("Loading available models")
            } else if !assistant.models.isEmpty {
                Picker("Model", selection: Binding(get: { assistant.selectedModel }, set: { assistant.selectedModel = $0 })) {
                    ForEach(assistant.models) { model in Text(model.displayName).tag(model.slug) }
                }
                .pickerStyle(.menu)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .disabled(assistant.isWorking)
                .accessibilityIdentifier("assistantModelPicker")
            } else {
                Button("Reload models") { Task { await assistant.refreshModels() } }
                    .font(.caption).frame(minHeight: 44)
                    .accessibilityIdentifier("assistantReloadModelsButton")
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = assistant.storageErrorMessage {
                        AssistantNotice(title: "Chats could not be saved", message: error, systemImage: "externaldrive.badge.exclamationmark")
                    }
                    if assistant.messages.isEmpty {
                        emptyTranscript
                    }
                    ForEach(assistant.messages) { message in
                        messageView(message)
                    }
                    if let error = assistant.errorMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            AssistantNotice(title: assistant.usageLimitReached ? "ChatGPT usage limit reached" : "Assistant unavailable", message: error, systemImage: "exclamationmark.circle")
                            if assistant.usageLimitReached {
                                Link("Manage usage in ChatGPT", destination: chatGPTUsageURL)
                                    .accessibilityIdentifier("assistantManageUsageLink")
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("assistantBottom")
                }.padding(.horizontal, 20).padding(.vertical, 12)
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
            ForEach(["Chart my training volume", "How has my bench press progressed?", "Help me adjust my next workout"], id: \.self) { question in
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
            Text("Charts use recorded completed sets. Use @ to add Apple Health for a selected workout. General image generation is unavailable through the ChatGPT plan preview.")
                .font(.footnote).foregroundStyle(.secondary)
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
                AssistantProposalView(proposal: proposal, isWorking: assistant.isWorking || !accounts.canUsePlan, apply: {
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
            Text(selectedReferences.contains { $0.kind == .health }
                 ? "Sending reads Apple Health for tagged sessions and shares it with OpenAI for this message. Health replies and charts aren’t saved."
                 : "Question + relevant workout data shared with OpenAI. Health requires an @ Health tag.")
                .font(.caption2).foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityIdentifier("assistantComposerPrivacyDisclosure")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var canSendQuestion: Bool {
        !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !assistant.selectedModel.isEmpty && !assistant.isLoadingModels && !assistant.usageLimitReached
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
