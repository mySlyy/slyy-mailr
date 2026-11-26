import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CalDAVError: Error, LocalizedError, Equatable {
    case http(Int, String)
    case discoveryFailed(String)
    case conflict

    public var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "Calendar server answered \(code) for \(url)."
        case .discoveryFailed(let m): return "Could not find your calendars: \(m)"
        case .conflict: return "The event was changed elsewhere. Reload and try again."
        }
    }
}

public struct CalDAVCalendar: Codable, Hashable, Sendable, Identifiable {
    public var url: String
    public var name: String
    public var color: String?
    public var ctag: String?
    public var isReadOnly: Bool

    public var id: String { url }
}

/// A stored calendar resource (.ics) with its events (master + exceptions).
public struct CalendarObject: Sendable {
    public var url: String
    public var etag: String?
    public var ics: String
    public var events: [CalendarEvent]
}

/// CalDAV (RFC 4791) client: discovery, calendar list, time-range query, PUT/DELETE with ETags.
public final class CalDAVClient: NSObject, @unchecked Sendable, URLSessionTaskDelegate {
    public let baseURL: URL
    private let authHeader: String
    private var session: URLSession!
    public private(set) var homeURL: URL?

    public init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.authHeader = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // Redirects are followed manually so PROPFIND/REPORT keep their method and body.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: HTTP

    struct Response {
        var status: Int
        var data: Data
        var headers: [String: String]
        var url: URL
    }

    func send(_ method: String, _ url: URL, body: String? = nil, depth: String? = nil, headers: [String: String] = [:], redirects: Int = 5) async throws -> Response {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = Data(body.utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        if let depth { req.setValue(depth, forHTTPHeaderField: "Depth") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CalDAVError.http(0, url.absoluteString) }
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields { h[String(describing: k).lowercased()] = String(describing: v) }
        if [301, 302, 303, 307, 308].contains(http.statusCode), redirects > 0, let loc = h["location"], let next = URL(string: loc, relativeTo: url)?.absoluteURL {
            return try await send(method, next, body: body, depth: depth, headers: headers, redirects: redirects - 1)
        }
        return Response(status: http.statusCode, data: data, headers: h, url: url)
    }

    struct PropResponse {
        var href: URL
        var props: [String: XMLTree.Node]
        var resourceTypes: Set<String>
    }

    func propfind(_ url: URL, depth: String, props: String) async throws -> [PropResponse] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/"><d:prop>\(props)</d:prop></d:propfind>
        """
        let r = try await send("PROPFIND", url, body: body, depth: depth)
        guard r.status == 207 else { throw CalDAVError.http(r.status, url.absoluteString) }
        return parseMultistatus(r.data, base: r.url)
    }

    func parseMultistatus(_ data: Data, base: URL) -> [PropResponse] {
        guard let doc = XMLTree.parse(data) else { return [] }
        return doc.all("response").compactMap { resp in
            guard let hrefText = resp.first("href")?.text, let href = URL(string: hrefText, relativeTo: base)?.absoluteURL else { return nil }
            var props: [String: XMLTree.Node] = [:]
            var types = Set<String>()
            for ps in resp.childrenNamed("propstat") {
                guard (ps.first("status")?.text ?? "200").contains(" 200") else { continue }
                guard let prop = ps.first("prop") else { continue }
                for p in prop.children {
                    props[p.name] = p
                    if p.name == "resourcetype" { types.formUnion(p.children.map(\.name)) }
                }
            }
            return PropResponse(href: href, props: props, resourceTypes: types)
        }
    }

    // MARK: Discovery

    /// Finds the calendar home: base → current-user-principal → calendar-home-set.
    public func discover() async throws -> URL {
        if let homeURL { return homeURL }
        var start = baseURL
        if baseURL.path.isEmpty || baseURL.path == "/" {
            // Try the well-known URL first, as RFC 6764 recommends.
            if let wk = URL(string: "/.well-known/caldav", relativeTo: baseURL)?.absoluteURL,
               let r = try? await send("PROPFIND", wk, body: Self.principalBody, depth: "0"), r.status == 207 {
                start = r.url
            }
        }
        let principals = try await propfind(start, depth: "0", props: "<d:current-user-principal/><c:calendar-home-set/>")
        if let home = principals.first?.props["calendar-home-set"]?.first("href")?.text, let url = URL(string: home, relativeTo: start)?.absoluteURL {
            homeURL = url
            return url
        }
        guard let principalHref = principals.first?.props["current-user-principal"]?.first("href")?.text,
              let principal = URL(string: principalHref, relativeTo: start)?.absoluteURL else {
            throw CalDAVError.discoveryFailed("no current-user-principal at \(start.absoluteString)")
        }
        let p = try await propfind(principal, depth: "0", props: "<c:calendar-home-set/>")
        guard let home = p.first?.props["calendar-home-set"]?.first("href")?.text, let url = URL(string: home, relativeTo: principal)?.absoluteURL else {
            throw CalDAVError.discoveryFailed("no calendar-home-set for \(principal.absoluteString)")
        }
        homeURL = url
        return url
    }

    static let principalBody = """
    <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>
    """

    /// Calendars that can hold events.
    public func calendars() async throws -> [CalDAVCalendar] {
        let home = try await discover()
        let list = try await propfind(home, depth: "1", props: "<d:resourcetype/><d:displayname/><a:calendar-color/><cs:getctag/><c:supported-calendar-component-set/><d:current-user-privilege-set/>")
        return list.compactMap { r in
            guard r.resourceTypes.contains("calendar") else { return nil }
            if let comps = r.props["supported-calendar-component-set"], !comps.children.isEmpty,
               !comps.children.contains(where: { $0.attributes["name"]?.uppercased() == "VEVENT" }) {
                return nil
            }
            let privileges = r.props["current-user-privilege-set"].map { Set($0.all("privilege").flatMap { $0.children.map(\.name) }) }
            let readOnly = privileges.map { !$0.contains("write") && !$0.contains("write-content") && !$0.contains("all") } ?? false
            let name = r.props["displayname"]?.text ?? ""
            return CalDAVCalendar(
                url: r.href.absoluteString,
                name: name.isEmpty ? r.href.lastPathComponent : name,
                color: r.props["calendar-color"]?.text.nilIfEmpty,
                ctag: r.props["getctag"]?.text.nilIfEmpty,
                isReadOnly: readOnly
            )
        }
    }

    /// Creates a calendar under the home collection.
    @discardableResult
    public func makeCalendar(name: String, color: String = "#2F6FED") async throws -> CalDAVCalendar {
        let home = try await discover()
        let url = home.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop>
        <d:displayname>\(HTMLText.escape(name))</d:displayname><a:calendar-color>\(color)</a:calendar-color>
        <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
        </d:prop></d:set></c:mkcalendar>
        """
        let r = try await send("MKCALENDAR", url, body: body)
        guard r.status == 201 || r.status == 200 else { throw CalDAVError.http(r.status, url.absoluteString) }
        return CalDAVCalendar(url: url.absoluteString, name: name, color: color, ctag: nil, isReadOnly: false)
    }

    /// Objects with events overlapping [from, to) (recurring masters included; expand locally).
    public func objects(in calendar: CalDAVCalendar, from: Date, to: Date) async throws -> [CalendarObject] {
        guard let url = URL(string: calendar.url) else { return [] }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:prop><d:getetag/><c:calendar-data/></d:prop>
        <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
        <c:time-range start="\(ICalTime.formatUTC(from))" end="\(ICalTime.formatUTC(to))"/>
        </c:comp-filter></c:comp-filter></c:filter></c:calendar-query>
        """
        let r = try await send("REPORT", url, body: body, depth: "1")
        guard r.status == 207 else { throw CalDAVError.http(r.status, url.absoluteString) }
        return parseMultistatus(r.data, base: r.url).compactMap { resp in
            guard let ics = resp.props["calendar-data"]?.text, !ics.isEmpty else { return nil }
            let etag = resp.props["getetag"]?.text
            var events = ICalendarReader.read(ics).events
            for i in events.indices {
                events[i].calendarURL = calendar.url
                events[i].objectURL = resp.href.absoluteString
                events[i].etag = etag
            }
            return CalendarObject(url: resp.href.absoluteString, etag: etag, ics: ics, events: events)
        }
    }

    /// Reads one object (to update it without losing exceptions or alarms).
    public func object(at urlString: String) async throws -> CalendarObject {
        guard let url = URL(string: urlString) else { throw CalDAVError.http(0, urlString) }
        let r = try await send("GET", url)
        guard r.status == 200 else { throw CalDAVError.http(r.status, urlString) }
        let ics = String(decoding: r.data, as: UTF8.self)
        return CalendarObject(url: urlString, etag: r.headers["etag"], ics: ics, events: ICalendarReader.read(ics).events)
    }

    /// Creates (etag nil → If-None-Match) or updates (If-Match) a calendar object. Returns the new ETag if the server sent one.
    @discardableResult
    public func put(ics: String, uid: String, calendarURL: String, objectURL: String? = nil, etag: String? = nil) async throws -> (url: String, etag: String?) {
        let target: URL
        if let objectURL, let u = URL(string: objectURL) {
            target = u
        } else if let base = URL(string: calendarURL) {
            let safe = uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.@"))) ?? UUID().uuidString
            target = base.appendingPathComponent("\(safe).ics")
        } else {
            throw CalDAVError.http(0, calendarURL)
        }
        var headers = ["Content-Type": "text/calendar; charset=utf-8"]
        if let etag { headers["If-Match"] = etag } else if objectURL == nil { headers["If-None-Match"] = "*" }
        let r = try await send("PUT", target, body: ics, headers: headers)
        if r.status == 412 { throw CalDAVError.conflict }
        guard (200...299).contains(r.status) else { throw CalDAVError.http(r.status, target.absoluteString) }
        return (target.absoluteString, r.headers["etag"])
    }

    public func delete(objectURL: String, etag: String?) async throws {
        guard let url = URL(string: objectURL) else { return }
        var headers: [String: String] = [:]
        if let etag { headers["If-Match"] = etag }
        let r = try await send("DELETE", url, headers: headers)
        if r.status == 412 { throw CalDAVError.conflict }
        guard (200...299).contains(r.status) || r.status == 404 else { throw CalDAVError.http(r.status, objectURL) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
