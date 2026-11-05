import SwiftUI

/// Shared provider controls keep Assistant and Settings on the same selection.
struct AssistantProviderPicker: View {
    @Environment(WorkoutAssistant.self) private var assistant
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var compact = false
    static let switchingDisclosure = "Switching providers clears unsent questions and tags from every chat. Saved messages stay separate for each provider."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact {
                providerMenu
                    .tint(Color(.label))
                    .padding(.horizontal, 14)
                    .liftGlassSurface(cornerRadius: 24)
                if assistant.storageErrorMessage != nil {
                    AssistantProviderStorageNotice()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                }
            } else {
                providerMenu
                AssistantProviderStorageNotice()
            }
        }
    }

    private var providerMenu: some View {
        Menu {
            ForEach(AssistantProvider.allCases) { provider in
                Button {
                    assistant.selectedProvider = provider
                } label: {
                    if assistant.selectedProvider == provider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                if compact && !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: assistant.selectedProvider == .chatGPT ? "sparkles" : "iphone")
                        .accessibilityHidden(true)
                    Text(assistant.selectedProvider.displayName)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Provider").font(.caption).foregroundStyle(.secondary)
                        Text(assistant.selectedProvider.displayName)
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Provider").foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(assistant.selectedProvider.displayName)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: compact ? "chevron.down" : "chevron.up.chevron.down")
                    .font(.caption).accessibilityHidden(true)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Provider, \(assistant.selectedProvider.displayName)")
        .accessibilityValue(assistant.selectedProvider.displayName)
        .accessibilityIdentifier("assistantProviderPicker")
        .accessibilityHint(Self.switchingDisclosure)
    }
}

/// Every provider control reports the same guarded chat-storage failure.
struct AssistantProviderStorageNotice: View {
    @Environment(WorkoutAssistant.self) private var assistant

    var body: some View {
        if let error = assistant.storageErrorMessage {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assistant changes could not be saved").font(.headline)
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Text("Provider changes require saving chats. Resolve the storage error, then try choosing the provider again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark")
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("assistantProviderStorageError")
        }
    }
}

struct AssistantProviderSettingsView: View {
    @Environment(WorkoutAssistant.self) private var assistant

    var body: some View {
        Section {
            AssistantProviderPicker()
            if assistant.selectedProvider == .appleFoundationModels {
                Label(assistant.appleFoundationModelsAvailability.isAvailable ? "Available on this iPhone" : "On-device assistant unavailable",
                      systemImage: assistant.appleFoundationModelsAvailability.isAvailable ? "checkmark.circle" : "exclamationmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
                Text(assistant.appleFoundationModelsAvailability.explanation)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistantProviderAvailability")
                Button("Check availability") { assistant.refreshProviderAvailability() }
                    .accessibilityIdentifier("assistantRefreshAvailabilityButton")
            }
        } header: {
            Text("Assistant provider")
        } footer: {
            Text((assistant.selectedProvider == .appleFoundationModels
                 ? "Apple’s Foundation Models run on this iPhone with Apple Intelligence. Ask about workouts, create charts, review proposed changes, and generate workout summaries, offline and without a ChatGPT account. Questions and selected data stay on this device. Lift Log never switches to ChatGPT automatically."
                 : "Uses your eligible ChatGPT plan. Submitted questions and relevant workout data are sent to OpenAI. Apple Intelligence is a separate on-device option.") + " " + AssistantProviderPicker.switchingDisclosure)
                .accessibilityIdentifier("assistantProviderDisclosure")
        }
    }
}

/// Form sections reused in app Settings and the Assistant account sheet.
struct ChatGPTAccountSettingsView: View {
    @Environment(ChatGPTAccountStore.self) private var accounts

    var body: some View {
        Section {
            if let current = accounts.currentAccount {
                LabeledContent("Account", value: accountLabel(current))
                LabeledContent("Connection", value: accounts.canUsePlan ? "ChatGPT plan connected" : (current.isConnected ? "Plan permission required" : "Sign-in required"))
            }
            if !accounts.accounts.isEmpty {
                Menu {
                    ForEach(accounts.accounts) { account in
                        Button {
                            Task { await accounts.selectAccount(account) }
                        } label: {
                            if account.id == accounts.currentAccount?.id {
                                Label(accountLabel(account), systemImage: "checkmark")
                            } else { Text(accountLabel(account)) }
                        }
                    }
                } label: { Label("Switch account", systemImage: "person.2") }
                    .disabled(accounts.isSigningIn)
                    .accessibilityIdentifier("assistantSwitchAccountButton")
            }
            ChatGPTSignInButton(addAccount: accounts.canUsePlan)
            if accounts.currentAccount != nil {
                Button("Disconnect ChatGPT", role: .destructive) { Task { await accounts.disconnect() } }
                    .disabled(accounts.isSigningIn)
                    .accessibilityIdentifier("assistantDisconnectButton")
            }
            Link("Manage usage in ChatGPT", destination: chatGPTUsageURL)
                .accessibilityIdentifier("chatGPTManageUsageLink")
        } header: { Text("ChatGPT") } footer: {
            Text("Uses an eligible ChatGPT plan. Only submitted questions and relevant workout data are shared with OpenAI. Your local workout app remains usable offline.")
        }
        if let error = accounts.errorMessage {
            Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("chatGPTAccountError") }
        }
    }

    private func accountLabel(_ account: ChatGPTAccount) -> String {
        account.email.map { "\($0) · \(account.label)" } ?? account.label
    }
}

struct ChatGPTSignInButton: View {
    @Environment(ChatGPTAccountStore.self) private var accounts
    var addAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                signIn()
            } label: {
                HStack {
                    if accounts.isSigningIn { ProgressView().tint(.white) }
                    Text(accounts.isSigningIn ? "Connecting…" : (addAccount ? "Add ChatGPT account" : "Continue with ChatGPT"))
                        .font(.headline)
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .liftGlassButton(prominent: true).controlSize(.large)
            .disabled(accounts.isSigningIn)
            .accessibilityIdentifier("continueWithChatGPTButton")
            if accounts.isSigningIn {
                Button("Cancel sign-in") { accounts.cancelSignIn() }
                    .accessibilityIdentifier("cancelChatGPTSignInButton")
            }
        }
    }

    private func signIn() {
        Task {
            if addAccount { await accounts.signIn(accountID: nil) }
            else if accounts.currentAccount?.isConnected == true && !accounts.canUsePlan {
                await accounts.enablePlanUsage()
            }
            else { await accounts.signIn() }
        }
    }
}
