import AVFoundation

final class StemAudioUnit: AUAudioUnit {
    private let renderer = StemRender()
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var internalRenderBlock: AUInternalRenderBlock { renderer.makeBlock() }
    var hostSnapshot: StemHostSnapshot { renderer.snapshot() }
    var cycleCapture: StemRender { renderer }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let input = try AUAudioUnitBus(format: format)
        let output = try AUAudioUnitBus(format: format)
        input.maximumChannelCount = 2
        output.maximumChannelCount = 2
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
    }

    override var channelCapabilities: [NSNumber]? { [1, 1, 2, 2] }

    override func allocateRenderResources() throws {
        guard inputs[0].format == outputs[0].format else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        let format = outputs[0].format
        renderer.setCaptureSampleRate(
            format.commonFormat == .pcmFormatFloat32 ? format.sampleRate : 0,
            channels: format.channelCount, nonInterleaved: !format.isInterleaved
        )
        renderer.setMusicalContext(musicalContextBlock, transport: transportStateBlock)
    }

    override func deallocateRenderResources() {
        renderer.setCaptureSampleRate(0, channels: 0, nonInterleaved: true)
        renderer.setMusicalContext(nil, transport: nil)
        super.deallocateRenderResources()
    }
}
