import SwiftUI

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
            .buttonStyle(.borderedProminent).controlSize(.large)
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
