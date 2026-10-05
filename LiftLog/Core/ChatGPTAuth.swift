import Foundation
import CryptoKit
import Security

public enum ChatGPTAuthError: Error, LocalizedError, Equatable {
    case invalidCallback, expiredAttempt, denied, incompleteRegistration, identityMismatch
    case invalidIdentityToken, invalidTokenResponse, noAccount, planNotAuthorized, signInRequired
    case requestFailed(status: Int, code: String?)
    case secureStorage

    public var errorDescription: String? {
        switch self {
        case .invalidCallback: return "The ChatGPT sign-in callback could not be verified. Try signing in again."
        case .expiredAttempt: return "ChatGPT sign-in expired. Try again."
        case .denied: return "ChatGPT sign-in was canceled or declined."
        case .incompleteRegistration: return "ChatGPT registration did not finish. Try signing in again."
        case .identityMismatch: return "The returned ChatGPT account does not match this saved registration."
        case .invalidIdentityToken: return "The ChatGPT account identity could not be verified. Try signing in again."
        case .invalidTokenResponse: return "ChatGPT returned incomplete credentials. Try signing in again."
        case .noAccount, .signInRequired: return "Continue with ChatGPT to connect your account."
        case .planNotAuthorized: return "Enable ChatGPT plan usage by continuing with ChatGPT and granting permission."
        case .requestFailed(let status, let code):
            if code == "invalid_grant" { return "Your ChatGPT session has expired. Continue with ChatGPT again." }
            return "ChatGPT authentication failed (HTTP \(status)). Try again."
        case .secureStorage: return "ChatGPT credentials could not be saved securely on this device."
        }
    }
}

public struct ChatGPTAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: String { clientID }
    public let clientID: String
    public var issuer: String?
    public var subject: String?
    public var email: String?
    public let label: String
    public var credentials: ChatGPTCredentials?
    public var isConnected: Bool { credentials != nil }
    public var canUsePlan: Bool { credentials?.canUsePlan ?? false }

    public init(clientID: String, issuer: String? = nil, subject: String? = nil,
                email: String? = nil, label: String, credentials: ChatGPTCredentials? = nil) {
        self.clientID = clientID
        self.issuer = issuer
        self.subject = subject
        self.email = email
        self.label = label
        self.credentials = credentials
    }
}

public struct ChatGPTCredentials: Codable, Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let idToken: String
    public let scopes: Set<String>
    public let expiresAt: Date?
    public var canUsePlan: Bool {
        scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") && accessToken != nil
    }

    public init(response: ChatGPTTokenResponse, previous: ChatGPTCredentials? = nil,
                now: Date = Date()) throws {
        guard let idToken = response.idToken ?? previous?.idToken, !idToken.isEmpty else {
            throw ChatGPTAuthError.invalidTokenResponse
        }
        if let access = response.accessToken {
            guard !access.isEmpty, response.tokenType?.lowercased() == "bearer",
                  let seconds = response.expiresIn, seconds.isFinite, seconds > 0 else {
                throw ChatGPTAuthError.invalidTokenResponse
            }
        } else if previous != nil {
            throw ChatGPTAuthError.invalidTokenResponse
        }
        if previous != nil {
            guard let replacement = response.refreshToken, !replacement.isEmpty else {
                throw ChatGPTAuthError.invalidTokenResponse
            }
        }
        self.idToken = idToken
        accessToken = response.accessToken
        refreshToken = response.refreshToken ?? previous?.refreshToken
        scopes = response.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        expiresAt = response.expiresIn.map { now.addingTimeInterval($0) }
    }
}

public struct ChatGPTTokenResponse: Codable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let idToken: String?
    public let tokenType: String?
    public let expiresIn: Double?
    public let scope: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case tokenType = "token_type", expiresIn = "expires_in", scope
    }
}

public struct ChatGPTAuthTransaction: Sendable {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public let state: String
    public let nonce: String
    public let verifier: String
    public let redirectURI: URL
    public let expiresAt: Date
    public let account: ChatGPTAccount?

    public init(redirectURI: URL, account: ChatGPTAccount? = nil, now: Date = Date()) throws {
        guard redirectURI.scheme == "http", redirectURI.host == "127.0.0.1",
              redirectURI.port != nil, redirectURI.path == "/auth/callback",
              redirectURI.query == nil, redirectURI.fragment == nil else { throw ChatGPTAuthError.invalidCallback }
        self.redirectURI = redirectURI
        self.account = account
        state = try Self.randomValue(count: 32)
        nonce = try Self.randomValue(count: 32)
        verifier = try Self.randomValue(count: 64)
        expiresAt = now.addingTimeInterval(10 * 60)
    }

    public var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString }

    public func authorizationURL(hostID: String, forceConsent: Bool = false) -> URL {
        var parameters = ["client_id": account?.clientID ?? "dynamic_agent_client",
                          "ext_agent_host_id": hostID, "response_type": "code",
                          "redirect_uri": redirectURI.absoluteString, "scope": Self.requestedScopes,
                          "resource": Self.resource, "state": state, "nonce": nonce,
                          "code_challenge_method": "S256", "code_challenge": challenge]
        if let account {
            parameters["id_token_hint"] = account.credentials?.idToken
            parameters["login_hint"] = account.email
        } else {
            parameters["agent_name_hint"] = "Lift Log"
        }
        if forceConsent { parameters["prompt"] = "consent" }
        var components = URLComponents(string: Self.issuer + "/api/accounts/authorize")!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    public func callback(_ url: URL, now: Date = Date()) throws -> (code: String, clientID: String) {
        let grouped = try callbackParameters(url, now: now)
        if grouped["error"] != nil { throw ChatGPTAuthError.denied }
        guard let code = grouped["code"]?.first?.value, !code.isEmpty else { throw ChatGPTAuthError.invalidCallback }
        let issued = grouped["client_id"]?.first?.value
        if let account {
            guard issued == nil || issued == account.clientID else { throw ChatGPTAuthError.identityMismatch }
            return (code, account.clientID)
        }
        guard let issued, !issued.isEmpty, issued != "dynamic_agent_client",
              issued.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ChatGPTAuthError.incompleteRegistration
        }
        return (code, issued)
    }

    public func validateCallbackBinding(_ url: URL, now: Date = Date()) throws {
        _ = try callbackParameters(url, now: now)
    }

    private func callbackParameters(_ url: URL, now: Date) throws -> [String: [URLQueryItem]] {
        guard now < expiresAt else { throw ChatGPTAuthError.expiredAttempt }
        guard url.scheme == redirectURI.scheme, url.host == redirectURI.host,
              url.port == redirectURI.port, url.path == redirectURI.path, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ChatGPTAuthError.invalidCallback
        }
        let grouped = Dictionary(grouping: items, by: \.name)
        guard grouped.values.allSatisfy({ $0.count == 1 }), grouped["state"]?.first?.value == state else {
            throw ChatGPTAuthError.invalidCallback
        }
        return grouped
    }

    private static func randomValue(count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAuthError.secureStorage
        }
        return Data(bytes).base64URLString
    }
}

extension Data {
    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL string: String) {
        guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let padded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - string.count % 4) % 4)
        self.init(base64Encoded: padded)
    }
}
