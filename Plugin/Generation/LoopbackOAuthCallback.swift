import Foundation
import Network

@MainActor
final class LoopbackOAuthCallback {
    private let listener: NWListener
    private var connection: NWConnection?
    private var readiness: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var delivery: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    var accepts: ((URL) -> Bool)?

    init() throws {
        let config = NWParameters.tcp
        config.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: config)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { reply in
            readiness = reply
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) }
                catch { return }
                self?.close(error: URLError(.timedOut))
            }
        }
    }

    func waitForReturn() async throws -> URL {
        try await withCheckedThrowingContinuation { reply in
            if let result { reply.resume(with: result) }
            else { delivery = reply }
        }
    }

    func close(error: Error = CancellationError()) {
        listener.cancel()
        connection?.cancel()
        connection = nil
        timeout?.cancel()
        readiness?.resume(throwing: error)
        readiness = nil
        if result == nil { deliver(.failure(error)) }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(BrowserAuthorization.path)")
            else { close(error: BrowserSignInError.unavailable); return }
            readiness?.resume(returning: url)
            readiness = nil
        case .failed(let error): close(error: error)
        default: break
        }
    }

    private func accept(_ next: NWConnection) {
        guard result == nil else { next.cancel(); return }
        connection?.cancel()
        connection = next
        next.start(queue: .main)
        receive(next, buffered: Data())
    }

    private func receive(_ peer: NWConnection, buffered: Data) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 8192 - buffered.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === peer else { return }
                let received = buffered + (data ?? Data())
                if let lineEnd = received.range(of: Data([13, 10])) {
                    self.reply(to: peer, request: String(decoding: received[..<lineEnd.lowerBound], as: UTF8.self))
                } else if received.count == 8192 || complete || error != nil {
                    peer.cancel()
                } else {
                    self.receive(peer, buffered: received)
                }
            }
        }
    }

    private func reply(to peer: NWConnection, request: String) {
        let fields = request.split(separator: " ")
        let url = fields.count == 3 && fields[0] == "GET" && fields[1].hasPrefix("/")
            ? listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)\(fields[1])") }
            : nil
        let accepted = url.flatMap { accepts?($0) == true ? $0 : nil }
        let message = accepted == nil ? "Invalid Logic Bridge sign-in callback." : "Return to Logic Bridge to finish sign-in."
        let body = Data(message.utf8)
        let status = accepted == nil ? "400 Bad Request" : "200 OK"
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        if let accepted { deliver(.success(accepted)) }
        peer.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                peer.cancel()
                guard let self, self.connection === peer else { return }
                self.connection = nil
            }
        })
    }

    private func deliver(_ outcome: Result<URL, Error>) {
        guard result == nil else { return }
        result = outcome
        delivery?.resume(with: outcome)
        delivery = nil
    }
}
