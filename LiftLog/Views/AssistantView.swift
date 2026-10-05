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
    @FocusState private var composerFocused: Bool

    private var accountIdentity: String {
        "\(accounts.currentAccount?.id ?? "none"):\(accounts.currentAccount?.isConnected ?? false):\(accounts.canUsePlan)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if accounts.canUsePlan {
                modelBar
                transcript
                composerBar
            } else {
                connectionView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("ChatGPT Account", systemImage: "person.crop.circle") { showAccountSettings = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("assistantAccountButton")
            }
            if !assistant.messages.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        assistant.reset()
                        Task { await assistant.refreshModels() }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("assistantNewChatButton")
                }
            }
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
        .task(id: accountIdentity) {
            if let previousAccountIdentity, previousAccountIdentity != accountIdentity { composer = "" }
            previousAccountIdentity = accountIdentity
            presentWelcomeIfNeeded()
        }
        .onChange(of: showAccountSettings) { _, isPresented in
            if !isPresented { presentWelcomeIfNeeded() }
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
                Text("Only your submitted question and relevant workout data are shared with OpenAI. Workout logging stays on your device and works offline.")
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
        HStack(spacing: 12) {
            Label("ChatGPT plan", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                .accessibilityIdentifier("assistantPlanBadge")
            Link(destination: chatGPTUsageURL) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Manage usage in ChatGPT")
            .accessibilityIdentifier("assistantPlanManageUsageLink")
            Spacer(minLength: 8)
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
                .disabled(assistant.isWorking)
                .accessibilityIdentifier("assistantModelPicker")
            } else {
                Button("Reload models") { Task { await assistant.refreshModels() } }
                    .font(.caption).accessibilityIdentifier("assistantReloadModelsButton")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                }.padding(20)
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
            Text("Charts use recorded completed sets. General image generation is unavailable through the ChatGPT plan preview.")
                .font(.footnote).foregroundStyle(.secondary)
        }.assistantCard()
            .accessibilityIdentifier("assistantEmptyState")
    }

    @ViewBuilder private func messageView(_ message: WorkoutAssistantMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.role == .user ? "You" : (message.isPartial ? (assistant.isWorking ? "Assistant · In progress" : "Assistant · Partial response") : "Assistant"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(message.text).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(message.role == .user ? Color.blue.opacity(0.09) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            if let chart = message.chart { AssistantChartView(chart: chart) }
            if let proposal = message.proposal {
                AssistantProposalView(proposal: proposal, isWorking: assistant.isWorking, apply: {
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
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask about your workouts", text: $composer, axis: .vertical)
                    .lineLimit(1...5).padding(12)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .focused($composerFocused)
                    .accessibilityIdentifier("assistantComposer")
                if assistant.isWorking {
                    Button { assistant.cancel() } label: {
                        Image(systemName: "stop.fill").font(.headline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered).clipShape(Circle())
                    .accessibilityLabel("Cancel response")
                    .accessibilityIdentifier("assistantCancelButton")
                } else {
                    Button {
                        let question = composer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !question.isEmpty else { return }
                        assistant.send(question)
                        composer = ""
                        composerFocused = false
                    } label: {
                        Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent).clipShape(Circle())
                    .disabled(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.selectedModel.isEmpty || assistant.isLoadingModels || assistant.usageLimitReached)
                    .accessibilityLabel("Send question")
                    .accessibilityIdentifier("assistantSendButton")
                }
            }
            Text("Question + relevant workout data shared with OpenAI.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
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
