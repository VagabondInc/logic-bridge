import AudioToolbox
import CoreAudioKit
import SwiftUI

final class StemViewController: AUViewController, AUAudioUnitFactory {
    private let model = StemSession()

    override func loadView() {
        let host = NSHostingController(rootView: StemPanel(session: model))
        addChild(host)
        view = host.view
        model.authenticationWindow = { [weak self] in self?.view.window }
        preferredContentSize = NSSize(width: 640, height: 610)
    }

    nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try StemAudioUnit(componentDescription: componentDescription, options: [])
        Task { @MainActor [weak self] in self?.model.audioUnit = unit }
        return unit
    }
}
