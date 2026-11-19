import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class StemSession {
    enum Instrument: String, CaseIterable {
        case any = "Any instrument"
        case vocals = "Vocals"
        case drums = "Drums"
        case bass = "Bass"
        case guitar = "Guitar"
        case keys = "Keys"
        case strings = "Strings"
        case synth = "Synth"
        case brass = "Brass"
        case percussion = "Percussion"
    }

    struct Cycle {
        let start: Double
        let end: Double
    }

    struct Take: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
    }

    var audioUnit: StemAudioUnit?
    var prompt = ""
    var instrument = Instrument.any
    var tempo = 120.0
    var bars = 4
    var key = ""
    var weirdness = 50.0
    var styleInfluence = 50.0
    var audioInfluence = 50.0
    var referenceURL: URL?
    var useCycleAudio = false
    private(set) var progressText = "Generating stem…"
    private(set) var cycle: Cycle?
    private(set) var meterNumerator = 4
    private(set) var meterDenominator = 4
    private(set) var takes: [Take] = []
    private(set) var generating = false
    private(set) var playing: UUID?
    var status: String?

    @ObservationIgnored var authenticationWindow: (() -> NSWindow?)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LogicBridge-\(UUID().uuidString)", isDirectory: true)

    deinit {
        work?.cancel()
        playbackTask?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    func useLogicCycle() {
        guard let host = audioUnit?.hostSnapshot, host.tempo.isFinite, (1...999).contains(host.tempo) else {
            status = "Logic hasn’t supplied tempo yet. Start playback and try again."
            return
        }
        applyHostContext(host)
        status = cycle == nil ? "Tempo copied. Turn on Logic’s Cycle to capture its range." : nil
    }

    private func applyHostContext(_ host: StemHostSnapshot) {
        tempo = (host.tempo * 100).rounded() / 100
        meterNumerator = host.numerator.isFinite && (1...64).contains(host.numerator) ? Int(host.numerator) : 4
        meterDenominator = (1...64).contains(host.denominator) ? host.denominator : 4
        cycle = host.hasCycle.boolValue ? Cycle(start: host.cycleStart, end: host.cycleEnd) : nil
    }

    func useManualRange() {
        cycle = nil
        status = nil
    }

    func generate(endpoint: String, token: String) {
        guard !generating else { return }
        let description = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        guard let url = StemService.endpointURL(endpoint) else {
            status = StemServiceError.invalidEndpoint.localizedDescription
            return
        }

        let captureRequested = useCycleAudio
        let renderer = audioUnit?.cycleCapture
        if captureRequested {
            guard renderer != nil else {
                status = CycleAudio.CaptureError.inactive.localizedDescription
                return
            }
            player?.stop()
        }

        let instrument = instrument.rawValue
        let tempo = tempo
        let meterNumerator = meterNumerator
        let meterDenominator = meterDenominator
        let cycle = cycle
        let beats = cycle.map { $0.end - $0.start } ?? Double(bars * meterNumerator) * 4 / Double(meterDenominator)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let weirdness = Int(weirdness)
        let styleInfluence = Int(styleInfluence)
        let audioInfluence = Int(audioInfluence)
        let referenceURL = referenceURL
        let directory = directory
        let takeNumber = takes.count + 1
        generating = true
        progressText = captureRequested ? "Play Logic with Cycle enabled…" : "Generating stem…"
        status = nil

        work = Task { [weak self] in
            do {
                let capture: CycleAudio?
                let reference: ReferenceAudio?
                if captureRequested, let renderer {
                    capture = try await CycleAudio.capture(using: renderer) {
                        self?.progressText = "Capturing the Logic Cycle…"
                    }
                    reference = capture?.reference
                    if let capture { self?.applyHostContext(capture.context) }
                } else {
                    capture = nil
                    reference = try await Task.detached(priority: .userInitiated) {
                        try referenceURL.map(ReferenceAudio.load(from:))
                    }.value
                }
                try Task.checkCancellation()
                self?.progressText = "Generating stem…"
                let host = capture?.context
                let stem = StemRequest(
                    prompt: description, instrument: instrument, tempoBPM: host?.tempo ?? tempo,
                    timeSignatureNumerator: host.flatMap { (1...64).contains($0.numerator) ? Int($0.numerator) : nil } ?? meterNumerator,
                    timeSignatureDenominator: host.flatMap { (1...64).contains($0.denominator) ? $0.denominator : nil } ?? meterDenominator,
                    durationBeats: host.map { $0.cycleEnd - $0.cycleStart } ?? beats,
                    cycleStartBeat: host?.cycleStart ?? cycle?.start, key: key.isEmpty ? nil : key,
                    weirdness: weirdness, styleInfluence: styleInfluence,
                    audioInfluence: reference == nil ? nil : audioInfluence, reference: reference
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let title = "Take \(takeNumber)"
                let destination = directory.appendingPathComponent("\(title).wav")
                try await StemService.generate(stem, at: url, bearerToken: token, destination: destination)
                guard let self else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                self.takes.insert(Take(title: title, url: destination), at: 0)
            } catch is CancellationError {
                self?.status = "Generation cancelled."
            } catch {
                self?.status = Task.isCancelled ? "Generation cancelled." : error.localizedDescription
            }
            self?.generating = false
            self?.work = nil
        }
    }

    func cancel() { work?.cancel() }

    func togglePlayback(_ take: Take) {
        let shouldPlay = playing != take.id
        player?.stop()
        playbackTask?.cancel()
        playing = nil
        guard shouldPlay else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: take.url)
            guard player.play() else {
                status = "Couldn’t play \(take.title)."
                return
            }
            self.player = player
            playing = take.id
            playbackTask = Task { [weak self] in
                repeat {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                } while self?.player?.isPlaying == true
                self?.playing = nil
                self?.player = nil
            }
        } catch {
            status = error.localizedDescription
        }
    }
}
