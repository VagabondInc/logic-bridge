import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct StemPanel: View {
    @Bindable var session: StemSession
    @AppStorage("generationEndpoint") private var endpoint = ""
    @AppStorage("browserAuthSettings") private var browserSettingsData = Data()
    @State private var connectionCredential: ConnectionCredential?
    @State private var browserTask: Task<Void, Never>?
    @State private var sunoCredential: BrowserCredential?
    @State private var draftBrowserAuth = false
    @State private var draftBrowserSettings = BrowserAuthSettings()
    @State private var showConnection = false
    @State private var pickingReference = false
    @State private var advanced = false
    @State private var exportTake: StemSession.Take?
    @State private var exportingTake = false
    @State private var draftEndpoint = ""
    @State private var draftToken = ""

    private let accent = Color(red: 0.68, green: 0.94, blue: 0.79)
    private let card = Color.white.opacity(0.055)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                header
                context
                composer
                advancedControls
                actionBar
                if !session.takes.isEmpty { takes }
            }
            .padding(22)
        }
        .frame(minWidth: 525, idealWidth: 640, minHeight: 525, idealHeight: 610)
        .background(Color(red: 0.07, green: 0.09, blue: 0.10))
        .preferredColorScheme(.dark)
        .tint(accent)
        .fileImporter(isPresented: $pickingReference, allowedContentTypes: [.wav]) { result in
            switch result {
            case .success(let url): session.referenceURL = url
            case .failure(let error): session.status = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $exportingTake, document: exportTake.map { TakeFile(url: $0.url) },
            contentType: .wav, defaultFilename: exportTake?.title
        ) { result in
            if case .failure(let error) = result { session.status = error.localizedDescription }
            exportTake = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            Text("Stem Generator")
                .font(.system(size: 26, weight: .semibold))
            Spacer()
            Button {
                if let browserTask { browserTask.cancel() } else { openConnection() }
            } label: {
                Label(connectionTitle, systemImage: endpointURL == nil ? "link" : "gearshape")
            }
            .disabled(session.generating)
            .popover(isPresented: $showConnection, arrowEdge: .bottom) {
                connection
            }
        }
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Session range").font(.headline)
                Spacer()
                Button("Read Logic Cycle", systemImage: "arrow.trianglehead.clockwise") {
                    session.useLogicCycle()
                }
            }
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    TextField("Tempo", value: $session.tempo, format: .number)
                        .frame(width: 62)
                        .accessibilityLabel("Tempo")
                    Text("BPM").foregroundStyle(.secondary)
                }
                if let cycle = session.cycle {
                    Text("\((cycle.end - cycle.start).formatted(.number.precision(.fractionLength(0...2)))) beats")
                        .monospacedDigit()
                        .accessibilityLabel("Cycle length in beats")
                    Button("Set bars manually") { session.useManualRange() }
                } else {
                    Picker("Length", selection: $session.bars) {
                        ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { count in
                            Text(count == 1 ? "1 bar" : "\(count) bars").tag(count)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("\(session.meterNumerator)/\(session.meterDenominator)")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Time signature")
                Spacer()
                TextField("Key (optional)", text: $session.key)
                    .frame(width: 105)
            }
        }
        .padding(13)
        .background(card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Describe the part").font(.headline)
                Spacer()
                Picker("Instrument", selection: $session.instrument) {
                    ForEach(StemSession.Instrument.allCases, id: \.self) { instrument in
                        Text(instrument.rawValue).tag(instrument)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.prompt)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 82)
                    .accessibilityLabel("Generation prompt")
                if session.prompt.isEmpty {
                    Text("Describe the sound, mood, or playing style…")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .background(.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Toggle("Use Cycle Audio", isOn: $session.useCycleAudio).toggleStyle(.switch)
                    .disabled(session.generating)
                Spacer()
                if !session.useCycleAudio {
                    Button("Reference WAV", systemImage: "paperclip") { pickingReference = true }
                }
                if !session.useCycleAudio, let reference = session.referenceURL {
                    Text(reference.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    Button("Remove reference", systemImage: "xmark.circle") { session.referenceURL = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                }
            }
            if session.useCycleAudio {
                Text("Generate captures one Logic Cycle from this insert and sends it to the generation service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var advancedControls: some View {
        DisclosureGroup("Advanced controls", isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 8) {
                control("Weirdness", value: $session.weirdness)
                control("Style Influence", value: $session.styleInfluence)
                control("Audio Influence", value: $session.audioInfluence)
                    .disabled(!session.useCycleAudio && session.referenceURL == nil)
                HStack {
                    Toggle("Auto Insert", isOn: .constant(false))
                        .toggleStyle(.switch)
                        .disabled(true)
                    Spacer()
                    Text("Drag takes to the Tracks area").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 9)
        }
        .padding(13)
        .background(card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func control(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 105, alignment: .leading)
            Slider(value: value, in: 0...100, step: 1) { Text(label) }
                .labelsHidden()
            Text("\(Int(value.wrappedValue))%")
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if session.generating {
                    ProgressView().controlSize(.small)
                    Text(session.progressText)
                    Spacer()
                    Button("Cancel") { session.cancel() }
                } else {
                    Text(endpointURL?.host() ?? "Connect a generation service to create takes.")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Generate Stem", systemImage: "sparkles") {
                        if let accessToken {
                            session.generate(endpoint: endpoint, token: accessToken)
                        } else {
                            openConnection()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .controlSize(.large)
                    .disabled(endpointURL == nil || browserTask != nil || session.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !session.tempo.isFinite || !(1...999).contains(session.tempo))
                }
            }
            if let status = session.status {
                Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var takes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Takes").font(.headline)
            ForEach(session.takes) { take in
                HStack(spacing: 10) {
                    Button {
                        session.togglePlayback(take)
                    } label: {
                        Label(session.playing == take.id ? "Stop \(take.title)" : "Play \(take.title)",
                              systemImage: session.playing == take.id ? "stop.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                    }
                    Text(take.title)
                    Spacer()
                    Button("Save WAV", systemImage: "square.and.arrow.down") {
                        exportTake = take
                        exportingTake = true
                    }
                    Label("Drag to Logic", systemImage: "waveform")
                        .foregroundStyle(accent)
                        .padding(7)
                        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                        .onDrag {
                            NSItemProvider(contentsOf: take.url) ?? NSItemProvider(object: take.url as NSURL)
                        }
                }
            }
        }
        .padding(13)
        .background(card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var endpointURL: URL? { StemService.endpointURL(endpoint) }

    private var savedBrowserSettings: BrowserAuthSettings? {
        try? JSONDecoder().decode(BrowserAuthSettings.self, from: browserSettingsData)
    }

    private struct ConnectionCredential {
        let endpoint: String
        let settings: Data
        let credential: BrowserCredential
    }

    private var accessToken: String? {
        if let connected = connectionCredential, connected.endpoint == endpoint,
           connected.settings == browserSettingsData {
            return connected.credential.activeToken
        }
        return browserSettingsData.isEmpty ? "" : nil
    }

    private var connectionTitle: String {
        if browserTask != nil { return "Cancel sign-in" }
        if endpointURL == nil { return "Connect service" }
        if savedBrowserSettings != nil && accessToken == nil { return "Sign in" }
        return "Service settings"
    }

    private func openConnection() {
        draftEndpoint = endpoint
        draftToken = savedBrowserSettings == nil ? (accessToken ?? "") : ""
        draftBrowserAuth = savedBrowserSettings != nil
        draftBrowserSettings = savedBrowserSettings ?? BrowserAuthSettings()
        showConnection = true
    }

    private func connect() {
        guard let destination = StemService.endpointURL(draftEndpoint) else { return }
        if !draftBrowserAuth {
            let manual = BrowserCredential(
                token: draftToken.trimmingCharacters(in: .whitespacesAndNewlines), expiresAt: nil
            )
            endpoint = destination.absoluteString
            browserSettingsData = Data()
            connectionCredential = ConnectionCredential(endpoint: endpoint, settings: Data(), credential: manual)
            draftToken = ""
            showConnection = false
            return
        }

        guard let anchor = session.authenticationWindow?() else {
            session.status = BrowserSignInError.unavailable.localizedDescription
            showConnection = false
            return
        }
        let configuration = draftBrowserSettings
        session.status = nil
        showConnection = false
        browserTask = Task { @MainActor in
            defer { browserTask = nil }
            do {
                let browser = BrowserSignIn(window: anchor)
                let credential = try await browser.signIn(settings: configuration)
                try Task.checkCancellation()
                let settings = try JSONEncoder().encode(configuration)
                endpoint = destination.absoluteString
                browserSettingsData = settings
                connectionCredential = ConnectionCredential(endpoint: endpoint, settings: settings, credential: credential)
                draftToken = ""
                session.status = "Signed in to the generation service."
            } catch {
                let cancelled = error is CancellationError
                    || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                session.status = cancelled ? "Sign-in cancelled." : error.localizedDescription
            }
        }
    }

    private func connectSuno() {
        session.status = nil
        showConnection = false
        browserTask = Task { @MainActor in
            defer { browserTask = nil }
            do {
                let credential = try await SunoSignIn.connect()
                try Task.checkCancellation()
                sunoCredential = credential
                session.status = "Suno account connected. Configure a stem generation service in connection settings."
            } catch {
                session.status = error is CancellationError ? "Sign-in cancelled." : error.localizedDescription
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Suno account").font(.headline)
                Spacer()
                if sunoCredential?.activeToken != nil {
                    Button("Sign Out") {
                        sunoCredential = nil
                        session.status = nil
                    }
                } else {
                    Button("Sign in with Suno", action: connectSuno)
                }
            }
            Divider()
            Text("Generation service").font(.headline)
            TextField("HTTPS endpoint", text: $draftEndpoint)
            Picker("Authentication", selection: $draftBrowserAuth) {
                Text("Bearer token").tag(false)
                Text("Browser sign-in").tag(true)
            }
            .pickerStyle(.segmented)
            if draftBrowserAuth {
                TextField("Authorization URL", text: $draftBrowserSettings.authorizationURL)
                TextField("Token URL", text: $draftBrowserSettings.tokenURL)
                TextField("Registered public client ID", text: $draftBrowserSettings.clientID)
                TextField("Scope (optional)", text: $draftBrowserSettings.scope)
                LabeledContent("Redirect URI", value: BrowserAuthorization.redirectURL)
                    .font(.caption)
                    .textSelection(.enabled)
            } else {
                SecureField("Bearer token (optional)", text: $draftToken)
            }
            Text("Generate sends your prompt, session settings, and your Cycle audio or reference WAV to this URL.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !endpoint.isEmpty {
                    Button("Disconnect") {
                        endpoint = ""
                        draftToken = ""
                        connectionCredential = nil
                        browserSettingsData = Data()
                        showConnection = false
                    }
                }
                Spacer()
                Button("Cancel") { showConnection = false }
                Button(draftBrowserAuth ? "Sign In" : "Use Service", action: connect)
                    .disabled(StemService.endpointURL(draftEndpoint) == nil
                              || (draftBrowserAuth && !draftBrowserSettings.isComplete))
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
