import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct BrowserAuthSettings: Codable {
    var authorizationURL = ""
    var tokenURL = ""
    var clientID = ""
    var scope = ""

    var isComplete: Bool {
        providerURL(authorizationURL) != nil && providerURL(tokenURL) != nil
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func providerURL(_ value: String) -> URL? {
        guard let url = StemService.endpointURL(value), url.query() == nil else { return nil }
        return url
    }
}

struct BrowserCredential {
    let token: String
    let expiresAt: Date?

    var activeToken: String? {
        if let expiresAt, expiresAt <= Date() { return nil }
        return token
    }
}

enum BrowserSignInError: LocalizedError {
    case configuration, unavailable, invalidCallback, declined, tokenRejected
    case randomness

    var errorDescription: String? {
        switch self {
        case .configuration: "Enter an authorization URL, a token URL, and a registered public client ID."
        case .unavailable: "Logic couldn’t open the browser sign-in session."
        case .invalidCallback: "The browser returned an invalid OAuth callback."
        case .declined: "The service declined authorization."
        case .tokenRejected: "The service didn’t issue a usable access token."
        case .randomness: "Couldn’t create a secure browser sign-in request."
        }
    }
}

struct BrowserAuthorization {
    static let scheme = "com.local.logicbridge.audio"
    static let path = "/oauth/callback"
    static let redirectURL = "\(scheme):\(path)"

    let url: URL
    private let state: String
    private let verifier: String
    private let clientID: String
    private let tokenURL: URL
    private let redirect: URL
    private let resource: String?

    init(settings: BrowserAuthSettings, redirect: URL = URL(string: Self.redirectURL)!, resource: String? = nil) throws {
        guard settings.isComplete,
              let start = settings.providerURL(settings.authorizationURL),
              let tokenURL = settings.providerURL(settings.tokenURL),
              var address = URLComponents(url: start, resolvingAgainstBaseURL: false)
        else { throw BrowserSignInError.configuration }

        let state = try Self.randomString()
        let verifier = try Self.randomString()
        let clientID = settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = settings.scope.trimmingCharacters(in: .whitespacesAndNewlines)
        var parameters = [
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect.absoluteString),
            ("state", state), ("code_challenge", Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            ("code_challenge_method", "S256")
        ]
        if !scope.isEmpty { parameters.append(("scope", scope)) }
        if let resource { parameters.append(("resource", resource)) }
        address.percentEncodedQuery = Self.form(parameters)
        guard let url = address.url else { throw BrowserSignInError.configuration }
        self.url = url
        self.state = state
        self.verifier = verifier
        self.clientID = clientID
        self.tokenURL = tokenURL
        self.redirect = redirect
        self.resource = resource
    }

    func matchesCallback(_ callback: URL) -> Bool {
        guard let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              returned.scheme == redirect.scheme, returned.host == redirect.host,
              returned.port == redirect.port, returned.user == nil, returned.password == nil,
              returned.path == redirect.path(), returned.fragment == nil
        else { return false }
        let states = (returned.queryItems ?? []).filter { $0.name == "state" }
        return states.count == 1 && states.first?.value == state
    }

    func exchange(callback: URL) async throws -> BrowserCredential {
        guard matchesCallback(callback) else { throw BrowserSignInError.invalidCallback }
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name == "error" }) {
            throw BrowserSignInError.declined
        }
        let codes = query.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
            throw BrowserSignInError.invalidCallback
        }

        var request = URLRequest(url: tokenURL, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var parameters = [
            ("grant_type", "authorization_code"), ("client_id", clientID),
            ("redirect_uri", redirect.absoluteString), ("code", code), ("code_verifier", verifier)
        ]
        if let resource { parameters.append(("resource", resource)) }
        request.httpBody = Data(Self.form(parameters).utf8)

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let result = try? JSONDecoder().decode(TokenResponse.self, from: data),
              result.token_type.lowercased() == "bearer", !result.access_token.isEmpty,
              result.access_token.utf8.allSatisfy({ (33...126).contains($0) }),
              result.expires_in.map({ $0.isFinite && $0 > 0 }) ?? true
        else { throw BrowserSignInError.tokenRejected }

        return BrowserCredential(token: result.access_token, expiresAt: result.expires_in.map {
            Date().addingTimeInterval($0)
        })
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: TimeInterval?
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw BrowserSignInError.randomness }
        return base64URL(Data(bytes))
    }

    private static func form(_ values: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: NSWindow
    private var browser: ASWebAuthenticationSession?
    private var pendingCallback: CheckedContinuation<URL, Error>?

    init(window: NSWindow) {
        self.window = window
    }

    func signIn(settings: BrowserAuthSettings) async throws -> BrowserCredential {
        let authorization = try BrowserAuthorization(settings: settings)
        defer { browser = nil }
        let callback = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<URL, Error>) in
                pendingCallback = reply
                let handler: ASWebAuthenticationSession.CompletionHandler = { [weak self] url, error in
                    Task { @MainActor in self?.finish(url: url, error: error) }
                }
                let session: ASWebAuthenticationSession
                if #available(macOS 14.4, *) {
                    session = ASWebAuthenticationSession(
                        url: authorization.url, callback: .customScheme(BrowserAuthorization.scheme),
                        completionHandler: handler
                    )
                } else {
                    session = ASWebAuthenticationSession(
                        url: authorization.url, callbackURLScheme: BrowserAuthorization.scheme,
                        completionHandler: handler
                    )
                }
                session.presentationContextProvider = self
                browser = session
                if Task.isCancelled {
                    finish(url: nil, error: CancellationError())
                } else if !session.start() {
                    finish(url: nil, error: BrowserSignInError.unavailable)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.browser?.cancel()
                self?.finish(url: nil, error: CancellationError())
            }
        }
        try Task.checkCancellation()
        return try await authorization.exchange(callback: callback)
    }

    private func finish(url: URL?, error: Error?) {
        guard let callback = pendingCallback else { return }
        pendingCallback = nil
        if let error {
            callback.resume(throwing: error)
        } else if let url {
            callback.resume(returning: url)
        } else {
            callback.resume(throwing: BrowserSignInError.invalidCallback)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
