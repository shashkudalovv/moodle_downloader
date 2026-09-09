import SwiftUI
import WebKit

@MainActor
final class MoodleWebSession: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    var onNavigationFinished: ((URL) -> Void)?
    var onNavigationFailed: ((Error) -> Void)?
    @Published var currentURL: URL?
    @Published var isLoading = false
    @Published var pageTitle = "Moodle"

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
        pageTitle = webView.title ?? "Moodle"
        if let url = webView.url { onNavigationFinished?(url) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        onNavigationFailed?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        onNavigationFailed?(error)
    }

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goHome() {
        if let url = URL(string: "https://moodle.innopolis.university/my/courses.php") {
            webView.load(URLRequest(url: url))
        }
    }

    func evaluate(_ javascript: String) async throws -> String {
        // evaluateJavaScript returns a JS Promise as an unsupported object.
        // callAsyncJavaScript awaits it inside WebKit and bridges only the final JSON string.
        let value = try await webView.callAsyncJavaScript(
            "return await (\(javascript));",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let string = value as? String else { throw ScraperError.invalidResult }
        return string
    }

    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
    }
}

struct MoodleWebView: NSViewRepresentable {
    @ObservedObject var session: MoodleWebSession

    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
