import SwiftUI
import SlyyMailKit

struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent
    @State private var confirmDelete = false

    var isMine: Bool { model.account.map { event.isOrganized(by: $0.email) } ?? true }
    var myStatus: ParticipationStatus? { model.account.flatMap { event.status(of: $0.email) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(event.summary.isEmpty ? String(localized: "New Event") : event.summary)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Label(EventFormat.when(event), systemImage: "clock")
                if event.isRecurring { Label("Repeats \(repeatText)", systemImage: "repeat") }
                if let v = event.videoURL {
                    HStack {
                        Button { model.join(v) } label: { Label("Join video call", systemImage: "video.fill") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        Button { model.copyToClipboard(v.absoluteString) } label: { Label("Copy link", systemImage: "link") }
                    }
                }
                if !event.location.isEmpty && event.location != event.videoURL?.absoluteString {
                    Label(event.location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                }
                if let org = event.organizer, !event.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Organizer: \(org.display)").font(.callout)
                        ForEach(event.attendees) { a in
                            HStack {
                                Image(systemName: icon(a.status)).foregroundStyle(color(a.status))
                                Text(a.name.isEmpty ? a.email : a.name)
                                Spacer()
                                Text(EventFormat.status(a.status)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !isMine, myStatus != nil {
                    HStack {
                        Button("Accept") { Task { await model.respond(to: event, status: .accepted); await model.loadEvents(force: true) } }
                        Button("Maybe") { Task { await model.respond(to: event, status: .tentative); await model.loadEvents(force: true) } }
                        Button("Decline") { Task { await model.respond(to: event, status: .declined); await model.loadEvents(force: true) } }
                    }
                    .buttonStyle(.bordered)
                }
                if !event.notes.isEmpty {
                    Divider()
                    Text(event.notes).textSelection(.enabled)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.editingEvent = event } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button(event.isRecurring ? "Delete All Events" : "Delete", role: .destructive) { Task { await model.delete(event: event) } }
        } message: {
            if !event.attendees.isEmpty && isMine { Text("Attendees will receive a cancellation.") }
        }
    }

    var deleteTitle: String {
        event.isRecurring ? String(localized: "This is a repeating event.") : String(localized: "Delete this event?")
    }

    var repeatText: String {
        guard let r = event.recurrence else { return "" }
        return RepeatOption(r.frequency).label
    }

    func icon(_ s: ParticipationStatus) -> String {
        switch s {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        default: return "circle"
        }
    }

    func color(_ s: ParticipationStatus) -> Color {
        switch s {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        default: return .secondary
        }
    }
}

enum RepeatOption: String, CaseIterable, Identifiable {
    case never, daily, weekly, monthly, yearly
    var id: String { rawValue }

    init(_ f: RecurrenceRule.Frequency?) {
        switch f {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        case nil: self = .never
        }
    }

    var frequency: RecurrenceRule.Frequency? {
        switch self {
        case .never: return nil
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        }
    }

    var label: String {
        switch self {
        case .never: return String(localized: "Never")
        case .daily: return String(localized: "Every day")
        case .weekly: return String(localized: "Every week")
        case .monthly: return String(localized: "Every month")
        case .yearly: return String(localized: "Every year")
        }
    }
}

struct EventEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var event: CalendarEvent
    @State private var attendeesText = ""
    @State private var saving = false
    @State private var repeatOption: RepeatOption = .never
    @State private var notify = true

    init(event: CalendarEvent) {
        _event = State(initialValue: event)
        _attendeesText = State(initialValue: event.attendees
            .filter { a in a.email.caseInsensitiveCompare(event.organizer?.address ?? "") != .orderedSame }
            .map { EmailAddress(name: $0.name, address: $0.email).headerValue }
            .joined(separator: ", "))
        _repeatOption = State(initialValue: RepeatOption(event.recurrence?.frequency))
    }

    var isNew: Bool { event.objectURL == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $event.summary)
                        .font(.headline)
                    TextField("Location", text: $event.location)
                }
                Section {
                    Toggle("All day", isOn: $event.isAllDay)
                    DatePicker("Starts", selection: startBinding, displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: endBinding, in: event.start..., displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    Picker("Repeat", selection: $repeatOption) {
                        ForEach(RepeatOption.allCases) { Text($0.label).tag($0) }
                    }
                    if event.isRecurring && event.recurrenceID != nil {
                        Text("Changes apply to all events in the series.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Reminder", selection: $event.alarmMinutes) {
                        Text("None").tag(Int?.none)
                        Text("At start").tag(Int?.some(0))
                        ForEach([5, 10, 15, 30, 60, 1440], id: \.self) { m in
                            Text(m >= 1440 ? String(localized: "1 day before") : String(localized: "\(m) minutes before")).tag(Int?.some(m))
                        }
                    }
                }
                Section("Video call") {
                    Toggle(isOn: videoBinding) {
                        Label("Add video call", systemImage: "video")
                    }
                    if let v = event.videoURL {
                        HStack {
                            Text(v.absoluteString).font(.caption).textSelection(.enabled).lineLimit(1)
                            Spacer()
                            Button { model.copyToClipboard(v.absoluteString) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    TextField("Invite people (comma separated emails)", text: $attendeesText, axis: .vertical)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    let token = attendeesText.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let suggestions = token.isEmpty || token.contains("@") && token.contains(".") ? [] : model.contacts.suggestions(for: token)
                    ForEach(suggestions) { s in
                        Button { pick(s) } label: { Text(s.name.isEmpty ? s.address : "\(s.name) <\(s.address)>") }
                            .buttonStyle(.borderless)
                    }
                    if !parsedAttendees.isEmpty && isMine {
                        Toggle("Send invitations", isOn: $notify)
                    }
                } header: {
                    Text("People")
                }
                if model.calendars.filter({ !$0.isReadOnly }).count > 1 && isNew {
                    Picker("Calendar", selection: Binding(get: { event.calendarURL ?? "" }, set: { event.calendarURL = $0 })) {
                        ForEach(model.calendars.filter { !$0.isReadOnly }) { Text($0.name).tag($0.url) }
                    }
                }
                Section("Notes") {
                    TextEditor(text: $event.notes).frame(minHeight: 100)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? String(localized: "New Event") : String(localized: "Edit Event"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text(isNew && !parsedAttendees.isEmpty && notify ? "Send" : "Save") }
                    }
                    .disabled(saving || event.summary.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }

    var isMine: Bool { model.account.map { event.isOrganized(by: $0.email) } ?? true }

    var parsedAttendees: [EmailAddress] {
        EmailAddress.parseList(attendeesText).filter(\.isValid)
    }

    var startBinding: Binding<Date> {
        Binding(get: { event.start }, set: { new in
            let d = event.duration
            event.start = new
            event.end = new.addingTimeInterval(max(d, event.isAllDay ? 86400 : 900))
        })
    }

    var endBinding: Binding<Date> {
        Binding(get: { event.isAllDay ? event.end.addingTimeInterval(-1) : event.end }, set: { new in
            event.end = event.isAllDay ? Calendar.current.startOfDay(for: new).addingTimeInterval(86400) : new
        })
    }

    var videoBinding: Binding<Bool> {
        Binding(get: { event.videoURL != nil }, set: { on in
            event.videoURL = on ? (event.videoURL ?? JitsiRoom.newURL(server: model.account?.jitsiURL ?? JitsiRoom.defaultServer)) : nil
        })
    }

    func pick(_ a: EmailAddress) {
        var parts = attendeesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(a.headerValue)
        attendeesText = parts.joined(separator: ", ") + ", "
    }

    func save() async {
        saving = true
        defer { saving = false }
        var e = event
        if e.isAllDay {
            e.start = Calendar.current.startOfDay(for: e.start)
            e.end = max(Calendar.current.startOfDay(for: e.end), e.start.addingTimeInterval(86400))
            e.timeZoneID = nil
        } else if e.timeZoneID == nil {
            e.timeZoneID = TimeZone.current.identifier
        }
        // Keep extra rule details (e.g. several weekdays) when the frequency is unchanged.
        if let f = repeatOption.frequency {
            if e.recurrence?.frequency != f { e.recurrence = RecurrenceRule(frequency: f) }
        } else {
            e.recurrence = nil
        }
        // Attendees: keep known statuses, add new ones.
        let old = Dictionary(e.attendees.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let organizerEmail = e.organizer?.address.lowercased() ?? model.account?.email.lowercased() ?? ""
        e.attendees = parsedAttendees.filter { $0.address.lowercased() != organizerEmail }.map { a in
            old[a.address.lowercased()] ?? Attendee(email: a.address, name: a.name)
        }
        if e.attendees.isEmpty {
            // No guests: no organizer/attendee lines at all.
            e.organizer = isNew ? nil : e.organizer
        } else if e.organizer == nil {
            e.organizer = model.account?.address
        }
        if await model.save(event: e, notify: notify) { dismiss() }
    }
}
