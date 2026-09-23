import AuthenticationServices
import Security
import UIKit
import WebKit

/// The broker rejects this app's custom scheme as a redirect. The HTTPS relay returns to
/// this app-owned scheme, without starting a second web/Supabase session.
enum OAuthConfiguration {
    static let callbackScheme = "app.lovable.dream-language"
    static let callbackHost = "oauth"
    static let callbackPath = "/callback"
    static let relayPath = "/auth/native-callback.html"
    static let providerHosts: Set<String> = [
        "accounts.google.com", "appleid.apple.com", "oauth.lovable.app"
    ]

    static func isAppURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        return url.scheme == "https" && url.host == rootUrl.host &&
            (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func isCallback(_ url: URL) -> Bool {
        url.scheme == callbackScheme && url.host == callbackHost &&
            url.path == callbackPath && url.port == nil && url.user == nil && url.password == nil
    }
}

final class OAuthBridge: NSObject, ASWebAuthenticationPresentationContextProviding {
    private weak var webView: WKWebView?
    private weak var presentingWindow: UIWindow?
    private var session: ASWebAuthenticationSession?
    private var timeout: DispatchWorkItem?
    private var activeState: String?
    private var sourceFrame: WKFrameInfo?
    private var documentID: String?

    func signIn(message: WKScriptMessage, window: UIWindow?) {
        // Never accept bridge requests from a subframe or another origin.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == rootUrl.host,
              [0, 443].contains(message.frameInfo.securityOrigin.port),
              let view = message.webView, OAuthConfiguration.isAppURL(view.url) else { return }

        // The web contract has no request IDs: do not emit a second result that
        // could accidentally settle the original request's listener.
        guard activeState == nil else { return }
        webView = view
        sourceFrame = message.frameInfo
        presentingWindow = window

        guard let body = message.body as? [String: Any],
              let provider = body["provider"] as? String,
              ["google", "apple"].contains(provider),
              let redirect = body["redirect_uri"] as? String,
              let redirectURL = URL(string: redirect),
              OAuthConfiguration.isAppURL(redirectURL),
              redirectURL.path == "/auth/callback",
              redirectURL.query == nil, redirectURL.fragment == nil else {
            send(["ok": false, "error": "Invalid sign-in request."])
            return
        }
        guard window != nil else {
            send(["ok": false, "error": "Sign-in window is unavailable. Please try again."])
            return
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            send(["ok": false, "error": "Unable to start secure sign-in."])
            return
        }
        let state = bytes.map { String(format: "%02x", $0) }.joined()
        activeState = state

        // Capture a marker on the initiating document before opening the sheet.
        // A reload/navigation must never deliver old credentials to a new page.
        view.callAsyncJavaScript("return window.__dreamOAuthDocumentID;", arguments: [:],
                                 in: message.frameInfo, in: .page) { [weak self] result in
            guard let self = self, self.activeState == state else { return }
            guard case .success(let value) = result, let marker = value as? String else {
                self.finish(["ok": false, "error": "Sign-in page changed. Please try again."])
                return
            }
            self.documentID = marker
            self.startSession(provider: provider, state: state)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.activeState == state else { return }
            self.finish(["ok": false, "error": "Sign-in timed out. Please try again."])
        }
        timeout = work
        // Finish before nativeAuth.ts removes its listener at 180 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 170, execute: work)
    }

    private func startSession(provider: String, state: String) {
        guard var relay = URLComponents(url: rootUrl, resolvingAgainstBaseURL: false) else { return }
        relay.path = OAuthConfiguration.relayPath
        relay.queryItems = [URLQueryItem(name: "native_state", value: state)]
        relay.fragment = nil
        guard let relayURL = relay.url,
              var initiate = URLComponents(url: rootUrl, resolvingAgainstBaseURL: false) else { return }
        initiate.path = "/~oauth/initiate"
        initiate.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_uri", value: relayURL.absoluteString),
            URLQueryItem(name: "state", value: state)
        ]
        initiate.fragment = nil
        guard let url = initiate.url else { return }
        let authSession = ASWebAuthenticationSession(
            url: url, callbackURLScheme: OAuthConfiguration.callbackScheme
        ) { [weak self] callback, error in
            DispatchQueue.main.async {
                guard let self = self, self.activeState == state else { return }
                if let error = error {
                    let cancelled = (error as NSError).domain == ASWebAuthenticationSessionError.errorDomain &&
                        (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                    self.finish(["ok": false, "error": cancelled ? "Sign-in cancelled." : "Sign-in could not complete. Please try again."])
                } else if let callback = callback {
                    self.receive(callback, expectedState: state)
                } else {
                    self.finish(["ok": false, "error": "Sign-in returned no result."])
                }
            }
        }
        authSession.presentationContextProvider = self
        session = authSession // Retain until completion, cancellation or timeout.
        if !authSession.start() {
            finish(["ok": false, "error": "Unable to open the sign-in window."])
        }
    }

    private func receive(_ url: URL, expectedState: String) {
        guard OAuthConfiguration.isCallback(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            finish(["ok": false, "error": "Invalid sign-in callback."])
            return
        }
        var fragment = URLComponents()
        fragment.percentEncodedQuery = components.percentEncodedFragment
        let items = (components.queryItems ?? []) + (fragment.queryItems ?? [])
        var values: [String: String] = [:]
        for item in items {
            // Ambiguous state/token parameters are never accepted.
            guard values[item.name] == nil, let value = item.value else {
                finish(["ok": false, "error": "Invalid sign-in callback parameters."])
                return
            }
            values[item.name] = value
        }
        guard values["state"] == expectedState else {
            finish(["ok": false, "error": "Sign-in verification failed. Please try again."])
            return
        }
        if values["error"] != nil {
            // Do not log callback URLs, tokens, or arbitrary provider error text.
            finish(["ok": false, "error": "The provider did not complete sign-in. Please try again."])
            return
        }
        guard let access = values["access_token"], !access.isEmpty,
              let refresh = values["refresh_token"], !refresh.isEmpty else {
            finish(["ok": false, "error": "Sign-in returned no session. Please try again."])
            return
        }
        finish(["ok": true, "access_token": access, "refresh_token": refresh])
    }

    private func finish(_ payload: [String: Any]) {
        activeState = nil
        timeout?.cancel()
        timeout = nil
        let previous = session
        session = nil
        previous?.cancel()
        send(payload)
        documentID = nil
        sourceFrame = nil
        presentingWindow = nil
    }

    private func send(_ payload: [String: Any]) {
        guard let view = webView, OAuthConfiguration.isAppURL(view.url), let frame = sourceFrame else { return }
        // Structured arguments, never string interpolation of OAuth data.
        // Check origin and document again in JavaScript at execution time.
        view.callAsyncJavaScript("""
            if (window.top !== window || location.origin !== origin) return;
            if (marker && window.__dreamOAuthDocumentID !== marker) return;
            window.dispatchEvent(new CustomEvent('oauth-result', {detail: payload}));
            """, arguments: ["payload": payload, "origin": "https://" + (rootUrl.host ?? ""),
                             "marker": documentID ?? ""], in: frame, in: .page,
                                 completionHandler: nil)
    }

    func cancelForNavigation() {
        guard activeState != nil else { return }
        finish(["ok": false, "error": "Sign-in interrupted by page navigation. Please try again."])
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // A window is checked before start; retain the same scene's window.
        presentingWindow ?? ASPresentationAnchor()
    }

    deinit {
        timeout?.cancel()
        session?.cancel()
    }
}
