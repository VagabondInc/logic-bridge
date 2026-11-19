import SwiftUI
import UniformTypeIdentifiers

struct TakeFile: FileDocument {
    static let readableContentTypes: [UTType] = [.wav]

    private let source: URL

    init(url: URL) { source = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: source, options: .immediate)
    }
}
