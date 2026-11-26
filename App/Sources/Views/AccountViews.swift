import SwiftUI
import SlyyMailKit

/// Server fields shared by setup and settings.
struct ServerSettingsForm: View {
    @Binding var settings: AccountSettings

    var body: some View {
        Section("Incoming mail (IMAP)") {
            TextField("Server", text: $settings.imap.host).serverField()
            TextField("Port", value: $settings.imap.port, format: .number.grouping(.never))
            SecurityPicker(security: $settings.imap.security)
        }
        Section("Outgoing mail (SMTP)") {
            TextField("Server", text: $settings.smtp.host).serverField()
            TextField("Port", value: $settings.smtp.port, format: .number.grouping(.never))
            SecurityPicker(security: $settings.smtp.security)
        }
        Section {
            TextField("User name", text: $settings.username).serverField()
        } footer: {
            Text("Usually your email address.")
        }
        Section {
            TextField("CalDAV URL", text: $settings.caldavURL).serverField()
            TextField("Video call server", text: $settings.jitsiURL).serverField()
        } header: {
            Text("Calendar and video")
        } footer: {
            Text("Calendar server root, e.g. https://mail.example.com/ — Slyy finds your calendars automatically. Leave empty to turn the calendar off.")
        }
    }
}

struct SecurityPicker: View {
    @Binding var security: ConnectionSecurity

    var body: some View {
        Picker("Security", selection: $security) {
            Text("TLS").tag(ConnectionSecurity.tls)
            Text("STARTTLS").tag(ConnectionSecurity.startTLS)
            Text("None (local testing only)").tag(ConnectionSecurity.plain)
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slyy Mailr").font(.largeTitle.weight(.bold))
                        Text("Mail, calendar and video calls on your own servers.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    TextField("Your name", text: $name)
                    TextField("Email address", text: $email)
                        .serverField()
                        .onSubmit { Task { await detect() } }
                    SecureField("Password", text: $password)
                }
                if showAdvanced, settings != nil {
                    ServerSettingsForm(settings: Binding(get: { settings! }, set: { settings = $0 }))
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? status : String(localized: "Sign In"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !EmailAddress(address: email).isValid || password.isEmpty)
                    Button(showAdvanced ? "Hide server settings" : "Server settings…") {
                        Task {
                            if settings == nil { await detect() }
                            showAdvanced.toggle()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!EmailAddress(address: email).isValid)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Account")
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
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
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showAdvanced = true
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
        Form {
            if settings != nil {
                Section("Account") {
                    TextField("Your name", text: Binding(get: { settings!.displayName }, set: { settings!.displayName = $0 }))
                    LabeledContent("Email", value: settings!.email)
                    SecureField("New password (leave empty to keep)", text: $newPassword)
                }
                Section("Signature") {
                    TextEditor(text: Binding(get: { settings!.signature }, set: { settings!.signature = $0 }))
                        .frame(minHeight: 70)
                }
                ServerSettingsForm(settings: Binding(get: { settings! }, set: { settings = $0 }))
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            if saving { ProgressView().controlSize(.small) }
                            Text(saved ? "Saved" : "Save and reconnect")
                        }
                    }
                    .disabled(saving)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Remove Account…", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Removes the account, its password and cached mail from this device. Mail on the server is not touched.")
                }
            } else {
                Text("No account configured.")
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { settings = model.account }
        .confirmationDialog("Remove this account?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.removeAccount(); dismiss() } }
        }
        #if os(iOS)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        #endif
    }

    func save() async {
        guard let s = settings else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await model.updateAccount(s, password: newPassword)
            newPassword = ""
            saved = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
