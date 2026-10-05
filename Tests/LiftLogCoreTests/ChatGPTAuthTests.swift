import XCTest
import CryptoKit
import Security
@testable import LiftLogCore

final class ChatGPTAuthTests: XCTestCase {
    private let callbackURI = URL(string: "http://127.0.0.1:43210/auth/callback")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNewRegistrationRequestsHostAllScopesAndFreshPKCE() throws {
        let first = try ChatGPTAuthTransaction(redirectURI: callbackURI)
        let second = try ChatGPTAuthTransaction(redirectURI: callbackURI)
        let parameters = query(first.authorizationURL(hostID: "urn:uuid:host"))
        XCTAssertEqual(parameters["client_id"], "dynamic_agent_client")
        XCTAssertEqual(parameters["agent_name_hint"], "Lift Log")
        XCTAssertEqual(parameters["ext_agent_host_id"], "urn:uuid:host")
        XCTAssertEqual(parameters["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(parameters["redirect_uri"], callbackURI.absoluteString)
        XCTAssertEqual(parameters["scope"], ChatGPTAuthTransaction.requestedScopes)
        XCTAssertEqual(parameters["code_challenge_method"], "S256")
        XCTAssertEqual(parameters["code_challenge"], Data(SHA256.hash(data: Data(first.verifier.utf8))).base64URLString)
        XCTAssertTrue((43...128).contains(first.verifier.count))
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNil(parameters["prompt"])
    }

    func testReturningAuthorizationReusesClientAndAssociatedHints() throws {
        let credentials = try ChatGPTCredentials(response: tokenResponse())
        let account = ChatGPTAccount(clientID: "issued_client", email: "test@example.com", label: "Account 1", credentials: credentials)
        let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI, account: account)
        let parameters = query(transaction.authorizationURL(hostID: "host"))
        XCTAssertEqual(parameters["client_id"], "issued_client")
        XCTAssertEqual(parameters["id_token_hint"], credentials.idToken)
        XCTAssertEqual(parameters["login_hint"], account.email)
        XCTAssertNil(parameters["agent_name_hint"])
        XCTAssertEqual(query(transaction.authorizationURL(hostID: "host", forceConsent: true))["prompt"], "consent")
    }

    func testOnlyExactLoopbackShapeIsAccepted() {
        for url in ["https://127.0.0.1:43210/auth/callback", "http://localhost:43210/auth/callback",
                    "http://127.0.0.1:43210/callback", "http://127.0.0.1/auth/callback",
                    "http://127.0.0.1:43210/auth/callback?existing=1"] {
            XCTAssertThrowsError(try ChatGPTAuthTransaction(redirectURI: URL(string: url)!))
        }
    }

    func testCallbackRequiresStateCodeAndIssuedRegistrationID() throws {
        let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI, now: now)
        let result = try transaction.callback(callback(transaction, extra: ["client_id": "issued_client"]), now: now)
        XCTAssertEqual(result.clientID, "issued_client")
        XCTAssertEqual(result.code, "auth-code")
        XCTAssertThrowsError(try transaction.callback(callback(transaction), now: now)) { XCTAssertEqual($0 as? ChatGPTAuthError, .incompleteRegistration) }
        XCTAssertThrowsError(try transaction.callback(callback(transaction, extra: ["client_id": "dynamic_agent_client"]), now: now))
        XCTAssertThrowsError(try transaction.callback(callback(transaction, extra: ["state": "wrong", "client_id": "issued_client"]), now: now))
        XCTAssertThrowsError(try transaction.callback(callback(transaction, extra: ["code": "", "client_id": "issued_client"]), now: now))
    }

    func testDeniedConsentValidatesStateBeforeOAuthError() throws {
        let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI, now: now)
        XCTAssertThrowsError(try transaction.callback(callback(transaction, extra: ["error": "access_denied"]), now: now)) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .denied)
        }
        XCTAssertThrowsError(try transaction.callback(callback(transaction, extra: ["state": "spoofed", "error": "access_denied"]), now: now)) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .invalidCallback)
        }
    }

    func testCallbackRejectsExpiredDuplicateAndChangedURI() throws {
        let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI, now: now)
        let good = callback(transaction, extra: ["client_id": "issued_client"])
        XCTAssertThrowsError(try transaction.callback(good, now: now.addingTimeInterval(601))) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .expiredAttempt)
        }
        let duplicate = URL(string: good.absoluteString + "&state=" + transaction.state)!
        XCTAssertThrowsError(try transaction.callback(duplicate, now: now))
        let changedPort = URL(string: good.absoluteString.replacingOccurrences(of: ":43210", with: ":43211"))!
        XCTAssertThrowsError(try transaction.callback(changedPort, now: now))
    }

    func testReturningCallbackCannotReplaceClientRegistration() throws {
        let account = ChatGPTAccount(clientID: "first", subject: "subject", label: "Account 1")
        let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI, account: account, now: now)
        XCTAssertEqual(try transaction.callback(callback(transaction), now: now).clientID, "first")
        XCTAssertEqual(try transaction.callback(callback(transaction, extra: ["client_id": "first"]), now: now).clientID, "first")
        XCTAssertThrowsError(try transaction.callback(callback(transaction, extra: ["client_id": "second"]), now: now)) {
            XCTAssertEqual($0 as? ChatGPTAuthError, .identityMismatch)
        }
    }

    func testLoopbackParserRejectsNonGETProxyTargetsAndWrongHost() throws {
        let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI)
        let target = "/auth/callback?state=\(transaction.state)&code=example"
        let good = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:43210\r\n\r\n"
        let parsed = try ChatGPTLoopbackRequest.callbackURL(request: Data(good.utf8), redirectURI: callbackURI)
        XCTAssertEqual(parsed.host, "127.0.0.1")
        try transaction.validateCallbackBinding(parsed)
        for malformed in [good.replacingOccurrences(of: "GET", with: "POST"),
                          good.replacingOccurrences(of: "Host: 127.0.0.1:43210", with: "Host: evil.example"),
                          good.replacingOccurrences(of: "GET /", with: "GET http://evil.example/"),
                          good.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: 127.0.0.1:43210\r\n\r\n"),
                          good.replacingOccurrences(of: "/auth/callback?", with: "/callback?"),
                          String(repeating: "x", count: 16_385)] {
            XCTAssertThrowsError(try ChatGPTLoopbackRequest.callbackURL(request: Data(malformed.utf8), redirectURI: callbackURI))
        }
    }

    func testJWTSignatureAndRequiredOIDCClaimsAreVerified() throws {
        let fixture = try signedIdentity()
        let identity = try ChatGPTIDTokenVerifier.verify(fixture.token, keys: fixture.keys, clientID: "issued_client", nonce: "nonce", now: now)
        XCTAssertEqual(identity.subject, "account-subject")
        XCTAssertEqual(identity.email, "test@example.com")
        XCTAssertEqual(identity.issuer, "https://auth.openai.com")
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(fixture.token, keys: fixture.keys, clientID: "another_client", nonce: "nonce", now: now))
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(fixture.token, keys: fixture.keys, clientID: "issued_client", nonce: "wrong", now: now))
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(fixture.token, keys: fixture.keys, clientID: "issued_client", nonce: "nonce", now: now.addingTimeInterval(3606)))
        var pieces = fixture.token.split(separator: ".").map(String.init)
        var claims = try JSONSerialization.jsonObject(with: Data(base64URL: pieces[1])!) as! [String: Any]
        claims["sub"] = "attacker"
        pieces[1] = try JSONSerialization.data(withJSONObject: claims).base64URLString
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(pieces.joined(separator: "."), keys: fixture.keys, clientID: "issued_client", nonce: "nonce", now: now))
    }

    func testJWTRejectsWrongIssuerMissingClaimsFutureTimeAndAmbiguousAudience() throws {
        for changes: [String: Any] in [["iss": "https://evil.example"], ["sub": ""], ["exp": true],
                                      ["exp": now.timeIntervalSince1970 - 60], ["iat": now.timeIntervalSince1970 + 60],
                                      ["nbf": now.timeIntervalSince1970 + 60], ["aud": ["issued_client", "other"]],
                                      ["aud": ["issued_client", "other"], "azp": "other"], ["nonce": "wrong"]] {
            let fixture = try signedIdentity(changes: changes)
            XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(fixture.token, keys: fixture.keys, clientID: "issued_client", nonce: "nonce", now: now))
        }
        let multiple = try signedIdentity(changes: ["aud": ["issued_client", "other"], "azp": "issued_client"])
        XCTAssertNoThrow(try ChatGPTIDTokenVerifier.verify(multiple.token, keys: multiple.keys, clientID: "issued_client", nonce: "nonce", now: now))
    }

    func testJWTRejectsUnknownKeyAndAlgorithmConfusion() throws {
        let fixture = try signedIdentity()
        let empty = try JSONDecoder().decode(ChatGPTJSONWebKeySet.self, from: Data("{\"keys\":[]}".utf8))
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(fixture.token, keys: empty, clientID: "issued_client", nonce: "nonce", now: now))
        var pieces = fixture.token.split(separator: ".").map(String.init)
        pieces[0] = Data("{\"alg\":\"none\",\"kid\":\"key1\"}".utf8).base64URLString
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(pieces.joined(separator: "."), keys: fixture.keys, clientID: "issued_client", nonce: "nonce", now: now))
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify("malformed", keys: fixture.keys, clientID: "issued_client", nonce: "nonce", now: now))
    }

    func testRS256SignatureVerificationRejectsTampering() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let integers = try rsaIntegers(der)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "rsa-key", "alg": "RS256", "use": "sig",
                                                                       "n": integers.0.base64URLString, "e": integers.1.base64URLString]]])
        let keys = try JSONDecoder().decode(ChatGPTJSONWebKeySet.self, from: jwks)
        let header = Data("{\"alg\":\"RS256\",\"kid\":\"rsa-key\"}".utf8).base64URLString
        let claims = try JSONSerialization.data(withJSONObject: baseClaims()).base64URLString
        let message = Data((header + "." + claims).utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)) as Data
        let token = header + "." + claims + "." + signature.base64URLString
        XCTAssertNoThrow(try ChatGPTIDTokenVerifier.verify(token, keys: keys, clientID: "issued_client", nonce: "nonce", now: now))
        var badSignature = signature
        badSignature[0] ^= 1
        XCTAssertThrowsError(try ChatGPTIDTokenVerifier.verify(header + "." + claims + "." + badSignature.base64URLString, keys: keys, clientID: "issued_client", nonce: "nonce", now: now))
    }

    func testScopesComeFromTokenResponseAndIdentityOnlyRemainsConnected() throws {
        let disabled = try ChatGPTCredentials(response: tokenResponse(scope: "openid profile email"), now: now)
        XCTAssertFalse(disabled.canUsePlan)
        let account = ChatGPTAccount(clientID: "client", subject: "subject", label: "Account 1", credentials: disabled)
        XCTAssertTrue(account.isConnected)
        let identityOnly = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: Data("{\"id_token\":\"identity\",\"scope\":\"openid email\"}".utf8))
        XCTAssertFalse(try ChatGPTCredentials(response: identityOnly).canUsePlan)
        XCTAssertTrue(try ChatGPTCredentials(response: tokenResponse()).canUsePlan)
        XCTAssertFalse(try ChatGPTCredentials(response: tokenResponse(scope: "chatgpt.tokens.use.direct")).canUsePlan)
    }

    func testRefreshReplacesTokensAtomicallyRetainsScopeOnlyWhenAbsent() throws {
        let initial = try ChatGPTCredentials(response: tokenResponse(), now: now)
        var values: [String: Any] = ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600, "token_type": "Bearer"]
        let refreshed = try ChatGPTCredentials(response: decodeTokens(values), previous: initial, now: now.addingTimeInterval(60))
        XCTAssertEqual(refreshed.idToken, initial.idToken)
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.scopes, initial.scopes)
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(3660))
        values["scope"] = "openid email"
        XCTAssertFalse(try ChatGPTCredentials(response: decodeTokens(values), previous: initial).canUsePlan)
        values.removeValue(forKey: "refresh_token")
        XCTAssertThrowsError(try ChatGPTCredentials(response: decodeTokens(values), previous: initial))
    }

    func testTokenResponseRejectsMissingBearerTypeLifetimeOrIdentity() throws {
        for values: [String: Any] in [["access_token": "access"], ["access_token": "access", "id_token": "id", "expires_in": 3600],
                                     ["access_token": "access", "id_token": "id", "token_type": "Bearer", "expires_in": -1],
                                     ["access_token": "", "id_token": "id", "token_type": "Bearer", "expires_in": 3600]] {
            XCTAssertThrowsError(try ChatGPTCredentials(response: decodeTokens(values)))
        }
    }

    func testSeparateRegistrationsAndStableHostRoundTripWithoutEmailDeduplication() throws {
        let accounts = [ChatGPTAccount(clientID: "first", issuer: "issuer", subject: "same", email: "same@example.com", label: "Account 1"),
                        ChatGPTAccount(clientID: "second", issuer: "issuer", subject: "same", email: "same@example.com", label: "Account 2")]
        let original = ChatGPTAuthSnapshot(accounts: accounts, activeAccountID: "first", pendingRegistrationID: "second")
        let decoded = try JSONDecoder().decode(ChatGPTAuthSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.hostID, original.hostID)
        XCTAssertTrue(decoded.hostID.hasPrefix("urn:uuid:"))
        XCTAssertEqual(decoded.accounts, accounts)
        XCTAssertEqual(decoded.pendingRegistrationID, "second")
    }

    func testExchangeAndRefreshUseIssuedClientExactRedirectAndNoSecret() async throws {
        let captured = RequestCapture()
        let client = mockClient { request in
            captured.append(request)
            return (200, try JSONEncoder().encode(self.tokenResponse()))
        }
        let transaction = try ChatGPTAuthTransaction(redirectURI: callbackURI)
        _ = try await client.exchange(code: "a+b&c", clientID: "issued_client", transaction: transaction)
        _ = try await client.refresh(clientID: "issued_client", refreshToken: "replacement+secret&")
        let requests = captured.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
        let exchange = form(requests[0])
        XCTAssertEqual(exchange["client_id"], "issued_client")
        XCTAssertEqual(exchange["code"], "a+b&c")
        XCTAssertEqual(exchange["code_verifier"], transaction.verifier)
        XCTAssertEqual(exchange["redirect_uri"], callbackURI.absoluteString)
        XCTAssertNil(exchange["client_secret"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        let refresh = form(requests[1])
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["refresh_token"], "replacement+secret&")
        XCTAssertEqual(refresh["resource"], ChatGPTAuthTransaction.resource)
        XCTAssertNil(refresh["scope"])
    }

    func testRefreshErrorsPreserveTerminalCodeWithoutLeakingResponseBody() async throws {
        for code in ["invalid_grant", "invalid_refresh_token", "refresh_token_expired", "refresh_token_reused"] {
            let client = mockClient { _ in (400, Data("{\"error\":\"\(code)\",\"description\":\"secret\"}".utf8)) }
            do {
                _ = try await client.refresh(clientID: "issued_client", refreshToken: "unused")
                XCTFail("Expected terminal refresh error")
            } catch {
                XCTAssertEqual(error as? ChatGPTAuthError, .requestFailed(status: 400, code: code))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testRevocationUsesDiscoveryRefreshTokenHintAndEmpty200() async throws {
        let captured = RequestCapture()
        let client = mockClient { request in
            captured.append(request)
            if request.url?.path == "/.well-known/openid-configuration" {
                return (200, Data("{\"issuer\":\"https://auth.openai.com\",\"jwks_uri\":\"https://auth.openai.com/keys\",\"revocation_endpoint\":\"https://auth.openai.com/revoke\"}".utf8))
            }
            return (200, Data())
        }
        try await client.revoke(clientID: "issued_client", refreshToken: "renewable")
        let revoke = try XCTUnwrap(captured.requests.last)
        XCTAssertEqual(revoke.url?.absoluteString, "https://auth.openai.com/revoke")
        XCTAssertEqual(form(revoke), ["client_id": "issued_client", "token": "renewable", "token_type_hint": "refresh_token"])
    }

    func testDiscoveryCannotSendCredentialsOrFetchKeysAtUntrustedHost() async throws {
        let client = mockClient { _ in
            (200, Data("{\"issuer\":\"https://auth.openai.com\",\"jwks_uri\":\"https://evil.example/keys\",\"revocation_endpoint\":\"https://evil.example/revoke\"}".utf8))
        }
        do { _ = try await client.discovery(); XCTFail("Untrusted discovery must fail") }
        catch { XCTAssertEqual(error as? ChatGPTAuthError, .invalidIdentityToken) }
    }

    func testRefreshRecoveryNeverRetriesConsumedTokenAfterVerificationOrStorageFailure() {
        for error: Error in [ChatGPTAuthError.secureStorage, ChatGPTAuthError.invalidIdentityToken,
                             ChatGPTAuthError.identityMismatch, URLError(.notConnectedToInternet),
                             ChatGPTAuthError.requestFailed(status: 503, code: nil)] {
            XCTAssertTrue(ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: true, error: error))
        }
        XCTAssertTrue(ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: false, error: ChatGPTAuthError.invalidTokenResponse))
        for code in ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"] {
            XCTAssertTrue(ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: false,
                error: ChatGPTAuthError.requestFailed(status: 400, code: code)))
        }
        XCTAssertFalse(ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: false, error: URLError(.timedOut)))
        XCTAssertFalse(ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: false,
            error: ChatGPTAuthError.requestFailed(status: 503, code: nil)))
        XCTAssertFalse(ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: true, replacementSaved: true,
            error: ChatGPTAuthError.planNotAuthorized))
        XCTAssertTrue(ChatGPTRefreshRecovery.requiresReauthorization(responseReceived: true, replacementSaved: false,
            error: ChatGPTAuthError.planNotAuthorized))
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }

    private func form(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        return query(URL(string: "https://example.invalid/?" + body)!)
    }

    private func callback(_ transaction: ChatGPTAuthTransaction, extra: [String: String] = [:]) -> URL {
        var components = URLComponents(url: transaction.redirectURI, resolvingAgainstBaseURL: false)!
        let values = ["code": "auth-code", "state": transaction.state].merging(extra, uniquingKeysWith: { _, new in new })
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func decodeTokens(_ values: [String: Any]) throws -> ChatGPTTokenResponse {
        try JSONDecoder().decode(ChatGPTTokenResponse.self, from: JSONSerialization.data(withJSONObject: values))
    }

    private func tokenResponse(scope: String = "openid email offline_access resource.invoke chatgpt.tokens.use.direct") throws -> ChatGPTTokenResponse {
        try decodeTokens(["access_token": "access", "refresh_token": "refresh", "id_token": "identity",
                          "token_type": "Bearer", "expires_in": 3600, "scope": scope])
    }

    private func baseClaims() -> [String: Any] {
        ["iss": "https://auth.openai.com", "sub": "account-subject", "aud": "issued_client",
         "email": "test@example.com", "nonce": "nonce", "iat": now.timeIntervalSince1970,
         "exp": now.timeIntervalSince1970 + 3600]
    }

    private func signedIdentity(changes: [String: Any] = [:]) throws -> (token: String, keys: ChatGPTJSONWebKeySet) {
        let key = P256.Signing.PrivateKey()
        let publicBytes = key.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "kid": "key1", "alg": "ES256", "crv": "P-256",
                                                                       "x": Data(publicBytes[1..<33]).base64URLString,
                                                                       "y": Data(publicBytes[33..<65]).base64URLString]]])
        let keys = try JSONDecoder().decode(ChatGPTJSONWebKeySet.self, from: jwks)
        let header = Data("{\"alg\":\"ES256\",\"kid\":\"key1\"}".utf8).base64URLString
        let payload = try JSONSerialization.data(withJSONObject: baseClaims().merging(changes, uniquingKeysWith: { _, new in new })).base64URLString
        let signingInput = header + "." + payload
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation.base64URLString
        return (signingInput + "." + signature, keys)
    }

    private func rsaIntegers(_ data: Data) throws -> (Data, Data) {
        let bytes = [UInt8](data)
        var index = 0
        func length() -> Int {
            let first = Int(bytes[index]); index += 1
            if first < 128 { return first }
            var result = 0
            for _ in 0..<(first & 127) { result = result * 256 + Int(bytes[index]); index += 1 }
            return result
        }
        XCTAssertEqual(bytes[index], 0x30); index += 1
        _ = length()
        XCTAssertEqual(bytes[index], 0x02); index += 1
        let nLength = length()
        let n = Data(bytes[index..<(index + nLength)]).drop(while: { $0 == 0 }); index += nLength
        XCTAssertEqual(bytes[index], 0x02); index += 1
        let eLength = length()
        return (Data(n), Data(bytes[index..<(index + eLength)]))
    }

    private func mockClient(handler: @escaping (URLRequest) throws -> (Int, Data)) -> ChatGPTAuthClient {
        MockAuthURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAuthURLProtocol.self]
        return ChatGPTAuthClient(session: URLSession(configuration: configuration))
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class MockAuthURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var body = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
                captured.httpBodyStream = nil
                captured.httpBody = body
            }
            let (status, data) = try Self.handler!(captured)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
