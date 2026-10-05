import Foundation
import Network
import SafariServices
import UIKit

@MainActor
final class ChatGPTBrowser: NSObject, SFSafariViewControllerDelegate {
    private var controller: SFSafariViewController?
    var onCancel: (() -> Void)?

    func open(_ url: URL) throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            throw ChatGPTAuthError.signInRequired
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let browser = SFSafariViewController(url: url)
        browser.delegate = self
        controller = browser
        // Safari's in-app presentation keeps the app's loopback listener in the foreground.
        presenter.present(browser, animated: true)
    }

    func close() {
        controller?.dismiss(animated: true)
        controller = nil
        onCancel = nil
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in self?.onCancel?() }
    }
}

@MainActor
final class ChatGPTLoopbackListener {
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var redirectURI: URL?
    var transaction: ChatGPTAuthTransaction?

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port,
                          let uri = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else { return }
                    self.redirectURI = uri
                    self.startContinuation?.resume(returning: uri)
                    self.startContinuation = nil
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10 * 60))
            if !Task.isCancelled { self?.finish(.failure(ChatGPTAuthError.expiredAttempt)) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func callback() async throws -> URL {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callbackContinuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, buffer: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(10))
            if let connection { self?.remove(connection) }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - buffer.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.result == nil else { connection.cancel(); return }
                let bytes = buffer + (data ?? Data())
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard let redirectURI = self.redirectURI,
                          let url = try? ChatGPTLoopbackRequest.callbackURL(request: bytes, redirectURI: redirectURI),
                          let transaction = self.transaction,
                          (try? transaction.validateCallbackBinding(url)) != nil else {
                        self.respond(connection, status: "400 Bad Request", message: "Invalid callback request.")
                        return
                    }
                    self.respond(connection, status: "200 OK", message: "Return to Lift Log to finish connecting ChatGPT.")
                    self.finish(.success(url), completing: connection)
                } else if complete || error != nil || bytes.count >= 16_384 {
                    self.remove(connection)
                } else {
                    self.receive(connection, buffer: bytes)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let body = "<!doctype html><html><head><meta name=viewport content=\"width=device-width\"><title>Lift Log</title></head><body><p>\(message)</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Security-Policy: default-src 'none'\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.remove(connection) }
        })
    }

    private func remove(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func finish(_ result: Result<URL, Error>, completing: NWConnection? = nil) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values where connection !== completing { connection.cancel() }
        connections = completing.map { [ObjectIdentifier($0): $0] } ?? [:]
        if case .failure(let error) = result { startContinuation?.resume(throwing: error) }
        startContinuation = nil
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
    }
}
