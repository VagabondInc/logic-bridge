import AppKit
import Foundation

private let demoName = "Logic Bridge Demo"

private enum DemoError: LocalizedError {
    case missingProject, missingLogic, invalidMusicFolder

    var errorDescription: String? {
        switch self {
        case .missingProject: "The bundled Logic Bridge demo is missing. Reinstall Logic Bridge."
        case .missingLogic: "Install Logic Pro, then open Logic Bridge again to launch the demo."
        case .invalidMusicFolder: "The Logic Bridge demo folder is unavailable."
        }
    }
}

private func prepareDemo(in folder: URL) throws -> URL {
    let files = FileManager.default
    guard let template = Bundle.main.url(forResource: demoName, withExtension: "logicx", subdirectory: "Demo") else {
        throw DemoError.missingProject
    }
    let folder = folder.appendingPathComponent("Logic Bridge", isDirectory: true)
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("\(demoName).logicx", isDirectory: true)

    func existingProject() throws -> Bool {
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { throw DemoError.invalidMusicFolder }
        return true
    }

    if try existingProject() { return destination }

    // Copy beside the final path so an incomplete copy never becomes the project.
    let staging = folder.appendingPathComponent(".demo-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: staging) }
    try files.copyItem(at: template, to: staging)
    do {
        try files.moveItem(at: staging, to: destination)
    } catch {
        guard try existingProject() else { throw error }
    }
    return destination
}

@MainActor
private final class DemoLauncher: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let files = FileManager.default
                let music = try files.url(for: .musicDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let project = try prepareDemo(in: music)
                let workspace = NSWorkspace.shared
                guard let logic = workspace.urlForApplication(withBundleIdentifier: "com.apple.logic10") else {
                    throw DemoError.missingLogic
                }
                _ = try await workspace.open([project], withApplicationAt: logic, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Couldn’t open the Logic Bridge demo"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            NSApp.terminate(nil)
        }
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--prepare-demo-in" {
    do {
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        print(try prepareDemo(in: folder).path)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let launcher = DemoLauncher()
        app.setActivationPolicy(.accessory)
        app.delegate = launcher
        app.run()
    }
}
