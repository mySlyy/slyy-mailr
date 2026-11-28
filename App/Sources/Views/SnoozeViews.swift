import SwiftUI
import SlyyMailKit

/// "Snooze…" chosen from a menu: the messages and, if known, the date the mail mentions.
struct SnoozeRequest: Identifiable {
    let id = UUID()
    var messages: [MessageSummary]
    var suggestion: DateMention?
}

enum SnoozeFormat {
    /// "Mon 7 Dec"
    static func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Mon 7 Dec, 09:00"
    static func dayTime(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func label(_ m: DateMention) -> String {
        switch m.kind {
        case .returning: return String(localized: "Back on \(day(m.date))")
        case .deadline: return String(localized: "Due \(day(m.date))")
        case .other: return String(localized: "Mentions \(day(m.date))")
        }
    }

    /// Tomorrow at 09:00.
    static func tomorrowMorning(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let t = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        return cal.date(bySettingHour: DateMentions.reminderHour, minute: 0, second: 0, of: t) ?? t
    }

    /// Next Monday at 09:00 (a week from today when today is Monday).
    static func nextMondayMorning(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        var delta = (2 - cal.component(.weekday, from: start) + 7) % 7
        if delta == 0 { delta = 7 }
        let d = cal.date(byAdding: .day, value: delta, to: start) ?? start
        return cal.date(bySettingHour: DateMentions.reminderHour, minute: 0, second: 0, of: d) ?? d
    }

    /// A reminder time that is still ahead: the suggestion, else tomorrow 09:00; never in the past.
    static func defaultTime(_ suggestion: DateMention?, now: Date = Date()) -> Date {
        let wanted = suggestion?.suggestedReminder ?? tomorrowMorning(now: now)
        return wanted > now.addingTimeInterval(60) ? wanted : nextHalfHour(after: now)
    }

    /// The next :00 or :30 at least 5 minutes ahead.
    static func nextHalfHour(after now: Date) -> Date {
        let cal = Calendar.current
        let soon = now.addingTimeInterval(300)
        let minute = cal.component(.minute, from: soon)
        let add = minute < 30 ? 30 - minute : 60 - minute
        let d = cal.date(byAdding: .minute, value: add, to: soon) ?? soon
        return cal.date(bySetting: .second, value: 0, of: d) ?? d
    }
}

/// One quiet line under the reader's header: the date the mail mentions and "Snooze & remind…",
/// or, for a snoozed message (e.g. found by search), when it comes back and "Unsnooze".
/// The check is local (DateMentions); a Slyy Haven based check could later enrich it, once Haven is available.
struct DateMentionLine: View {
    @Environment(AppModel.self) private var model
    let summary: MessageSummary
    let parsed: ParsedMessage
    @State private var picking = false

    var body: some View {
        if let entry = model.snoozeEntry(for: summary) {
            line(icon: "clock", text: String(localized: "Snoozed until \(SnoozeFormat.dayTime(entry.until))")) {
                Button("Unsnooze") { Task { await model.unsnooze(summary) } }
            }
        } else if let m = model.dateMentions(for: summary, parsed: parsed).first {
            line(icon: m.kind == .returning ? "calendar.badge.clock" : "calendar", text: SnoozeFormat.label(m)) {
                Button("Snooze & remind…") { picking = true }
                    .popover(isPresented: $picking, arrowEdge: .bottom) {
                        // iPhone shows the popover as a sheet.
                        SnoozePicker(messages: model.snoozeTargets(for: summary), suggestion: m) { picking = false }
                            .environment(model)
                    }
            }
            .help(m.phrase)
        }
    }

    func line<Action: View>(icon: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).imageScale(.small)
            Text(text).lineLimit(1)
            Spacer(minLength: 8)
            action()
                .buttonStyle(.plain)
                .foregroundStyle(Slyy.accent)
        }
        .font(Slyy.font(13))
        .foregroundStyle(Slyy.muted)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Slyy.line).frame(height: 1) }
    }
}

/// Picks when a snoozed message comes back: quick choices, a date and time picker, Snooze / Cancel.
struct SnoozePicker: View {
    @Environment(AppModel.self) private var model
    let messages: [MessageSummary]
    var suggestion: DateMention?
    var onDone: () -> Void
    @State private var when: Date
    /// The suggestion found after opening (menus on a message whose text was not loaded yet).
    @State private var found: DateMention?
    @State private var touched = false

    init(messages: [MessageSummary], suggestion: DateMention?, onDone: @escaping () -> Void) {
        self.messages = messages
        self.suggestion = suggestion
        self.onDone = onDone
        _when = State(initialValue: SnoozeFormat.defaultTime(suggestion))
    }

    var best: DateMention? { suggestion ?? found }

    var body: some View {
        Group {
            #if os(macOS)
            content.frame(width: 340) // popovers and sheets size to their content
            #else
            ScrollView { content }
                .frame(maxWidth: 420)
            #endif
        }
        .background(Color.white)
        .task {
            guard suggestion == nil, let first = messages.max(by: { $0.date < $1.date }) else { return }
            if let m = await model.dateSuggestion(for: first) {
                found = m
                if !touched { when = SnoozeFormat.defaultTime(m) }
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Snooze & remind").font(Slyy.font(17, .semibold))
                Text("The mail is hidden until then and comes back unread, with a reminder.")
                    .font(Slyy.font(13))
                    .foregroundStyle(Slyy.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { choices }
                VStack(alignment: .leading, spacing: 6) { choices }
            }
            picker
            Text("Snoozes are kept on this device.")
                .font(Slyy.font(12))
                .foregroundStyle(Slyy.muted)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onDone() }
                    .buttonStyle(.slyyOutline)
                    .keyboardShortcut(.cancelAction)
                Button("Snooze") {
                    let list = messages
                    let until = max(when, Date().addingTimeInterval(60))
                    onDone()
                    Task { await model.snooze(list, until: until) }
                }
                .buttonStyle(.slyyPrimary(height: 34))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    var picker: some View {
        let binding = Binding(get: { when }, set: { when = $0; touched = true })
        #if os(macOS)
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("Date", selection: binding, in: Date()..., displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            DatePicker("Time", selection: binding, displayedComponents: [.hourAndMinute])
                .datePickerStyle(.stepperField)
                .font(Slyy.font(13))
        }
        #else
        DatePicker("Remind me", selection: binding, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.graphical)
            .font(Slyy.font(14))
        #endif
    }

    @ViewBuilder
    var choices: some View {
        if let b = best {
            choice(String(localized: "Suggested"), SnoozeFormat.defaultTime(b))
                .help(SnoozeFormat.label(b))
        }
        choice(String(localized: "Tomorrow 9:00"), SnoozeFormat.tomorrowMorning())
        choice(String(localized: "Next Monday 9:00"), SnoozeFormat.nextMondayMorning())
    }

    func choice(_ title: String, _ date: Date) -> some View {
        Button(title) {
            when = date
            touched = true
        }
        .buttonStyle(SlyyOutlineButtonStyle(height: 28, selected: abs(when.timeIntervalSince(date)) < 30))
    }
}
