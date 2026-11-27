import SwiftUI
import SlyyMailKit

/// Server fields shared by setup and settings (the "Server settings" card in the wireframe).
struct ServerSettingsForm: View {
    enum Part { case mail, calendar, video }
    @Binding var settings: AccountSettings
    var parts: Set<Part> = [.mail, .calendar, .video]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if parts.contains(.mail) {
                endpoint("Incoming mail (IMAP)", $settings.imap)
                endpoint("Outgoing mail (SMTP)", $settings.smtp)
                field("User name", text: $settings.username, hint: nil)
            }
            if parts.contains(.calendar) {
                field("Calendar server (CalDAV)", text: $settings.caldavURL, hint: "Slyy finds your calendars from here. Empty turns the calendar off.")
            }
            if parts.contains(.video) {
                field("Video call server", text: $settings.jitsiURL, hint: "Jitsi Meet server for new meetings and \u{201C}Meet now\u{201D}.")
            }
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
    /// Pre-filled address (screenshots, mailto with an unknown account).
    var initialEmail = ""
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var settings: AccountSettings?
    @State private var showAdvanced = false
    @State private var working = false
    @State private var status = ""
    @State private var error: String?

    var emailValid: Bool { EmailAddress(address: email.trimmingCharacters(in: .whitespaces)).isValid }
    /// Google: known from a gmail.com address at once, or for Workspace domains after the server lookup.
    var provider: KnownProvider? {
        guard emailValid else { return nil }
        let addr = email.trimmingCharacters(in: .whitespaces)
        if let p = KnownProvider.detect(email: addr) { return p }
        if let s = settings, s.email == addr { return KnownProvider.forSettings(s) }
        return nil
    }

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
        .onAppear { if email.isEmpty { email = initialEmail } }
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
            if let p = provider { AppPasswordGuide(provider: p, workspace: KnownProvider.isWorkspace(email)) }
            labeled(provider == nil ? "Password" : "App password") {
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
        // Google shows app passwords in groups of four ("abcd efgh ijkl mnop"): the spaces are not part of it.
        if provider != nil { password = password.replacingOccurrences(of: " ", with: "") }
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
    static func isAuthFailure(_ error: Error) -> Bool {
        switch error {
        case IMAPError.authenticationFailed: return true
        case SMTPError.unexpectedReply(let cmd, let code, _) where cmd.hasPrefix("AUTH") && (code == 535 || code == 534): return true
        default: return false
        }
    }

    static func explain(_ error: Error, settings s: AccountSettings) -> String {
        if let p = KnownProvider.forSettings(s), isAuthFailure(error) {
            return String(localized: "\(p.name) refused the password. \(p.name) needs an app password here, not your normal password: follow the steps above.")
        }
        switch error {
        case let e as OAuthError:
            return e.errorDescription ?? "\(e)"
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

enum SettingsTab: String, CaseIterable, Identifiable {
    case mail, calendar, video
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .video: "Video Calls"
        }
    }
    var icon: String {
        switch self {
        case .mail: SlyyIcon.mail
        case .calendar: SlyyIcon.calendar
        case .video: SlyyIcon.video
        }
    }
    var sections: [SettingsSection] {
        switch self {
        case .mail:
            #if os(macOS)
            return [.account, .senders, .reading, .assistant, .servers, .updates]
            #else
            return [.account, .senders, .reading, .assistant, .servers]
            #endif
        case .calendar: return [.calendarServer, .calendars]
        case .video: return [.videoServer, .rooms]
        }
    }
}

/// One form in Settings. Each saves on its own.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case account, senders, reading, assistant, servers, updates
    case calendarServer, calendars
    case videoServer, rooms
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .account: "Account"
        case .senders: "Sender Addresses"
        case .reading: "Reading and Writing"
        case .assistant: "Assistant"
        case .servers: "Servers"
        case .updates: "Updates"
        case .calendarServer: "Calendar Server"
        case .calendars: "Shown Calendars"
        case .videoServer: "Video Server"
        case .rooms: "Room Links"
        }
    }
    var tab: SettingsTab { SettingsTab.allCases.first { $0.sections.contains(self) } ?? .mail }
}

/// Settings: tabs (Mail · Calendar · Video Calls) on top, the tab's sections on the left, one form on the right.
/// On iPhone the sections are a list that opens each form.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State var tab: SettingsTab = .mail
    @State var section: SettingsSection = .account

    var compact: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(Slyy.font(24, .semibold))
                Spacer()
                #if os(macOS)
                Button("Done") { dismiss() }
                    .buttonStyle(.slyyOutline)
                    .keyboardShortcut(.cancelAction) // Esc
                #else
                // iPad with a keyboard: Esc closes Settings when it is shown as a sheet.
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                #endif
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 14)
            tabBar
            if model.account == nil {
                Text("No account configured.").foregroundStyle(Slyy.muted).padding(24)
                Spacer()
            } else if compact {
                sectionList
            } else {
                HStack(spacing: 0) {
                    sidebar
                    ScrollView {
                        // Same margin left and right of the form; centred when the window is wider.
                        SettingsSectionView(section: section)
                            .frame(maxWidth: 600, alignment: .leading)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 28)
                            .frame(maxWidth: .infinity)
                    }
                    .id(section) // each form starts from the saved settings
                }
            }
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .background(Color.white)
        .onChange(of: tab) { _, t in if section.tab != t { section = t.sections[0] } }
        .onAppear { if section.tab != tab { section = tab.sections[0] } }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// Underlined tabs in the Slyy style: Mail · Calendar · Video Calls.
    var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(SettingsTab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 8) {
                        Label(t.title, systemImage: t.icon)
                            .labelStyle(.titleAndIcon)
                            .font(Slyy.font(14, tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Slyy.ink : Slyy.muted)
                            .lineLimit(1)
                            .fixedSize()
                        Rectangle().fill(tab == t ? Slyy.accent : Color.clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .bottomHairline()
    }

    /// Left pane: the sections of the current tab.
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tab.sections) { s in
                Button { section = s } label: {
                    HStack(spacing: 0) {
                        Rectangle().fill(section == s ? Slyy.accent : Color.clear).frame(width: 2)
                        Text(s.title)
                            .font(Slyy.font(14, section == s ? .semibold : .regular))
                            .foregroundStyle(section == s ? Slyy.ink : Slyy.ink2)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true) // rows keep their height; the list sits at the top
                    .background(section == s ? Slyy.panel : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == s ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.vertical, 20)
        .padding(.leading, 18) // row text lines up with "Settings" and the tabs above
        .frame(width: 200, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .trailingHairline()
    }

    /// iPhone: sections as a list; each opens its form.
    var sectionList: some View {
        List {
            ForEach(tab.sections) { s in
                NavigationLink {
                    ScrollView { SettingsSectionView(section: s).padding(18) }
                        .background(Color.white)
                        .navigationTitle(Text(s.title))
                } label: {
                    Text(s.title).font(Slyy.font(15))
                }
            }
        }
        .listStyle(.plain)
    }
}

/// The form for one section, with its own copy of the settings and its own Save.
struct SettingsSectionView: View {
    @Environment(AppModel.self) private var model
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(section.title).font(Slyy.font(18, .semibold))
            switch section {
            case .account: AccountForm()
            case .senders: SendersForm()
            case .reading: ReadingForm()
            case .assistant: HavenSection()
            case .servers: ServersForm()
            case .updates: UpdatesSection()
            case .calendarServer: CalendarServerForm()
            case .calendars: ShownCalendarsForm()
            case .videoServer: VideoServerForm()
            case .rooms: RoomLinksInfo()
            }
        }
    }
}

/// Save row shared by the forms: disabled until something changed, "Saved" after.
struct SectionSaveBar: View {
    let title: LocalizedStringKey
    let changed: Bool
    let state: SaveState
    let action: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { Task { await action() } } label: {
                    HStack(spacing: 8) {
                        if state.saving { ProgressView().controlSize(.small).tint(.white) }
                        Text(title)
                    }
                }
                .buttonStyle(SlyyPrimaryButtonStyle(height: 40))
                .disabled(!changed || state.saving)
                if state.saved && !changed {
                    Label("Saved", systemImage: "checkmark").font(Slyy.font(13)).foregroundStyle(Slyy.muted)
                }
            }
            if let e = state.error { Text(e).font(Slyy.font(13)).foregroundStyle(Slyy.danger) }
        }
        .padding(.top, 4)
    }
}

struct SaveState {
    var saving = false
    var saved = false
    var error: String?
}

/// Saves one section: only the fields `apply` writes are taken over into the current settings,
/// so unsaved edits in other sections are never saved along with it.
@MainActor
func saveSection(_ model: AppModel, state: Binding<SaveState>, reconnect: Bool, password: String? = nil, apply: (inout AccountSettings) -> Void) async -> Bool {
    guard var s = model.account else { return false }
    apply(&s)
    state.wrappedValue = SaveState(saving: true)
    do {
        if reconnect || !(password ?? "").isEmpty {
            try await model.updateAccount(s, password: password)
        } else {
            model.saveSettings(s)
        }
        state.wrappedValue = SaveState(saved: true)
        return true
    } catch {
        state.wrappedValue = SaveState(error: SignInError.explain(error, settings: s))
        return false
    }
}

func settingsField<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(Slyy.font(13))
        content()
    }
}

struct AccountForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var signature = ""
    @State private var password = ""
    @State private var state = SaveState()
    @State private var confirmRemove = false

    var changed: Bool {
        guard let a = model.account else { return false }
        return name != a.displayName || signature != a.signature || !password.isEmpty
    }

    var body: some View {
        if let a = model.account {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    InitialsAvatar(name: a.displayName.isEmpty ? a.email : a.displayName, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.displayName.isEmpty ? a.email : a.displayName).font(Slyy.font(15, .semibold))
                        Text(a.email).font(Slyy.font(13)).foregroundStyle(Slyy.muted)
                    }
                    Spacer()
                }
                .padding(16)
                .hairlineBorder()
                settingsField("Your name") { TextField("", text: $name).textFieldStyle(SlyyFieldStyle(padding: 8)) }
                settingsField(KnownProvider.forSettings(a) == nil ? "New password (leave empty to keep)" : "New app password (leave empty to keep)") {
                    SecureField("", text: $password).textFieldStyle(SlyyFieldStyle(padding: 8))
                }
                settingsField("Signature") {
                    TextEditor(text: $signature)
                        .font(Slyy.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 70)
                        .padding(6)
                        .hairlineBorder(Slyy.lineStrong)
                }
                SectionSaveBar(title: password.isEmpty ? "Save" : "Save and reconnect", changed: changed, state: state) {
                    let n = name, sig = signature, pw = password
                    if await saveSection(model, state: $state, reconnect: false, password: pw, apply: { $0.displayName = n; $0.signature = sig }) {
                        password = ""
                    }
                }
                Divider().padding(.vertical, 6)
                Button("Remove account…") { confirmRemove = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Slyy.danger)
                Text("Removing the account deletes its password and cached mail from this device. Mail on the server is not touched.")
                    .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
            .onAppear { name = a.displayName; signature = a.signature }
            .confirmationDialog("Remove this account?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { Task { await model.removeAccount(); dismiss() } }
            }
        }
    }
}

struct SendersForm: View {
    @Environment(AppModel.self) private var model
    @State private var aliases: [SenderIdentity] = []
    @State private var defaultSender: String?
    @State private var state = SaveState()

    var changed: Bool {
        guard let a = model.account else { return false }
        return aliases != (a.aliases ?? []) || defaultSender != a.defaultSender
    }

    var body: some View {
        if let a = model.account {
            VStack(alignment: .leading, spacing: 14) {
                AliasesEditor(aliases: $aliases, primary: a.email, defaultSender: $defaultSender)
                SectionSaveBar(title: "Save", changed: changed, state: state) {
                    // Keep only valid, distinct aliases that are not the account address itself.
                    var seen = Set([a.email.lowercased()])
                    let clean = aliases.filter { x in
                        EmailAddress(address: x.email.trimmingCharacters(in: .whitespaces)).isValid && seen.insert(x.email.lowercased()).inserted
                    }
                    var def = defaultSender
                    if let d = def, !clean.contains(where: { $0.email.caseInsensitiveCompare(d) == .orderedSame }) { def = nil }
                    if await saveSection(model, state: $state, reconnect: false, apply: { $0.aliases = clean; $0.defaultSender = def }) {
                        aliases = clean
                        defaultSender = def
                    }
                }
            }
            .onAppear { aliases = a.aliases ?? []; defaultSender = a.defaultSender }
        }
    }
}

struct ReadingForm: View {
    @Environment(AppModel.self) private var model
    @AppStorage("notifyNewMail") private var notifyNewMail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Group messages by conversation", isOn: Binding(get: { model.threaded }, set: { model.threaded = $0 }))
                .toggleStyle(SlyyCheckboxStyle())
            Toggle("Notify me about new mail", isOn: $notifyNewMail)
                .toggleStyle(SlyyCheckboxStyle())
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { model.blueReplies }, set: { model.blueReplies = $0 })) {
                    Text("Write my replies in colour")
                }
                .toggleStyle(SlyyCheckboxStyle())
                ColorPicker("Reply colour", selection: Binding(get: { model.replyColor }, set: { model.replyColorHex = $0.hexString }), supportsOpacity: false)
                    .labelsHidden()
                    .disabled(!model.blueReplies)
                Text("Sample reply").font(Slyy.font(14, .semibold)).foregroundStyle(model.blueReplies ? model.replyColor : Slyy.muted)
                if model.replyColorHex != Slyy.replyDefaultHex {
                    Button("Slyy blue") { model.replyColorHex = Slyy.replyDefaultHex }
                        .buttonStyle(.slyyOutline)
                }
            }
            Toggle("Auto-save mails while writing (also survives a crash)", isOn: Binding(get: { model.autoSave }, set: { model.autoSave = $0 }))
                .toggleStyle(SlyyCheckboxStyle())
            Text("These apply right away.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
        }
    }
}

struct ServersForm: View {
    @Environment(AppModel.self) private var model
    @State private var draft: AccountSettings?
    @State private var state = SaveState()

    var changed: Bool {
        guard let d = draft, let a = model.account else { return false }
        return d.imap != a.imap || d.smtp != a.smtp || d.username != a.username
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft != nil {
                ServerSettingsForm(settings: Binding(get: { draft! }, set: { draft = $0 }), parts: [.mail])
                SectionSaveBar(title: "Save and reconnect", changed: changed, state: state) {
                    guard let d = draft else { return }
                    _ = await saveSection(model, state: $state, reconnect: true, apply: { $0.imap = d.imap; $0.smtp = d.smtp; $0.username = d.username })
                }
            }
        }
        .onAppear { draft = model.account }
    }
}

struct CalendarServerForm: View {
    @Environment(AppModel.self) private var model
    @State private var draft: AccountSettings?
    @State private var state = SaveState()

    var changed: Bool { draft?.caldavURL != model.account?.caldavURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft != nil {
                ServerSettingsForm(settings: Binding(get: { draft! }, set: { draft = $0 }), parts: [.calendar])
                SectionSaveBar(title: "Save and reconnect", changed: changed, state: state) {
                    let url = draft?.caldavURL ?? ""
                    _ = await saveSection(model, state: $state, reconnect: true, apply: { $0.caldavURL = url })
                }
                Text("Invitations go out as standard iCalendar mails, so Outlook, Apple Calendar and Gmail can answer them.")
                    .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
        }
        .onAppear { draft = model.account }
    }
}

struct ShownCalendarsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.calendars.isEmpty {
                Text((model.account?.caldavURL ?? "").isEmpty ? "The calendar is off: no calendar server set." : "No calendars loaded yet.")
                    .font(Slyy.font(13)).foregroundStyle(Slyy.muted)
            }
            ForEach(model.calendars) { c in
                Toggle(isOn: Binding(
                    get: { !model.hiddenCalendars.contains(c.url) },
                    set: { on in if on { model.hiddenCalendars.remove(c.url) } else { model.hiddenCalendars.insert(c.url) } }
                )) {
                    HStack(spacing: 8) {
                        Text(c.name)
                        if c.isReadOnly { MonoTag(text: "read-only", background: Slyy.muted) }
                    }
                }
                .toggleStyle(SlyyCheckboxStyle())
            }
            Text("These apply right away.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
        }
    }
}

struct VideoServerForm: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var state = SaveState()

    var changed: Bool { server != (model.account?.jitsiURL ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsField("Video call server") {
                TextField("", text: $server).textFieldStyle(SlyyFieldStyle(padding: 8)).serverField()
            }
            Text("Jitsi Meet server for new meetings and \u{201C}Meet now\u{201D}.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            HStack(spacing: 10) {
                Button("Use default") { server = JitsiRoom.defaultServer }
                    .buttonStyle(.slyyOutline)
                    .disabled(server == JitsiRoom.defaultServer)
                Button { model.meetNow() } label: { Label("Test call", systemImage: SlyyIcon.video) }
                    .buttonStyle(SlyyOutlineButtonStyle(strong: true))
            }
            SectionSaveBar(title: "Save", changed: changed, state: state) {
                let url = server.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = await saveSection(model, state: $state, reconnect: false, apply: { $0.jitsiURL = url })
            }
        }
        .onAppear { server = model.account?.jitsiURL ?? JitsiRoom.defaultServer }
    }
}

struct RoomLinksInfo: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("New rooms look like")
            Text(JitsiRoom.newURL(server: model.account?.jitsiURL ?? JitsiRoom.defaultServer).absoluteString)
                .font(Slyy.mono(12)).foregroundStyle(Slyy.ink2).textSelection(.enabled)
            Text("Every meeting gets its own unguessable room name. Meetings and \u{201C}Meet now\u{201D} add the link to invitations automatically.")
                .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
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
                Text("Installed version").font(Slyy.font(13))
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
                #if os(macOS)
                CleanupRow()
                #endif
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

#if os(macOS)
/// Last automatic cleanup of old installers and the pre-rename app, plus "Clean up now".
struct CleanupRow: View {
    @State private var summary = UserDefaults.standard.string(forKey: "cleanup.lastSummary")
    @State private var running = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(running ? "Cleaning…" : "Clean up now") {
                running = true
                let cleanup = InstallerCleanup.live()
                Task.detached(priority: .utility) {
                    let report = cleanup.run()
                    await MainActor.run {
                        UserDefaults.standard.set(report.summary, forKey: "cleanup.lastSummary")
                        summary = report.summary
                        running = false
                    }
                }
            }
            .buttonStyle(SlyyOutlineButtonStyle(strong: true))
            .disabled(running)
            Text(summary ?? String(localized: "Old installers and app copies are removed automatically after each update."))
                .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
        }
    }
}
#endif

/// Extra From addresses on the same mailbox, each with an optional name and signature.
struct AliasesEditor: View {
    @Binding var aliases: [SenderIdentity]
    let primary: String
    /// Address new mails start from; nil = the account address.
    @Binding var defaultSender: String?

    func isDefault(_ email: String) -> Bool {
        guard let d = defaultSender, !d.isEmpty else { return email.caseInsensitiveCompare(primary) == .orderedSame }
        return d.caseInsensitiveCompare(email) == .orderedSame
    }

    /// "Default" radio: one address is the sender of new mails.
    func defaultToggle(_ email: String) -> some View {
        let on = isDefault(email)
        return Button {
            defaultSender = email.caseInsensitiveCompare(primary) == .orderedSame ? nil : email.lowercased()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Slyy.accent : Slyy.lineStrong)
                Text("Default").font(Slyy.font(12)).foregroundStyle(on ? Slyy.ink : Slyy.muted)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(!EmailAddress(address: email).isValid)
        .accessibilityLabel("Default sender")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send as other addresses of this mailbox (e.g. info@ or rechnung@). New mails start from the default address; replies go out from the address a mail was sent to. The mail server must allow sending as these addresses.")
                .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            HStack(spacing: 8) {
                Text(primary).font(Slyy.font(14))
                MonoTag(text: "ACCOUNT", background: Slyy.ink2)
                Spacer()
                defaultToggle(primary)
            }
            .padding(10)
            .hairlineBorder()
            ForEach($aliases) { $a in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Address", text: $a.email)
                            .textFieldStyle(SlyyFieldStyle(padding: 8))
                            .serverField()
                        TextField("Name (optional)", text: $a.name)
                            .textFieldStyle(SlyyFieldStyle(padding: 8))
                        defaultToggle(a.email)
                        Button {
                            if isDefault(a.email) { defaultSender = nil }
                            aliases.removeAll { $0.id == a.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Slyy.danger)
                            .accessibilityLabel("Remove \(a.email)")
                    }
                    TextField("Signature for this address (optional)", text: $a.signature, axis: .vertical)
                        .textFieldStyle(SlyyFieldStyle(padding: 8))
                    if let problem = problem(a) {
                        Text(problem).font(Slyy.font(12)).foregroundStyle(Slyy.danger)
                    }
                }
                .padding(10)
                .hairlineBorder()
            }
            Button {
                aliases.append(SenderIdentity(email: ""))
            } label: { Label("Add address", systemImage: "plus") }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true))
        }
    }

    func problem(_ a: SenderIdentity) -> String? {
        if a.email.isEmpty { return nil }
        if !EmailAddress(address: a.email).isValid { return String(localized: "Not a valid email address.") }
        if a.email.caseInsensitiveCompare(primary) == .orderedSame { return String(localized: "This is already the account address.") }
        if aliases.filter({ $0.email.caseInsensitiveCompare(a.email) == .orderedSame }).count > 1 { return String(localized: "Listed twice.") }
        return nil
    }
}

/// Assistant status: Slyy Haven provides models and data sources; Mailr never holds AI keys.
struct HavenSection: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(model.havenState == .connected ? Slyy.accent : Slyy.lineStrong).frame(width: 8, height: 8)
                Text(status).font(Slyy.font(13))
                Spacer()
                Button(checking ? "Checking…" : "Check again") {
                    checking = true
                    Task { await model.connectHaven(); checking = false }
                }
                .buttonStyle(.slyyOutline)
                .disabled(checking)
            }
            Text(hint).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
        }
    }

    var status: String {
        switch model.havenState {
        case .connected: return String(localized: "Connected to Slyy Haven")
        case .notInstalled, .unknown: return String(localized: "Install Slyy Haven to use AI in Mailr")
        case .failed(let m): return m
        }
    }

    var hint: String {
        #if os(macOS)
        return String(localized: "With Slyy Haven, \u{201C}Ask Haven\u{201D} at the bottom of the writer and the reader drafts mails, schedules meetings and creates tasks from your connected data sources. Models, keys and connections are set up in Slyy Haven.")
        #else
        return String(localized: "Ask Haven is available in Slyy Mailr on the Mac.")
        #endif
    }
}

/// Steps for a Google app password, with a link to the right page. Google Workspace adds what the admin must allow.
struct AppPasswordGuide: View {
    let provider: KnownProvider
    var workspace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace ? "Google Workspace needs an app password" : "Gmail needs an app password")
                .font(Slyy.font(14, .semibold))
            VStack(alignment: .leading, spacing: 4) {
                step(1, "Turn on 2-Step Verification in your Google account (app passwords need it).")
                step(2, "Open Google\u{2019}s app-password page and create one named \u{201C}Slyy Mailr\u{201D}.")
                step(3, "Paste the 16-letter password below. Spaces don\u{2019}t matter.")
            }
            Button {
                openExternally(provider.appPasswordURL)
            } label: {
                Label("Open Google app passwords", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Slyy.accent)
            if workspace {
                Text("If the page says app passwords are not available, your Google Workspace admin has to allow 2-Step Verification and IMAP access for your account (Admin console \u{2192} Security and Apps \u{2192} Gmail \u{2192} End user access).")
                    .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
            Text("Mail works fully. Google calendars can\u{2019}t be used with an app password, so the calendar stays off for this account.")
                .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
        }
        .font(Slyy.font(13))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Slyy.tint)
    }

    func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Slyy.mono(11)).foregroundStyle(Slyy.accent)
            Text(text)
        }
    }
}
