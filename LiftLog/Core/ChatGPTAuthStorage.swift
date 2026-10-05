import Foundation

public struct ChatGPTAuthSnapshot: Codable, Sendable {
    public let hostID: String
    public var accounts: [ChatGPTAccount]
    public var activeAccountID: String?
    public var pendingRegistrationID: String?

    public init(hostID: String = "urn:uuid:" + UUID().uuidString.lowercased(),
                accounts: [ChatGPTAccount] = [], activeAccountID: String? = nil,
                pendingRegistrationID: String? = nil) {
        self.hostID = hostID
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.pendingRegistrationID = pendingRegistrationID
    }
}

public protocol ChatGPTCredentialStorage {
    func load() throws -> ChatGPTAuthSnapshot?
    func save(_ snapshot: ChatGPTAuthSnapshot) throws
}

public enum ChatGPTRefreshRecovery {
    /// A successful refresh consumes the previous token. Even a later verification or storage
    /// failure must never leave that consumed token available for a second refresh.
    public static func requiresReauthorization(responseReceived: Bool, replacementSaved: Bool = false,
                                              error: Error) -> Bool {
        if replacementSaved, error as? ChatGPTAuthError == .planNotAuthorized { return false }
        if responseReceived { return true }
        guard let error = error as? ChatGPTAuthError else { return false }
        if error == .invalidTokenResponse { return true } // Malformed HTTP 200 may already have rotated tokens.
        if case .requestFailed(_, let code) = error, let code {
            return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                    "refresh_token_invalidated", "refresh_token_reused"].contains(code)
        }
        return false
    }
}

/// Minimal HTTP parsing for the native loopback listener. Never accept proxy-form request targets.
public enum ChatGPTLoopbackRequest {
    public static func callbackURL(request: Data, redirectURI: URL) throws -> URL {
        guard request.count <= 16_384, let text = String(data: request, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { throw ChatGPTAuthError.invalidCallback }
        let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/auth/callback?"), !first[1].contains("#") else {
            throw ChatGPTAuthError.invalidCallback
        }
        var hosts = [String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw ChatGPTAuthError.invalidCallback
            }
            if line[..<colon].lowercased() == "host" {
                hosts.append(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let port = redirectURI.port, hosts == ["127.0.0.1:\(port)"],
              let url = URL(string: "http://127.0.0.1:\(port)" + String(first[1])),
              url.path == "/auth/callback" else { throw ChatGPTAuthError.invalidCallback }
        return url
    }
}
