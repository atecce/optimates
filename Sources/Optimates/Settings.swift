import Foundation
import Security
import SwiftUI

/// Where the equities API is and how to get through Cloudflare Access to it,
/// kept in the Keychain.
///
/// A person signs in to Access with their email (accessToken, from
/// AccessLoginView). The Mac and scripts use Access's service token instead:
/// set here, or from the environment (CF_ACCESS_CLIENT_ID and
/// CF_ACCESS_CLIENT_SECRET, as simulator.sh passes them). EQUITIES_API in the
/// environment points the app at another address, such as a local
/// `equities-api --no-access`.
struct ServerSettings: Equatable {
    var url = ""
    var accessClientId = ""
    var accessClientSecret = ""
    var accessToken = ""

    /// Through Cloudflare, from anywhere.
    static let cloudflareURL = "https://api.atec.pub"

    private static let environment = ProcessInfo.processInfo.environment

    /// The API's address: the one set here, else EQUITIES_API, else Cloudflare's.
    var serverURL: URL {
        for candidate in [url, Self.environment["EQUITIES_API"] ?? ""] {
            if let u = URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines)), u.host != nil { return u }
        }
        return URL(string: Self.cloudflareURL)!
    }

    var session: AccessSession? { accessToken.isEmpty ? nil : AccessSession(token: accessToken) }

    /// The service token set here, else the environment's.
    var serviceToken: (id: String, secret: String)? {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !trim(accessClientId).isEmpty, !trim(accessClientSecret).isEmpty {
            return (trim(accessClientId), trim(accessClientSecret))
        }
        if let id = Self.environment["CF_ACCESS_CLIENT_ID"], let secret = Self.environment["CF_ACCESS_CLIENT_SECRET"],
           !id.isEmpty, !secret.isEmpty {
            return (id, secret)
        }
        return nil
    }

    static func load() -> ServerSettings {
        // Before the API, the app read InfluxDB directly: its address, its
        // token and the Access session for influx.atec.pub are no use now.
        for old in ["url", "token", "accessToken"] where Keychain.get(old) != nil {
            Keychain.set(old, "")
        }
        return ServerSettings(
            url: Keychain.get("apiURL") ?? "",
            accessClientId: Keychain.get("accessClientId") ?? "",
            accessClientSecret: Keychain.get("accessClientSecret") ?? "",
            accessToken: Keychain.get("apiAccessToken") ?? "")
    }

    func save() {
        Keychain.set("apiURL", url)
        Keychain.set("accessClientId", accessClientId)
        Keychain.set("accessClientSecret", accessClientSecret)
        Keychain.set("apiAccessToken", accessToken)
    }
}

/// Strings in the Keychain, this device only (not synced through iCloud).
enum Keychain {
    private static let service = "pub.atec.optimates"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ServerSettings.load()
    @State private var signingIn = false
    /// Called after saving, to load again.
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let session = settings.session, !session.isExpired {
                        LabeledContent("Signed in as", value: session.email ?? "unknown")
                        if let expires = session.expires {
                            LabeledContent("Until", value: expires.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Sign out", role: .destructive) {
                            settings.accessToken = ""
                            ReplyCache.shared.clear()
                        }
                    } else {
                        Button(settings.session == nil ? "Sign in with email" : "Session expired: sign in again") {
                            signingIn = true
                        }
                    }
                } header: {
                    Text("Cloudflare Access")
                } footer: {
                    Text("Your email and a one-time code from Cloudflare, for \(settings.serverURL.host ?? "the server").")
                }
                Section {
                    TextField(ServerSettings.cloudflareURL, text: $settings.url)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    DisclosureGroup("Service token (Mac and scripts)") {
                        TextField("client ID", text: $settings.accessClientId)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        SecureField("client secret", text: $settings.accessClientSecret)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Empty address: \(ServerSettings.cloudflareURL). The service token, instead of signing in: equities-app, in ~/.cloudflared/equities-app.env on the Mac.")
                }
            }
            .navigationTitle("Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settings.save()
                        onSave()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $signingIn) {
                AccessLoginView(url: settings.serverURL.appendingPathComponent("health")) { token in
                    // Kept at once: a sign-in shouldn't be lost to Cancel.
                    settings.accessToken = token
                    Keychain.set("apiAccessToken", token)
                    onSave()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}
