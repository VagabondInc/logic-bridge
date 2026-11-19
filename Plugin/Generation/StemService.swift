import AVFoundation
import Foundation

struct StemRequest: Encodable, Sendable {
    let prompt: String
    let instrument: String
    let tempoBPM: Double
    let timeSignatureNumerator: Int
    let timeSignatureDenominator: Int
    let durationBeats: Double
    let cycleStartBeat: Double?
    let key: String?
    let weirdness: Int
    let styleInfluence: Int
    let audioInfluence: Int?
    let reference: ReferenceAudio?
}

struct ReferenceAudio: Encodable, Sendable {
    let filename: String
    let wav: Data

    nonisolated static func load(from url: URL) throws -> Self {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let limit = 20 * 1_024 * 1_024
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw StemServiceError.referenceTooLarge }
        guard isWave(data) else { throw StemServiceError.invalidReference }
        return Self(filename: url.lastPathComponent, wav: data)
    }
}

private func isWave(_ data: Data) -> Bool {
    data.count >= 12 && data.prefix(4).elementsEqual("RIFF".utf8)
        && data.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8)
}

enum StemServiceError: LocalizedError {
    case invalidEndpoint, responseStatus(Int), invalidAudio, referenceTooLarge, invalidReference

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTPS generation URL or a localhost development URL."
        case .responseStatus(let status): "The generation service returned HTTP \(status)."
        case .invalidAudio: "The generation service must return a playable WAV under 100 MB."
        case .referenceTooLarge: "Choose a reference WAV under 20 MB."
        case .invalidReference: "Choose a valid WAV reference file."
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum StemService {
    static func endpointURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
        else { return nil }
        return parts.url
    }

    nonisolated static func generate(
        _ stem: StemRequest, at endpoint: URL, bearerToken: String, destination: URL
    ) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(stem)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (url, response) = try await session.download(for: request, delegate: NoRedirects())
        defer { try? FileManager.default.removeItem(at: url) }
        guard let http = response as? HTTPURLResponse else { throw StemServiceError.invalidAudio }
        guard (200..<300).contains(http.statusCode) else {
            throw StemServiceError.responseStatus(http.statusCode)
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (12...100_000_000).contains(size) else { throw StemServiceError.invalidAudio }
        let downloaded = try FileHandle(forReadingFrom: url)
        defer { try? downloaded.close() }
        guard isWave(try downloaded.read(upToCount: 12) ?? Data()) else {
            throw StemServiceError.invalidAudio
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: url, to: destination)
        do {
            let audio = try AVAudioFile(forReading: destination)
            guard audio.length > 0 else { throw StemServiceError.invalidAudio }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error is CancellationError { throw error }
            throw StemServiceError.invalidAudio
        }
    }
}
