import Foundation
import CryptoKit
import Security

public struct ChatGPTDiscovery: Decodable, Sendable {
    public let issuer: String
    public let jwksURI: URL
    public let revocationEndpoint: URL
    enum CodingKeys: String, CodingKey {
        case issuer, jwksURI = "jwks_uri", revocationEndpoint = "revocation_endpoint"
    }
}

public struct ChatGPTIdentity: Equatable, Sendable {
    public let issuer: String
    public let subject: String
    public let email: String?
}

public struct ChatGPTJSONWebKeySet: Decodable {
    public let keys: [Key]
    public struct Key: Decodable {
        let kty: String
        let kid: String?
        let alg: String?
        let use: String?
        let n: String?
        let e: String?
        let crv: String?
        let x: String?
        let y: String?
    }
}

/// Only verified ID-token claims may be used to associate an account with a registration.
public enum ChatGPTIDTokenVerifier {
    public static func verify(_ token: String, keys: ChatGPTJSONWebKeySet, clientID: String,
                              nonce: String?, now: Date = Date()) throws -> ChatGPTIdentity {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3,
              let headerData = Data(base64URL: pieces[0]), let payload = Data(base64URL: pieces[1]),
              let signature = Data(base64URL: pieces[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let algorithm = header["alg"] as? String, ["RS256", "ES256"].contains(algorithm),
              let kid = header["kid"] as? String, !kid.isEmpty,
              header["crit"] == nil else { throw ChatGPTAuthError.invalidIdentityToken }
        let candidates = keys.keys.filter { $0.kid == kid && ($0.alg == nil || $0.alg == algorithm) && ($0.use == nil || $0.use == "sig") }
        guard candidates.count == 1 else { throw ChatGPTAuthError.invalidIdentityToken }
        let key = candidates[0]
        let message = Data((pieces[0] + "." + pieces[1]).utf8)
        let valid: Bool
        switch algorithm {
        case "RS256":
            guard key.kty == "RSA", let n = key.n.flatMap({ Data(base64URL: $0) }),
                  let e = key.e.flatMap({ Data(base64URL: $0) }), n.count >= 256,
                  let publicKey = rsaPublicKey(modulus: n, exponent: e) else { throw ChatGPTAuthError.invalidIdentityToken }
            valid = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                          message as CFData, signature as CFData, nil)
        case "ES256":
            guard key.kty == "EC", key.crv == "P-256",
                  let x = key.x.flatMap({ Data(base64URL: $0) }), x.count == 32,
                  let y = key.y.flatMap({ Data(base64URL: $0) }), y.count == 32,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
                throw ChatGPTAuthError.invalidIdentityToken
            }
            valid = publicKey.isValidSignature(parsed, for: message)
        default: valid = false
        }
        guard valid, let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == ChatGPTAuthTransaction.issuer,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expires = number(claims["exp"]), let issued = number(claims["iat"]),
              expires > now.timeIntervalSince1970 - 5, issued <= now.timeIntervalSince1970 + 5,
              expires > issued else { throw ChatGPTAuthError.invalidIdentityToken }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              (claims["azp"] == nil && audiences.count == 1) || claims["azp"] as? String == clientID else {
            throw ChatGPTAuthError.invalidIdentityToken
        }
        if let nonce, claims["nonce"] as? String != nonce { throw ChatGPTAuthError.invalidIdentityToken }
        if let nbf = claims["nbf"] {
            guard let seconds = number(nbf), seconds <= now.timeIntervalSince1970 + 5 else {
                throw ChatGPTAuthError.invalidIdentityToken
            }
        }
        return ChatGPTIdentity(issuer: ChatGPTAuthTransaction.issuer, subject: subject, email: claims["email"] as? String)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func length(_ size: Int) -> Data {
            if size < 128 { return Data([UInt8(size)]) }
            var size = size
            var bytes = [UInt8]()
            while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ value: Data) -> Data {
            var bytes = Data(value.drop(while: { $0 == 0 }))
            if bytes.first.map({ $0 & 0x80 != 0 }) == true { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + bytes
        }
        let contents = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(contents.count) + contents
        return SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil)
    }
}

public struct ChatGPTAuthClient: Sendable {
    private let session: URLSession
    private static let productionSession = URLSession(configuration: .ephemeral,
        delegate: ChatGPTAuthRedirectPolicy(), delegateQueue: nil)
    public init(session: URLSession? = nil) { self.session = session ?? Self.productionSession }

    public func discovery() async throws -> ChatGPTDiscovery {
        let configuration: ChatGPTDiscovery = try await get(URL(string: ChatGPTAuthTransaction.issuer + "/.well-known/openid-configuration")!)
        guard configuration.issuer == ChatGPTAuthTransaction.issuer,
              isTrusted(configuration.jwksURI), isTrusted(configuration.revocationEndpoint) else {
            throw ChatGPTAuthError.invalidIdentityToken
        }
        return configuration
    }

    public func exchange(code: String, clientID: String, transaction: ChatGPTAuthTransaction) async throws -> ChatGPTTokenResponse {
        try await tokenRequest(["grant_type": "authorization_code", "client_id": clientID,
            "code": code, "code_verifier": transaction.verifier,
            "redirect_uri": transaction.redirectURI.absoluteString, "resource": ChatGPTAuthTransaction.resource])
    }

    public func refresh(clientID: String, refreshToken: String) async throws -> ChatGPTTokenResponse {
        try await tokenRequest(["grant_type": "refresh_token", "client_id": clientID,
            "refresh_token": refreshToken, "resource": ChatGPTAuthTransaction.resource])
    }

    public func verifyIdentity(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        let configuration = try await discovery()
        // Fetch fresh keys for each sign-in/refresh: rotated or unfamiliar kids cannot reuse stale keys.
        let keys: ChatGPTJSONWebKeySet = try await get(configuration.jwksURI)
        return try ChatGPTIDTokenVerifier.verify(token, keys: keys, clientID: clientID, nonce: nonce)
    }

    public func revoke(clientID: String, refreshToken: String) async throws {
        let configuration = try await discovery()
        let (_, response) = try await session.data(for: Self.formRequest(url: configuration.revocationEndpoint,
            values: ["token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientID]))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ChatGPTAuthError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: nil)
        }
    }

    private func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && url.user == nil && url.password == nil && url.port == nil
    }

    private func tokenRequest(_ values: [String: String]) async throws -> ChatGPTTokenResponse {
        let (data, response) = try await session.data(for: Self.formRequest(
            url: URL(string: ChatGPTAuthTransaction.issuer + "/api/accounts/oauth/token")!, values: values))
        try Self.check(response, data: data)
        guard let tokens = try? JSONDecoder().decode(ChatGPTTokenResponse.self, from: data) else {
            throw ChatGPTAuthError.invalidTokenResponse
        }
        return tokens
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public static func formRequest(url: URL, values: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        return request
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Never surface response bodies; they may contain credentials or reflected request input.
            let code = object?["error"] as? String ?? (object?["error"] as? [String: Any])?["code"] as? String
            let safeCodes = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                             "refresh_token_invalidated", "refresh_token_reused"]
            throw ChatGPTAuthError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                                code: code.flatMap { safeCodes.contains($0) ? $0 : nil })
        }
    }
}

/// OAuth credentials must never be replayed to a redirected destination.
private final class ChatGPTAuthRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
