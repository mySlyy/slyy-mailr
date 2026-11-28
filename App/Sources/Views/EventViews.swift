import SwiftUI
import SlyyMailKit

/// Event details (calendar aside on desktop, sheet on iPhone).
struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent
    @State private var confirmDelete = false

    var isMine: Bool { model.account.map { event.isOrganized(by: $0.email) } ?? true }
    var myStatus: ParticipationStatus? { model.myStatus(in: event) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.summary.isEmpty ? String(localized: "New event") : event.summary)
                        .font(Slyy.font(20, .semibold))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Edit") { model.editingEvent = event }
                        .buttonStyle(.plain)
                        .foregroundStyle(Slyy.accent)
                    Button { model.selectedEvent = nil } label: { Image(systemName: "xmark").foregroundStyle(Slyy.muted) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                }
                Text(EventFormat.medium(event) + (event.isRecurring ? "\n" + repeatText : ""))
                    .foregroundStyle(Slyy.ink2)
                if let v = event.videoURL {
                    Button { model.join(v) } label: { Label("Join video call", systemImage: SlyyIcon.video) }
                        .buttonStyle(.slyyAccent(fullWidth: true, height: 44))
                    Text(v.absoluteString.replacingOccurrences(of: "https://", with: ""))
                        .font(Slyy.mono(11))
                        .foregroundStyle(Slyy.ink2)
                        .textSelection(.enabled)
                }
                if !event.location.isEmpty && event.location != event.videoURL?.absoluteString {
                    Label(event.location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                }
                if !event.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let org = event.organizer {
                            SectionLabel("People · organizer \(org.display)")
                        } else {
                            SectionLabel("People")
                        }
                        ForEach(event.attendees) { a in
                            HStack {
                                Text(a.name.isEmpty ? a.email : a.name) + Text(model.isMine(a.email) ? " (you)" : "")
                                Spacer()
                                Text(a.email.caseInsensitiveCompare(event.organizer?.address ?? "") == .orderedSame ? String(localized: "Organizer") : EventFormat.status(a.status))
                                    .font(Slyy.font(12))
                                    .foregroundStyle(a.status == .accepted ? Slyy.accent : (a.status == .needsAction ? Slyy.muted : Slyy.ink2))
                            }
                        }
                    }
                }
                if !isMine, myStatus != nil {
                    HStack(spacing: 6) {
                        rsvp("Accept", .accepted)
                        rsvp("Maybe", .tentative)
                        rsvp("Decline", .declined)
                    }
                }
                if let m = event.alarmMinutes {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Reminder")
                        Text(m == 0 ? String(localized: "At start") : String(localized: "\(m) minutes before") + (event.videoURL != nil ? " · " + String(localized: "with Join button") : ""))
                            .font(Slyy.font(13))
                    }
                }
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(Slyy.font(13))
                        .foregroundStyle(Slyy.ink2)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                Button(event.isRecurring ? "Delete series…" : "Delete…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Slyy.danger)
                    .padding(.top, 8)
            }
            .padding(20)
            #if os(macOS)
            .padding(.top, 10)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .background(Color.white)
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button(event.isRecurring ? "Delete All Events" : "Delete", role: .destructive) { Task { await model.delete(event: event) } }
        } message: {
            if !event.attendees.isEmpty && isMine { Text("Attendees will receive a cancellation.") }
        }
    }

    func rsvp(_ title: LocalizedStringKey, _ status: ParticipationStatus) -> some View {
        Button(title) {
            Task {
                await model.respond(to: event, status: status)
                await model.loadEvents(force: true)
            }
        }
        .buttonStyle(SlyyOutlineButtonStyle(strong: true, fullWidth: true, selected: myStatus == status))
    }

    var deleteTitle: String {
        event.isRecurring ? String(localized: "This is a repeating event.") : String(localized: "Delete this event?")
    }

    var repeatText: String {
        guard let r = event.recurrence else { return "" }
        return RepeatOption(r.frequency).label
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

/// New/edit meeting dialog from the wireframe.
struct EventEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var event: CalendarEvent
    @State private var people: [EmailAddress]
    @State private var typing = ""
    @State private var saving = false
    @State private var repeatOption: RepeatOption = .never
    @State private var notify = true

    init(event: CalendarEvent) {
        _event = State(initialValue: event)
        _people = State(initialValue: event.attendees
            .filter { a in a.email.caseInsensitiveCompare(event.organizer?.address ?? "") != .orderedSame }
            .map { EmailAddress(name: $0.name, address: $0.email) })
        _repeatOption = State(initialValue: RepeatOption(event.recurrence?.frequency))
    }

    var isNew: Bool { event.objectURL == nil }
    var isMine: Bool { model.account.map { event.isOrganized(by: $0.email) } ?? true }
    var sendsInvites: Bool { !allPeople.isEmpty && isMine && notify }

    var allPeople: [EmailAddress] {
        people + EmailAddress.parseList(typing).filter(\.isValid)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.slyyOutline)
                    .keyboardShortcut(.cancelAction)
                Text(isNew ? (allPeople.isEmpty ? String(localized: "New event") : String(localized: "New meeting")) : String(localized: "Edit event"))
                    .font(Slyy.font(15, .semibold))
                    .frame(maxWidth: .infinity)
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small).tint(.white) } else { Text(sendsInvites ? (isNew ? "Send invitations" : "Send update") : "Save") }
                }
                .buttonStyle(.slyyAccent(height: 36))
                .disabled(saving || event.summary.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .bottomHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Title", text: $event.summary)
                        .textFieldStyle(.plain)
                        .font(Slyy.font(22, .semibold))
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(Slyy.lineStrong).frame(height: 1) }

                    dateTimeSection

                    HStack(spacing: 10) {
                        fieldRow("Repeat") {
                            Picker("Repeat", selection: $repeatOption) {
                                ForEach(RepeatOption.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                        }
                        fieldRow("Reminder") {
                            Picker("Reminder", selection: $event.alarmMinutes) {
                                Text("None").tag(Int?.none)
                                Text("At start").tag(Int?.some(0))
                                ForEach([5, 10, 15, 30, 60, 1440], id: \.self) { m in
                                    Text(m >= 1440 ? String(localized: "1 day before") : String(localized: "\(m) minutes before")).tag(Int?.some(m))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    if event.isRecurring && event.recurrenceID != nil {
                        Text("Changes apply to all events in the series.").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                    }

                    videoSection
                    peopleSection

                    HStack(spacing: 10) {
                        labeled("Location") {
                            TextField("Optional", text: $event.location).textFieldStyle(SlyyFieldStyle(padding: 9))
                        }
                        if model.calendars.filter({ !$0.isReadOnly }).count > 1 && isNew {
                            fieldRow("Calendar") {
                                Picker("Calendar", selection: Binding(get: { event.calendarURL ?? "" }, set: { event.calendarURL = $0 })) {
                                    ForEach(model.calendars.filter { !$0.isReadOnly }) { Text($0.name).tag($0.url) }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }
                    labeled("Notes") {
                        TextEditor(text: $event.notes)
                            .font(Slyy.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80)
                            .padding(6)
                            .hairlineBorder(Slyy.lineStrong)
                    }
                }
                .padding(20)
            }
        }
        .font(Slyy.body)
        .foregroundStyle(Slyy.ink)
        .background(Color.white)
        .tint(Slyy.accent)
        .preferredColorScheme(.light)
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 640, idealHeight: 760)
        #endif
        .onAppear {
            // New meetings with people get a video call by default (spec).
            if isNew && event.videoURL == nil && !people.isEmpty { setVideo(true) }
        }
    }

    func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Slyy.font(13)).foregroundStyle(Slyy.ink2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A labelled control (picker, date) in a square box, its own label hidden.
    func fieldRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder control: () -> Content) -> some View {
        labeled(title) {
            control()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .hairlineBorder(Slyy.lineStrong)
        }
    }

    var dateTimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                fieldRow("Date") {
                    DatePicker("Date", selection: startBinding, displayedComponents: [.date])
                }
                if !event.isAllDay {
                    fieldRow("Starts") {
                        DatePicker("Starts", selection: startBinding, displayedComponents: [.hourAndMinute])
                    }
                    fieldRow("Ends") {
                        DatePicker("Ends", selection: endBinding, in: event.start..., displayedComponents: [.date, .hourAndMinute])
                    }
                } else {
                    fieldRow("Until") {
                        DatePicker("Until", selection: endBinding, in: event.start..., displayedComponents: [.date])
                    }
                }
            }
            HStack {
                Toggle("All day", isOn: $event.isAllDay).toggleStyle(SlyyCheckboxStyle())
                Spacer()
                Text(event.isAllDay ? "" : (event.timeZoneID ?? TimeZone.current.identifier)).font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
        }
    }

    var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { event.videoURL != nil }, set: { setVideo($0) })) {
                HStack(spacing: 10) {
                    Image(systemName: SlyyIcon.video).foregroundStyle(Slyy.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Video call").font(Slyy.font(14, .semibold))
                        Text("On for meetings with people; a new private room each time").font(Slyy.font(12)).foregroundStyle(Slyy.muted)
                    }
                }
            }
            .toggleStyle(SlyySwitchStyle())
            if let v = event.videoURL {
                HStack(spacing: 8) {
                    Text(v.absoluteString).font(Slyy.mono(12)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Copy link") { model.copyToClipboard(v.absoluteString) }
                        .buttonStyle(SlyyOutlineButtonStyle(strong: true, height: 30))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Slyy.panel)
                Text("Goes into location, description and the Outlook \"Join\" field, so every guest sees it.")
                    .font(Slyy.font(12)).foregroundStyle(Slyy.muted)
            }
        }
        .padding(14)
        .hairlineBorder()
    }

    var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People").font(Slyy.font(13)).foregroundStyle(Slyy.ink2)
            FlowChips(people: $people) {
                TextField(people.isEmpty ? "Add email" : "", text: $typing)
                    .textFieldStyle(.plain)
                    .onSubmit(commitTyping)
                    .onChange(of: typing) { _, t in if t.hasSuffix(",") || t.hasSuffix(" ") && t.contains("@") { commitTyping() } }
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .frame(minWidth: 140)
            }
            .padding(6)
            .hairlineBorder(Slyy.lineStrong)
            let suggestions = typing.count >= 1 ? model.contacts.suggestions(for: typing).filter { s in !people.contains(where: { $0.id == s.id }) } : []
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { s in
                        Button { people.append(s); typing = ""; if isNew && event.videoURL == nil { setVideo(true) } } label: {
                            HStack(spacing: 6) {
                                Text(s.name.isEmpty ? s.address : s.name).font(Slyy.font(14, .semibold))
                                if !s.name.isEmpty { Text(s.address).font(Slyy.font(13)).foregroundStyle(Slyy.ink2) }
                                Spacer()
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .hairlineBorder(Slyy.lineStrong)
            }
            if !allPeople.isEmpty && isMine {
                Toggle("Send invitations (work in Outlook, Google and Apple Calendar)", isOn: $notify)
                    .toggleStyle(SlyyCheckboxStyle())
                    .font(Slyy.font(13))
            }
        }
    }

    func commitTyping() {
        let found = EmailAddress.parseList(typing.trimmingCharacters(in: CharacterSet(charactersIn: ", "))).filter(\.isValid)
        guard !found.isEmpty else { return }
        for a in found where !people.contains(where: { $0.id == a.id }) { people.append(a) }
        typing = ""
        if isNew && event.videoURL == nil { setVideo(true) }
    }

    func setVideo(_ on: Bool) {
        event.videoURL = on ? (event.videoURL ?? model.newMeetingURL()) : nil
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
            event.end = event.isAllDay ? Calendar.current.startOfDay(for: new).addingTimeInterval(86400) : max(new, event.start.addingTimeInterval(300))
        })
    }

    func save() async {
        commitTyping()
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
        let old = Dictionary(e.attendees.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let organizerEmail = e.organizer?.address.lowercased() ?? model.account?.email.lowercased() ?? ""
        e.attendees = people.filter { $0.address.lowercased() != organizerEmail }.map { a in
            old[a.address.lowercased()] ?? Attendee(email: a.address, name: a.name)
        }
        if e.attendees.isEmpty {
            e.organizer = isNew ? nil : e.organizer
        } else if e.organizer == nil {
            e.organizer = model.account?.address
        }
        if await model.save(event: e, notify: notify) { dismiss() }
    }
}

/// Wrapping row of removable people chips followed by an input.
struct FlowChips<Input: View>: View {
    @Binding var people: [EmailAddress]
    @ViewBuilder var input: () -> Input

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(people) { p in
                HStack(spacing: 6) {
                    Text(p.name.isEmpty ? p.address : p.name)
                    Button { people.removeAll { $0.id == p.id } } label: { Image(systemName: "xmark").imageScale(.small) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(p.address)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Slyy.panel)
            }
            input()
        }
    }
}

/// Simple flow layout (left to right, wrapping).
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(width, maxX), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
