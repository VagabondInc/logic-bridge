import SwiftUI
import WebKit

enum SupportDestination {
    static let automaticPromptDelay: Duration = .seconds(300)
    static let hasShownKey = "didShowSupportPrompt"
    static let visibleSecondsKey = "supportEditorVisibleSeconds"

    static var paymentURL: URL? {
        let bundle = Bundle(for: StemViewController.self)
        guard let value = bundle.object(forInfoDictionaryKey: "LogicBridgeDonationURL") as? String,
              let url = URL(string: value),
              url.scheme == "https", url.host() == "buy.stripe.com",
              url.port == nil, url.user() == nil, url.password() == nil,
              url.query() == nil, url.fragment() == nil, url.path().count > 1
        else { return nil }
        return url
    }
}

struct SupportSheet: View {
    let paymentURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var checkingOut = false
    private let mint = Color(red: 0.62, green: 0.93, blue: 0.79)

    var body: some View {
        VStack(spacing: 0) {
            if checkingOut {
                HStack {
                    Text("Support Logic Bridge").font(.headline)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(15)
                StripeCheckout(url: paymentURL)
            } else {
                artwork
                VStack(alignment: .leading, spacing: 14) {
                    Text("A little support goes a long way.")
                        .font(.system(size: 28, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("I’m an independent developer and a fellow Suno fan. I built Logic Bridge because I wanted to stay in the session while trying out a new part.")
                    Text("If it’s made creating a little easier for you, a one-time tip helps cover the time it takes to keep building and testing it.")
                    Text("Thanks for giving it a spin.")
                        .foregroundStyle(mint)
                    HStack(spacing: 14) {
                        Button("Leave a tip") { checkingOut = true }
                            .buttonStyle(.borderedProminent)
                            .tint(mint)
                            .controlSize(.large)
                        Button("Continue making music") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.top, 5)
                }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.87))
                .padding(26)
            }
        }
        .frame(width: checkingOut ? 560 : 486, height: checkingOut ? 630 : nil)
        .background(Color(red: 0.055, green: 0.076, blue: 0.084))
        .preferredColorScheme(.dark)
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.06, green: 0.19, blue: 0.17),
                                    Color(red: 0.14, green: 0.10, blue: 0.23)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            Canvas { context, size in
                for band in 0..<8 {
                    var trace = Path()
                    let base = size.height * (0.28 + Double(band) * 0.066)
                    for offset in 0...112 {
                        let x = Double(offset) / 112
                        let envelope = pow(sin(.pi * x), 2) * (0.55 + Double(band) * 0.055)
                        let y = base + sin(x * 34 + Double(band) * 0.42) * 20 * envelope
                        let point = CGPoint(x: size.width * x, y: y)
                        if offset == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                    }
                    context.stroke(trace, with: .color(mint.opacity(0.13 + Double(band) * 0.045)),
                                   lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
            Label("Logic Bridge", systemImage: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(mint)
                .padding(24)
        }
        .frame(height: 153)
    }
}

private struct StripeCheckout: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Navigation { Navigation() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Navigation: NSObject, WKNavigationDelegate, WKUIDelegate {
        private func isCheckout(_ url: URL?) -> Bool {
            guard let url, url.scheme == "https", let host = url.host()?.lowercased() else { return false }
            return host == "stripe.com" || host.hasSuffix(".stripe.com")
                || host == "link.com" || host.hasSuffix(".link.com")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Embedded bank authentication frames may use HTTPS at the issuer.
            if action.targetFrame?.isMainFrame == false {
                let scheme = action.request.url?.scheme
                decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
                return
            }
            decisionHandler(isCheckout(action.request.url) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if isCheckout(action.request.url) { webView.load(action.request) }
            return nil
        }
    }
}
