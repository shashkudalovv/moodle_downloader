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

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

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

    /// Continues a login that can be completed without asking for credentials:
    /// either follows the Moodle SSO/IdP link or submits a form already filled by WebKit.
    func attemptAutomaticLogin() async -> Bool {
        let script = #"""
        (() => {
          const visible = element => {
            const style = getComputedStyle(element);
            return style.display !== 'none' && style.visibility !== 'hidden' && !element.disabled;
          };
          const links = [...document.querySelectorAll('a[href], button[data-href]')].filter(visible);
          const sso = links.find(element => {
            const href = (element.href || element.dataset.href || '').toLowerCase();
            const text = (element.textContent || element.getAttribute('aria-label') || '').toLowerCase();
            return href.includes('/auth/saml') || href.includes('/auth/oidc') ||
                   href.includes('/auth/oauth') || href.includes('idp=') ||
                   /\b(sso|single sign|innopolis account|university account|microsoft)\b/.test(text);
          });
          if (sso) {
            if (sso.href) location.assign(sso.href);
            else sso.click();
            return 'sso';
          }

          const username = document.querySelector('input[name="username"], input[type="email"]');
          const password = document.querySelector('input[name="password"], input[type="password"]');
          if (username?.value && password?.value) {
            const form = password.form || username.form;
            if (form) {
              if (form.requestSubmit) form.requestSubmit(); else form.submit();
              return 'filled-form';
            }
          }
          return 'manual';
        })()
        """#
        guard let result = try? await evaluate(script) else { return false }
        return result != "manual"
    }

    /// Requests the same Moodle Mobile credentials used by the open-source
    /// InNoHassle Tools extension. This runs only after a normal authenticated login.
    func captureMobileCredentials() async -> MoodleMobileCredentials? {
        let script = #"""
        (async () => {
          try {
            const launch = new URL('/admin/tool/mobile/launch.php', location.origin);
            launch.searchParams.set('service', 'moodle_mobile_app');
            launch.searchParams.set('passport', '1');
            launch.searchParams.set('confirmed', 'true');
            launch.searchParams.set('oauthsso', '1');
            const response = await fetch(launch.href, {credentials: 'include', redirect: 'follow'});
            const html = await response.text();
            const encoded = html.match(/"moodlemobile:\/\/token=([^"\\]+)"/)?.[1];
            if (!encoded) return '';
            const parts = atob(encoded).split(':::');
            const token = parts[1];
            const privateToken = parts[2];
            if (!token || !privateToken) return '';

            const form = new URLSearchParams({
              moodlewsrestformat: 'json',
              wsfunction: 'core_webservice_get_site_info',
              wstoken: token
            });
            const infoResponse = await fetch('/webservice/rest/server.php', {
              method: 'POST', credentials: 'include',
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: form.toString()
            });
            const info = await infoResponse.json();
            if (!Number.isInteger(info.userid)) return '';
            return JSON.stringify({token, privateToken, userID: info.userid});
          } catch (_) {
            return '';
          }
        })()
        """#
        guard let json = try? await evaluate(script), !json.isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MoodleMobileCredentials.self, from: data)
    }
}

struct MoodleWebView: NSViewRepresentable {
    @ObservedObject var session: MoodleWebSession

    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
