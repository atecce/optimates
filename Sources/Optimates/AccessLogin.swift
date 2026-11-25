import Foundation
import SwiftUI
import WebKit

/// A Cloudflare Access session: the `CF_Authorization` token Access sets on
/// the server's domain once a person is through its login (for
/// influx.atec.pub, an email one-time code; the 家人 (jiārén) policy). The
/// Rust client sends it as `cf-access-token`.
struct AccessSession {
    let token: String

    /// The token's claims (a JWT: header.payload.signature, base64url). Read
    /// only to show who is signed in and until when; Cloudflare checks the
    /// signature.
    private var claims: [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    var email: String? { claims["email"] as? String }

    var expires: Date? {
        (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    var isExpired: Bool { expires.map { $0 <= Date() } ?? false }
}

/// Access's login page for `url`, in a private web view. When Access sets
/// `CF_Authorization` (the login is done), `onToken` gets it.
struct AccessLoginView: View {
    let url: URL
    let onToken: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccessWebView(url: url) { token in
                onToken(token)
                dismiss()
            }
            .navigationTitle("Sign in")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }
}

#if os(iOS)
private typealias Representable = UIViewRepresentable
#else
private typealias Representable = NSViewRepresentable
#endif

private struct AccessWebView: Representable {
    let url: URL
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(host: url.host, onToken: onToken) }

    private func make(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing kept between sign-ins, nor shared with Safari.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #endif

    final class Coordinator: NSObject, WKNavigationDelegate {
        let host: String?
        let onToken: (String) -> Void
        private var done = false

        init(host: String?, onToken: @escaping (String) -> Void) {
            self.host = host
            self.onToken = onToken
        }

        /// After each page: has Access set the session cookie on the server's
        /// own domain (not the team's login domain)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard !self.done, let host = self.host,
                      let cookie = cookies.first(where: { $0.name == "CF_Authorization" && host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) })
                else { return }
                self.done = true
                DispatchQueue.main.async { self.onToken(cookie.value) }
            }
        }
    }
}
