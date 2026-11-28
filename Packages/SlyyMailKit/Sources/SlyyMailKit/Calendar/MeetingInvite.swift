import Foundation

/// A meeting added to a mail being written: on Send it is stored in the sender's calendar
/// and the mail itself carries the invitation (iTIP REQUEST) to its To and Cc recipients.
public struct MeetingInvite: Codable, Hashable, Sendable {
    /// Calendar UID; stays the same while the mail is edited, so a retried Send updates the same event.
    public var uid: String
    public var title: String
    public var start: Date
    public var minutes: Int
    public var videoURL: URL?
    public var timeZoneID: String

    public init(uid: String = UUID().uuidString.lowercased(), title: String, start: Date, minutes: Int = 30, videoURL: URL? = nil, timeZoneID: String = TimeZone.current.identifier) {
        self.uid = uid
        self.title = title
        self.start = start
        self.minutes = minutes
        self.videoURL = videoURL
        self.timeZoneID = timeZoneID
    }

    public var end: Date { start.addingTimeInterval(TimeInterval(max(1, minutes)) * 60) }

    /// The calendar event: `organizer` first as accepted chair (as CalendarService stores it),
    /// then every other address once, waiting for an answer.
    public func event(organizer: EmailAddress, attendees: [EmailAddress], fallbackTitle: String = "Meeting") -> CalendarEvent {
        var seen: Set<String> = [organizer.address.lowercased()]
        var list = [Attendee(email: organizer.address, name: organizer.name, status: .accepted, role: "CHAIR", rsvp: false)]
        for a in attendees where !a.address.isEmpty && seen.insert(a.address.lowercased()).inserted {
            list.append(Attendee(email: a.address, name: a.name))
        }
        let summary = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            uid: uid,
            summary: summary.isEmpty ? fallbackTitle : summary,
            start: start,
            end: end,
            timeZoneID: timeZoneID,
            organizer: organizer,
            attendees: list,
            videoURL: videoURL
        )
    }
}

extension OutgoingMessage {
    /// This mail as the invitation to `event`: a when / where / join block above the text
    /// and the iTIP REQUEST as text/calendar part (plus invite.ics), as CalendarService's invitation mails.
    public func invitation(for event: CalendarEvent) -> OutgoingMessage {
        var m = self
        let block = CalendarService.inviteText(event)
        m.text = block + "\n\n" + text
        if let html { m.html = HTMLText.fromPlain(block) + "<br><hr><br>" + html }
        m.calendar = CalendarAttachment(method: "REQUEST", ics: ICalendarWriter.request(event))
        return m
    }
}
