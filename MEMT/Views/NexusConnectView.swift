import SwiftUI
import WebKit

/// Signs in to Nexus Mods. With an SSO application slug this is Nexus's one-click "authorize"
/// flow; otherwise the user signs in on the Nexus Mods page shown right here, and the app reads
/// their personal API key from it (or they paste it).
struct NexusConnectView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var page = WebPage()
    @State private var apiKey = ""
    @State private var error: String?
    @State private var isConnecting = false
    /// Set once the API Keys page has been opened after signing in, so it isn't reloaded in a loop.
    @State private var openedKeysPage = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if NexusSSO.isAvailable {
                ssoBody
            } else {
                webControls
                WebView(page)
                    .frame(minHeight: 380)
                    .onChange(of: page.isLoading) { _, isLoading in
                        if !isLoading { Task { await pageFinishedLoading() } }
                    }
                Divider()
                keyEntry
            }
        }
        .frame(width: 760, height: NexusSSO.isAvailable ? 320 : 680)
        .task {
            if !NexusSSO.isAvailable {
                page.load(URLRequest(url: Self.signInURL))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connect Nexus Mods").meHeading(size: 22)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(NexusSSO.isAvailable
                 ? "Sign in once and the \"Mod Manager Download\" button on Nexus Mods will download and install mods here."
                 : "Sign in to Nexus Mods below. That's it: the app picks up your account automatically and closes this window when it's connected.")
                .foregroundStyle(.secondary)
            N7Stripe()
        }
        .padding(20)
    }

    private var ssoBody: some View {
        VStack(spacing: 16) {
            Spacer()
            if isConnecting {
                ProgressView("Waiting for you to approve in your browser…")
            } else {
                Button {
                    Task { await logInWithSSO() }
                } label: {
                    Label("Log In with Nexus Mods", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(minWidth: 260)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(20)
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SecureField("Personal API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await connect() } }
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        apiKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                Button {
                    Task { await connect() }
                } label: {
                    if isConnecting { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.isEmpty || isConnecting)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
            } else if isConnecting {
                Label("Connecting your account…", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                Text("Your key is stored in your Mac's keychain and only sent to Nexus Mods.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private static let signInURL = URL(string: "https://users.nexusmods.com/auth/sign_in")!

    private var webControls: some View {
        HStack(spacing: 8) {
            Button("Back", systemImage: "chevron.backward") {
                if let item = page.backForwardList.backList.last { page.load(item) }
            }
            .labelStyle(.iconOnly)
            .disabled(page.backForwardList.backList.isEmpty)
            Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                .labelStyle(.iconOnly)
            Text(page.url?.host() ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if page.isLoading { ProgressView().controlSize(.small) }
            Button("Sign In") { page.load(URLRequest(url: Self.signInURL)) }
            Button("API Keys Page") {
                openedKeysPage = true
                page.load(URLRequest(url: NexusClient.apiKeysPageURL))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    /// Drives the flow without any clicks: sign in → API Keys page → read (or request) the key →
    /// connect. Runs after every page load.
    private func pageFinishedLoading() async {
        guard let host = page.url?.host()?.lowercased(), host.hasSuffix("nexusmods.com") else { return }

        // A password box means the user is still signing in; wait for them.
        let onSignInForm = "return !!document.querySelector('input[type=password]');"
        if (try? await page.callJavaScript(onSignInForm) as? Bool) == true { return }

        let deniedScript = "return document.body ? document.body.innerText.includes('Full authentication is required') : false;"
        if (try? await page.callJavaScript(deniedScript) as? Bool) == true {
            // Not signed in: show the sign-in page instead of "Access Denied".
            openedKeysPage = false
            page.load(URLRequest(url: Self.signInURL))
            return
        }

        if !isOnKeysPage {
            // Signed in (e.g. on the "Welcome back" account page): go straight to the API Keys page.
            if !openedKeysPage {
                openedKeysPage = true
                page.load(URLRequest(url: NexusClient.apiKeysPageURL))
            }
            return
        }
        await findKeyAndConnect()
    }

    /// The API Keys page, or wherever Nexus Mods redirected it to.
    private var isOnKeysPage: Bool {
        guard let url = page.url, url.host()?.lowercased().hasSuffix("nexusmods.com") == true else { return false }
        let address = url.absoluteString.lowercased()
        return openedKeysPage || address.contains("api-key") || address.contains("tab=api")
    }

    /// The API Keys page fills in after loading, so look for the key for a few seconds. If the
    /// account has no personal key yet, press "Request an API Key" once.
    private func findKeyAndConnect() async {
        guard apiKey.isEmpty, !isConnecting else { return }
        var requestedKey = false
        for _ in 0..<12 {
            if let key = await readKeyFromPage() {
                apiKey = key
                await connect()
                return
            }
            if !requestedKey, await pressRequestKeyButton() {
                requestedKey = true
            }
            try? await Task.sleep(for: .seconds(1))
            guard isOnKeysPage else { return }
        }
        error = "Couldn't find your API key on this page. Copy your Personal API Key and click Paste."
    }

    /// Looks for the personal API key on the Nexus Mods API Keys page the user is signed into.
    private func readKeyFromPage() async -> String? {
        let script = """
        const candidates = [...document.querySelectorAll('input, textarea')].map(e => e.value)
            .concat([...document.querySelectorAll('code, pre, [class*="key" i]')].map(e => e.textContent));
        const key = candidates.map(v => (v || '').trim()).find(v => /^[A-Za-z0-9+\\/=_-]{60,}$/.test(v));
        return key || null;
        """
        return try? await page.callJavaScript(script) as? String
    }

    /// Clicks the page's "Request an API Key" button for the personal key, if there is one.
    private func pressRequestKeyButton() async -> Bool {
        let script = """
        const button = [...document.querySelectorAll('button, a, input[type=submit]')]
            .find(e => /request\\s+(an\\s+)?api\\s+key/i.test((e.innerText || e.value || '').trim()));
        if (!button) return false;
        button.click();
        return true;
        """
        return (try? await page.callJavaScript(script) as? Bool) == true
    }

    private func connect() async {
        isConnecting = true
        error = await downloads.connectNexus(apiKey: apiKey)
        isConnecting = false
        if error == nil {
            await NXMHandler.makeDefault()
            dismiss()
        }
    }

    private func logInWithSSO() async {
        isConnecting = true
        error = nil
        do {
            let key = try await NexusSSO.logIn { url in
                Task { @MainActor in openURL(url) }
            }
            apiKey = key
            await connect()
        } catch {
            self.error = error.localizedDescription
        }
        isConnecting = false
    }
}

/// Makes this app open Nexus Mods "Mod Manager Download" (nxm://) links instead of Vortex or M3.
enum NXMHandler {
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "nxm://masseffectlegendaryedition/mods/1/files/1")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS may ask the user to confirm.
    static func makeDefault() async {
        try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "nxm")
    }
}
