import SwiftUI
import SlyyMailKit

/// Server fields shared by setup and settings (the "Server settings" card in the wireframe).
struct ServerSettingsForm: View {
    @Binding var settings: AccountSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            endpoint("Incoming mail (IMAP)", $settings.imap)
            endpoint("Outgoing mail (SMTP)", $settings.smtp)
            field("User name", text: $settings.username, hint: nil)
            field("Calendar server (CalDAV)", text: $settings.caldavURL, hint: "Slyy finds your calendars from here. Empty turns the calendar off.")
            field("Video call server", text: $settings.jitsiURL, hint: nil)
        }
    }

    func endpoint(_ title: LocalizedStringKey, _ ep: Binding<ServerEndpoint>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            HStack(spacing: 10) {
                TextField("Server", text: ep.host)
                    .textFieldStyle(SlyyFieldStyle(padding: 8))
                    .serverField()
                    .frame(maxWidth: .infinity)
                TextField("Port", value: ep.port, format: .number.grouping(.never))
                    .textFieldStyle(SlyyFieldStyle(padding: 8))
                    .frame(width: 70)
                Picker("Security", selection: ep.security) {
                    Text("TLS").tag(ConnectionSecurity.tls)
                    Text("STARTTLS").tag(ConnectionSecurity.startTLS)
                    Text("None (local testing only)").tag(ConnectionSecurity.plain)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
                .padding(3)
                .hairlineBorder(Slyy.lineStrong)
            }
        }
    }

    func field(_ title: LocalizedStringKey, text: Binding<String>, hint: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Slyy.font(13))
            TextField("", text: text)
                .textFieldStyle(SlyyFieldStyle(padding: 8))
                .serverField()
            if let hint { Text(hint).font(Slyy.font(12)).foregroundStyle(Slyy.muted) }
        }
    }
}

extension View {
    func serverField() -> some View {
        #if os(iOS)
        return self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        return self.autocorrectionDisabled()
        #endif
    }
}

/// "Add your account" (wireframe 3).
struct AccountSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var settings: AccountSettings?
    @State private var showAdvanced = false
    @State private var working = false
    @State private var status = ""
    @State private var error: String?

    var emailValid: Bool { EmailAddress(address: email.trimmingCharacters(in: .whitespaces)).isValid }

    var body: some View {
        ScrollView {
            WrapCards {
                signInCard
                if showAdvanced, settings != nil {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Server settings").font(Slyy.font(18, .semibold))
                            Text("Shown when auto-detection fails, or to change what was found.").font(Slyy.font(13)).foregroundStyle(Slyy.muted)
                        }
                        ServerSettingsForm(settings: Binding(get: { settings! }, set: { settings = $0 }))
                        if let error { errorBox(error) }
                    }
                    .padding(28)
                    .frame(maxWidth: 520)
                    .background(Color.white)
                    .hairlineBorder()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .background(Slyy.sidebar)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    var signInCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SlyyLogo(size: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your account").font(Slyy.font(24, .semibold))
                Text("Mail, calendar and video calls on our own servers.").foregroundStyle(Slyy.muted)
            }
            labeled("Your name") {
                TextField("", text: $name).textFieldStyle(SlyyFieldStyle())
            }
            labeled("Email address") {
                TextField("you@slyy.ai", text: $email)
                    .textFieldStyle(SlyyFieldStyle())
                    .serverField()
                    .onSubmit { Task { await detect() } }
            }
            labeled("Password") {
                SecureField("", text: $password)
                    .textFieldStyle(SlyyFieldStyle())
                    .onSubmit { Task { await signIn() } }
                Text("Stored in the Keychain on this device only.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small).tint(.white) }
                    Text(working ? status : String(localized: "Sign in"))
                }
            }
            .buttonStyle(SlyyPrimaryButtonStyle(fullWidth: true, height: 44))
            .disabled(working || !emailValid || password.isEmpty)
            .keyboardShortcut(.defaultAction)

            if let s = settings {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Found automatically")
                    found("Mail in", "\(s.imap.host):\(s.imap.port) \(label(s.imap.security))")
                    found("Mail out", "\(s.smtp.host):\(s.smtp.port) \(label(s.smtp.security))")
                    found("Calendar", s.caldavURL.isEmpty ? String(localized: "not found") : (URL(string: s.caldavURL)?.host ?? s.caldavURL))
                    found("Video", URL(string: s.jitsiURL)?.host ?? s.jitsiURL)
                }
                .padding(12)
                .background(Slyy.panel)
            }
            Button(showAdvanced ? "Hide server settings" : "Server settings…") {
                Task {
                    if settings == nil { await detect() }
                    showAdvanced.toggle()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Slyy.accent)
            .disabled(!emailValid)
            if let error, !showAdvanced { errorBox(error) }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .background(Color.white)
        .hairlineBorder()
    }

    func label(_ s: ConnectionSecurity) -> String {
        switch s {
        case .tls: return "TLS"
        case .startTLS: return "STARTTLS"
        case .plain: return String(localized: "unencrypted")
        }
    }

    func found(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).font(Slyy.mono(12)).lineLimit(1).truncationMode(.middle)
        }
    }

    func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Slyy.font(14, .semibold))
            content()
        }
    }

    func errorBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Not signed in.").font(Slyy.font(13, .semibold))
            Text(text).font(Slyy.font(13))
        }
        .foregroundStyle(Color(rgb: 0x8A1C13))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Slyy.danger, lineWidth: 1))
    }

    func detect() async {
        let addr = email.trimmingCharacters(in: .whitespaces)
        guard EmailAddress(address: addr).isValid else { return }
        if let s = settings, s.email == addr { return }
        working = true
        status = String(localized: "Looking up server settings…")
        var s = await AutoConfig.discover(email: addr)
        s.displayName = name
        settings = s
        working = false
    }

    func signIn() async {
        guard emailValid, !password.isEmpty else { return }
        error = nil
        await detect()
        guard var s = settings else { return }
        s.email = email.trimmingCharacters(in: .whitespaces)
        s.displayName = name.trimmingCharacters(in: .whitespaces)
        if s.username.isEmpty { s.username = s.email }
        working = true
        status = String(localized: "Signing in…")
        defer { working = false }
        do {
            try await model.addAccount(s, password: password)
        } catch {
            self.error = SignInError.explain(error, settings: s)
            showAdvanced = true
        }
    }
}

/// Turns low-level failures into something a person can act on.
enum SignInError {
    static func explain(_ error: Error, settings s: AccountSettings) -> String {
        switch error {
        case IMAPError.authenticationFailed:
            return String(localized: "Email or password is wrong (mail server \(s.imap.host)).")
        case IMAPError.startTLSRequired:
            return String(localized: "\(s.imap.host) offers no STARTTLS; Slyy will not send your password unencrypted. Try port 993 with TLS.")
        case SMTPError.startTLSRequired:
            return String(localized: "\(s.smtp.host) offers no STARTTLS; Slyy will not send your password unencrypted. Try port 465 with TLS.")
        case SMTPError.unexpectedReply(let cmd, let code, _) where cmd.hasPrefix("AUTH") && code == 535:
            return String(localized: "The outgoing server \(s.smtp.host) rejected the password.")
        case TransportError.timeout:
            return String(localized: "No answer from \(s.imap.host). Check the server name and port.")
        case TransportError.connectionFailed, TransportError.closed:
            return String(localized: "Cannot reach \(s.imap.host):\(s.imap.port). Check the server name, port and your network.")
        default:
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return text
        }
    }
}

/// Places cards side by side when there is room, stacked otherwise.
struct WrapCards<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 40) { content() }
            VStack(spacing: 24) { content() }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AccountSettings?
    @State private var newPassword = ""
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Settings").font(Slyy.font(24, .semibold))
                    Spacer()
                    #if os(macOS)
                    Button("Done") { dismiss() }.buttonStyle(.slyyOutline)
                    #endif
                }
                if settings != nil {
                    HStack(spacing: 16) {
                        InitialsAvatar(name: settings!.displayName.isEmpty ? settings!.email : settings!.displayName, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings!.displayName.isEmpty ? settings!.email : settings!.displayName).font(Slyy.font(15, .semibold))
                            Text(settings!.email).font(Slyy.font(13)).foregroundStyle(Slyy.muted)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .hairlineBorder()

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Account")
                        labeled("Your name") {
                            TextField("", text: Binding(get: { settings!.displayName }, set: { settings!.displayName = $0 })).textFieldStyle(SlyyFieldStyle(padding: 8))
                        }
                        labeled("New password (leave empty to keep)") {
                            SecureField("", text: $newPassword).textFieldStyle(SlyyFieldStyle(padding: 8))
                        }
                        labeled("Signature") {
                            TextEditor(text: Binding(get: { settings!.signature }, set: { settings!.signature = $0 }))
                                .font(Slyy.body)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 70)
                                .padding(6)
                                .hairlineBorder(Slyy.lineStrong)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Reading")
                        Toggle("Group messages by conversation", isOn: Binding(get: { model.threaded }, set: { model.threaded = $0 }))
                            .toggleStyle(SlyyCheckboxStyle())
                    }
                    ServerSettingsForm(settings: Binding(get: { settings! }, set: { settings = $0 }))
                    HStack(spacing: 10) {
                        Button {
                            Task { await save() }
                        } label: {
                            HStack(spacing: 8) {
                                if saving { ProgressView().controlSize(.small).tint(.white) }
                                Text(saved ? "Saved" : "Save and reconnect")
                            }
                        }
                        .buttonStyle(SlyyPrimaryButtonStyle(height: 40))
                        .disabled(saving)
                        Spacer()
                        Button("Remove account…") { confirmRemove = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(Slyy.danger)
                    }
                    if let error { Text(error).font(Slyy.font(13)).foregroundStyle(Slyy.danger) }
                    Text("Removing the account deletes its password and cached mail from this device. Mail on the server is not touched.")
                        .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                } else {
                    Text("No account configured.").foregroundStyle(Slyy.muted)
                }
                UpdatesSection()
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .background(Color.white)
        .onAppear { settings = model.account }
        .confirmationDialog("Remove this account?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.removeAccount(); dismiss() } }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Slyy.font(13))
            content()
        }
    }

    func save() async {
        guard let s = settings else { return }
        saving = true
        error = nil
        saved = false
        defer { saving = false }
        do {
            try await model.updateAccount(s, password: newPassword)
            newPassword = ""
            saved = true
        } catch {
            self.error = SignInError.explain(error, settings: s)
        }
    }
}

/// Version and automatic updates (Mac).
struct UpdatesSection: View {
    @State private var auto = AppUpdater.shared.installsAutomatically
    @State private var checks = AppUpdater.shared.checksAutomatically

    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Updates")
                Spacer()
                Text(version).font(Slyy.mono(12))
            }
            if AppUpdater.shared.isAvailable {
                Toggle("Check for updates automatically", isOn: $checks)
                    .toggleStyle(SlyyCheckboxStyle())
                    .onChange(of: checks) { _, v in AppUpdater.shared.checksAutomatically = v }
                Toggle("Download and install updates automatically", isOn: $auto)
                    .toggleStyle(SlyyCheckboxStyle())
                    .disabled(!checks)
                    .onChange(of: auto) { _, v in AppUpdater.shared.installsAutomatically = v }
                HStack {
                    Button("Check now") { AppUpdater.shared.checkForUpdates() }
                        .buttonStyle(SlyyOutlineButtonStyle(strong: true))
                    if let last = AppUpdater.shared.lastCheck {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                    }
                }
                Text("Updates are signed by Slyy and notarized by Apple; they install when you quit the app.")
                    .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            } else {
                #if os(macOS)
                Text("Automatic updates are off in this build.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                #else
                Text("Updates arrive through TestFlight or the App Store.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                #endif
            }
        }
    }
}
