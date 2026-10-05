import Foundation
import Observation

@Observable @MainActor
final class ChatGPTAccountStore {
    private(set) var accounts: [ChatGPTAccount] = []
    private(set) var currentAccount: ChatGPTAccount?
    private(set) var isSigningIn = false
    private(set) var revision = 0
    var errorMessage: String?
    var canUsePlan: Bool { currentAccount?.canUsePlan ?? false }
    @ObservationIgnored var onConnectionChange: (() -> Void)?

    @ObservationIgnored private let storage: ChatGPTCredentialStorage
    @ObservationIgnored private let client: ChatGPTAuthClient
    @ObservationIgnored private var snapshot: ChatGPTAuthSnapshot
    @ObservationIgnored private var storageAvailable = true
    @ObservationIgnored private let isUITesting: Bool
    @ObservationIgnored private var attemptID: UUID?
    @ObservationIgnored private var listener: ChatGPTLoopbackListener?
    @ObservationIgnored private var browser: ChatGPTBrowser?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var isDisconnecting = false

    init(storage: ChatGPTCredentialStorage? = nil, client: ChatGPTAuthClient = ChatGPTAuthClient()) {
        #if DEBUG
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        let testing = false
        #endif
        isUITesting = testing
        self.storage = storage ?? (testing ? ChatGPTMemoryStorage() : ChatGPTKeychainStorage())
        self.client = client
        snapshot = ChatGPTAuthSnapshot()
        do {
            if let stored = try self.storage.load() {
                snapshot = stored
            } else {
                // Persist the stable host identifier before the browser can ever be opened.
                try self.storage.save(snapshot)
            }
            accounts = snapshot.accounts
            currentAccount = accounts.first { $0.id == snapshot.activeAccountID }
        } catch {
            storageAvailable = false
            errorMessage = ChatGPTAuthError.secureStorage.localizedDescription
        }
    }

    func signIn() async {
        await signIn(accountID: snapshot.pendingRegistrationID ?? currentAccount?.id ?? accounts.last?.id)
    }

    /// Passing nil explicitly registers another account/workspace without replacing the active one.
    func signIn(accountID: String?) async { await authorize(accountID: accountID, forceConsent: false) }

    func enablePlanUsage() async {
        await authorize(accountID: currentAccount?.id ?? snapshot.pendingRegistrationID ?? accounts.last?.id,
                        forceConsent: true)
    }

    func selectAccount(_ account: ChatGPTAccount) async {
        guard accounts.contains(where: { $0.id == account.id }) else { return }
        await signIn(accountID: account.id)
    }

    func cancelSignIn() {
        attemptID = nil
        listener?.cancel()
        browser?.close()
        isSigningIn = false
    }

    private func authorize(accountID: String?, forceConsent: Bool) async {
        guard !isSigningIn, !isDisconnecting else { return }
        guard storageAvailable else { errorMessage = ChatGPTAuthError.secureStorage.localizedDescription; return }
        guard !isUITesting else { errorMessage = "ChatGPT sign-in is unavailable during UI tests."; return }
        let selected = accountID.flatMap { id in accounts.first { $0.id == id } }
        guard accountID == nil || selected != nil else { return }
        errorMessage = nil
        isSigningIn = true
        let id = UUID()
        attemptID = id
        let listener = ChatGPTLoopbackListener()
        let browser = ChatGPTBrowser()
        self.listener = listener
        self.browser = browser
        browser.onCancel = { [weak self] in self?.cancelSignIn() }
        defer {
            listener.cancel()
            browser.close()
            if attemptID == id {
                attemptID = nil
                self.listener = nil
                self.browser = nil
                isSigningIn = false
            }
        }
        do {
            let callbackURI = try await listener.start()
            try checkAttempt(id)
            let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI, account: selected)
            listener.transaction = transaction
            try browser.open(transaction.authorizationURL(hostID: snapshot.hostID, forceConsent: forceConsent))
            let returned = try await listener.callback()
            try checkAttempt(id)
            let result = try transaction.callback(returned)
            browser.close()
            if selected == nil {
                guard !accounts.contains(where: { $0.clientID == result.clientID }) else {
                    throw ChatGPTAuthError.identityMismatch
                }
                var pending = snapshot
                pending.accounts.append(ChatGPTAccount(clientID: result.clientID, label: "Account \(accounts.count + 1)"))
                pending.pendingRegistrationID = result.clientID
                // Retain the issued ID before redeeming the code; invalid_grant retries reuse this registration.
                try commit(pending)
            }
            let response = try await client.exchange(code: result.code, clientID: result.clientID, transaction: transaction)
            try checkAttempt(id)
            guard let idToken = response.idToken else { throw ChatGPTAuthError.invalidTokenResponse }
            let identity = try await client.verifyIdentity(idToken, clientID: result.clientID, nonce: transaction.nonce)
            try checkAttempt(id)
            if let subject = selected?.subject,
               subject != identity.subject || selected?.issuer != identity.issuer {
                throw ChatGPTAuthError.identityMismatch
            }
            let credentials = try ChatGPTCredentials(response: response)
            guard let index = snapshot.accounts.firstIndex(where: { $0.id == result.clientID }) else {
                throw ChatGPTAuthError.incompleteRegistration
            }
            var next = snapshot
            next.accounts[index].issuer = identity.issuer
            next.accounts[index].subject = identity.subject
            next.accounts[index].email = identity.email
            next.accounts[index].credentials = credentials
            next.activeAccountID = result.clientID
            if next.pendingRegistrationID == result.clientID { next.pendingRegistrationID = nil }
            // Save before publishing; a Keychain failure never replaces an account's usable credentials.
            try storage.save(next)
            connectionWillChange()
            publish(next)
            revision += 1
        } catch is CancellationError {
            // Cancellation preserves the active account and any already-issued registration.
        } catch {
            if attemptID == id { errorMessage = error.localizedDescription }
        }
    }

    func accessToken() async throws -> String {
        guard !isDisconnecting, let account = currentAccount, let credentials = account.credentials else {
            throw ChatGPTAuthError.signInRequired
        }
        guard credentials.canUsePlan else { throw ChatGPTAuthError.planNotAuthorized }
        if let token = credentials.accessToken,
           let expiry = credentials.expiresAt, expiry.timeIntervalSinceNow > 60 { return token }
        if let refreshTask {
            let startEpoch = epoch
            let token = try await refreshTask.value
            guard startEpoch == epoch, currentAccount?.id == account.id else { throw CancellationError() }
            return token
        }
        guard let refresh = credentials.refreshToken, !refresh.isEmpty else { throw ChatGPTAuthError.signInRequired }
        let startEpoch = epoch
        let task = Task { @MainActor [self] () throws -> String in
            var responseReceived = false
            var replacementSaved = false
            do {
                let response = try await client.refresh(clientID: account.clientID, refreshToken: refresh)
                responseReceived = true
                guard epoch == startEpoch, currentAccount?.id == account.id else { throw CancellationError() }
                if let token = response.idToken {
                    let identity = try await client.verifyIdentity(token, clientID: account.clientID, nonce: nil)
                    guard epoch == startEpoch else { throw CancellationError() }
                    guard identity.subject == account.subject, identity.issuer == account.issuer else {
                        throw ChatGPTAuthError.identityMismatch
                    }
                }
                let renewed = try ChatGPTCredentials(response: response, previous: credentials)
                guard let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }) else { throw CancellationError() }
                var next = snapshot
                next.accounts[index].credentials = renewed
                try commit(next)
                replacementSaved = true
                guard renewed.canUsePlan, let token = renewed.accessToken else {
                    onConnectionChange?()
                    revision += 1
                    throw ChatGPTAuthError.planNotAuthorized
                }
                return token
            } catch {
                if epoch == startEpoch,
                   ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: responseReceived,
                                                                  replacementSaved: replacementSaved, error: error) {
                    var next = snapshot
                    if let index = next.accounts.firstIndex(where: { $0.id == account.id }) {
                        next.accounts[index].credentials = nil
                        connectionWillChange()
                        // If secure persistence fails, still stop using unusable credentials for this launch.
                        do { try commit(next) }
                        catch {
                            publish(next)
                            errorMessage = ChatGPTAuthError.secureStorage.localizedDescription
                        }
                        revision += 1
                    }
                }
                throw error
            }
        }
        refreshTask = task
        defer { if epoch == startEpoch { refreshTask = nil } }
        let token = try await task.value
        guard epoch == startEpoch, currentAccount?.id == account.id else { throw CancellationError() }
        return token
    }

    func disconnect() async {
        guard !isDisconnecting, let account = currentAccount else { return }
        cancelSignIn()
        isDisconnecting = true
        errorMessage = nil
        connectionWillChange()
        currentAccount = nil
        revision += 1
        defer { isDisconnecting = false }
        var remotelyRevoked = true
        if let refresh = account.credentials?.refreshToken {
            remotelyRevoked = false
            for attempt in 0..<3 {
                do {
                    try await client.revoke(clientID: account.clientID, refreshToken: refresh)
                    remotelyRevoked = true
                    break
                } catch {
                    let retry: Bool
                    if case ChatGPTAuthError.requestFailed(let status, _) = error { retry = status >= 500 }
                    else { retry = error is URLError }
                    if !retry || attempt == 2 { break }
                    try? await Task.sleep(for: .seconds(Double(attempt + 1)))
                }
            }
        }
        var next = snapshot
        if let index = next.accounts.firstIndex(where: { $0.id == account.id }) { next.accounts[index].credentials = nil }
        // Retain active mapping for the next routine sign-in; its credentials have been removed.
        do { try commit(next) }
        catch { publish(next); errorMessage = ChatGPTAuthError.secureStorage.localizedDescription }
        revision += 1
        if !remotelyRevoked {
            errorMessage = "Signed out on this device. Remote revocation was not confirmed; disconnect Lift Log in ChatGPT Settings."
        }
    }

    private func checkAttempt(_ id: UUID) throws {
        guard attemptID == id, !Task.isCancelled else { throw CancellationError() }
    }

    private func connectionWillChange() {
        epoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        onConnectionChange?()
    }

    private func commit(_ next: ChatGPTAuthSnapshot) throws { try storage.save(next); publish(next) }

    private func publish(_ next: ChatGPTAuthSnapshot) {
        snapshot = next
        accounts = next.accounts
        currentAccount = accounts.first { $0.id == next.activeAccountID }
    }
}
