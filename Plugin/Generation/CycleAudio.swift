import Foundation

struct CycleAudio {
    let context: StemHostSnapshot
    let reference: ReferenceAudio

    enum CaptureError: LocalizedError {
        case inactive, interrupted, tooLong, unavailable, timedOut

        var errorDescription: String? {
            switch self {
            case .inactive: "Play audio through this insert, then try Generate Stem again."
            case .interrupted: "Logic’s transport or Cycle changed during capture. Try again with a fixed range."
            case .tooLong: "Cycle audio exceeded 20 MiB. Shorten the Cycle and try again."
            case .unavailable: "Logic didn’t supply usable audio for this Cycle."
            case .timedOut: "Cycle audio timed out. Enable Cycle and play the selected range through this insert."
            }
        }
    }

    @MainActor
    static func capture(using renderer: StemRender, onRecording: () -> Void) async throws -> CycleAudio {
        guard renderer.armCycleCapture() else { throw CaptureError.inactive }
        defer { renderer.cancelCycleCapture() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))

        while clock.now < deadline {
            try Task.checkCancellation()
            switch renderer.captureStatus() {
            case .waiting:
                break
            case .recording:
                onRecording()
            case .complete:
                var context = StemHostSnapshot()
                guard let wav = renderer.takeCycleWAV(withContext: &context) else {
                    throw CaptureError.unavailable
                }
                return CycleAudio(context: context, reference: ReferenceAudio(filename: "Logic Cycle.wav", wav: wav))
            case .rangeChanged:
                throw CaptureError.interrupted
            case .tooLong:
                throw CaptureError.tooLong
            case .idle, .unavailable:
                throw CaptureError.unavailable
            @unknown default:
                throw CaptureError.unavailable
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw CaptureError.timedOut
    }
}
