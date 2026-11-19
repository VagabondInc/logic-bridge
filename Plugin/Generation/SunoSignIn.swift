import AppKit
import Foundation

enum SunoSignIn {
    private static let resource = "https://api.suno.com/mcp"
    private static let issuer = "https://studio-api-prod.suno.com/api/v2/external/oauth"
    private static let discovery = "https://studio-api-prod.suno.com/.well-known/oauth-authorization-server/api/v2/external/oauth"
    private static let scope = "api:v0 profile:read"

    struct Metadata: Decodable {
        let issuer: String
        let authorization_endpoint: String
        let token_endpoint: String
        let registration_endpoint: String
        let code_challenge_methods_supported: [String]
        let token_endpoint_auth_methods_supported: [String]
    }

    private struct Registration: Decodable {
        let client_id: String
        let redirect_uris: [String]
        let token_endpoint_auth_method: String
    }

    @MainActor
    static func connect() async throws -> BrowserCredential {
        let callback = try LoopbackOAuthCallback()
        defer { callback.close() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let redirect = try await callback.start()
            let transport = URLSession(configuration: .ephemeral)
            defer { transport.finishTasksAndInvalidate() }

            let metadata = try await json(Metadata.self, from: URLRequest(url: URL(string: discovery)!), using: transport)
            guard metadata.issuer == issuer, metadata.code_challenge_methods_supported.contains("S256"),
                  metadata.token_endpoint_auth_methods_supported.contains("none"),
                  let registrationURL = trustedURL(metadata.registration_endpoint),
                  trustedURL(metadata.authorization_endpoint) != nil, trustedURL(metadata.token_endpoint) != nil
            else { throw BrowserSignInError.configuration }

            var request = URLRequest(url: registrationURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_name": "Logic Bridge",
                "application_type": "native",
                "redirect_uris": [redirect.absoluteString],
                "token_endpoint_auth_method": "none",
                "grant_types": ["authorization_code"],
                "response_types": ["code"],
                "scope": scope
            ])
            let registration = try await json(Registration.self, from: request, using: transport)
            guard registration.redirect_uris == [redirect.absoluteString],
                  registration.token_endpoint_auth_method == "none"
            else { throw BrowserSignInError.configuration }

            let authorization = try BrowserAuthorization(settings: BrowserAuthSettings(
                authorizationURL: metadata.authorization_endpoint, tokenURL: metadata.token_endpoint,
                clientID: registration.client_id, scope: scope
            ), redirect: redirect, resource: resource)
            callback.accepts = authorization.matchesCallback
            try Task.checkCancellation()
            guard NSWorkspace.shared.open(authorization.url) else { throw BrowserSignInError.unavailable }
            let returned = try await callback.waitForReturn()
            try Task.checkCancellation()
            return try await authorization.exchange(callback: returned)
        } onCancel: {
            Task { @MainActor in callback.close() }
        }
    }

    private static func trustedURL(_ value: String) -> URL? {
        guard let url = StemService.endpointURL(value), url.scheme == "https",
              url.host() == URL(string: issuer)?.host(), url.port == nil
        else { return nil }
        return url
    }

    private static func json<Value: Decodable>(
        _ type: Value.Type, from request: URLRequest, using transport: URLSession
    ) async throws -> Value {
        var request = request
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await transport.data(for: request, delegate: NoRedirects())
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw BrowserSignInError.configuration
        }
        guard (200..<300).contains(status) else { throw StemServiceError.responseStatus(status) }
        return try JSONDecoder().decode(type, from: body)
    }
}
