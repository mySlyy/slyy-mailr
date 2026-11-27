import SwiftUI
import SlyyMailKit

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var phone: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            if phone { phoneHeader } else { header }
            switch effectiveMode {
            case .month:
                MonthGridView()
            case .week, .day:
                TimeGridView(days: days, hourHeight: phone ? 64 : 48)
            }
            if !phone {
                Text("Double-click an empty slot to create an event. Repeating events keep their local time across daylight-saving changes.")
                    .font(Slyy.font(12))
                    .foregroundStyle(Slyy.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.white)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: model.account?.id) { await model.loadEvents(force: false) }
        .refreshable { await model.loadEvents(force: true) }
    }

    var effectiveMode: CalendarMode {
        phone ? .day : model.calendarMode
    }

    var days: [Date] {
        let r = model.range(for: model.calendarDate, mode: effectiveMode)
        var out: [Date] = []
        var d = r.0
        while d < r.1 {
            out.append(d)
            d = Calendar.current.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    var weekNumber: Int {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal.component(.weekOfYear, from: model.calendarDate)
    }

    var header: some View {
        HStack(spacing: 8) {
            Button("Today") { model.calendarDate = Date(); Task { await model.loadEvents(force: false) } }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true))
            Button { model.moveCalendar(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 12) }
                .buttonStyle(.slyyOutline)
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .accessibilityLabel("Previous")
            Button { model.moveCalendar(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 12) }
                .buttonStyle(.slyyOutline)
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .accessibilityLabel("Next")
            (Text(model.calendarDate.formatted(.dateTime.month(.wide).year())).font(Slyy.font(20, .semibold))
             + Text(model.calendarMode == .month ? "" : "  · " + String(localized: "week \(weekNumber)")).font(Slyy.font(20)).foregroundStyle(Slyy.muted))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                ForEach(CalendarMode.allCases) { m in
                    Button { model.calendarMode = m; Task { await model.loadEvents(force: false) } } label: {
                        Text(m.title)
                            .lineLimit(1)
                            .fixedSize()
                            .font(Slyy.font(14, model.calendarMode == m ? .semibold : .regular))
                            .foregroundStyle(model.calendarMode == m ? Color.white : Slyy.ink)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(model.calendarMode == m ? Slyy.ink : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .hairlineBorder(Slyy.lineStrong)
            Button { model.meetNow() } label: { Label("Meet now", systemImage: SlyyIcon.video) }
                .buttonStyle(SlyyOutlineButtonStyle(strong: true))
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        .padding(.bottom, 12)
        .bottomHairline()
    }

    var topInset: CGFloat {
        #if os(macOS)
        return 30
        #else
        return 12
        #endif
    }

    /// iPhone (M3): month title, new-event button, a strip of this week's days.
    var phoneHeader: some View {
        let week = model.range(for: model.calendarDate, mode: .week).0
        let weekDays = (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: week)! }
        return VStack(spacing: 0) {
            HStack {
                Text(model.calendarDate.formatted(.dateTime.month(.wide))).font(Slyy.font(20, .bold))
                Spacer()
                Button { model.newEvent(at: nil) } label: {
                    Image(systemName: "plus").foregroundStyle(.white).frame(width: 44, height: 44).background(Slyy.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New event")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 8)
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { d in
                    let selected = Calendar.current.isDate(d, inSameDayAs: model.calendarDate)
                    Button { model.calendarDate = d } label: {
                        VStack(spacing: 4) {
                            Text(d.formatted(.dateTime.weekday(.abbreviated))).font(Slyy.font(12)).foregroundStyle(selected ? Slyy.accent : Slyy.muted)
                            Text(d.formatted(.dateTime.day()))
                                .font(Slyy.font(16, selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.white : Slyy.ink)
                                .frame(width: 32, height: 32)
                                .background(selected ? Slyy.accent : Color.clear, in: Circle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                model.calendarDate = Calendar.current.date(byAdding: .day, value: v.translation.width < 0 ? 7 : -7, to: model.calendarDate) ?? model.calendarDate
                Task { await model.loadEvents(force: false) }
            })
            .bottomHairline()
        }
    }
}

/// Day/week grid: day headers, all-day strip, hours; overlapping events side by side.
struct TimeGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let days: [Date]
    var hourHeight: CGFloat = 48
    let gutter: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let colWidth = max(40, (geo.size.width - gutter) / CGFloat(max(days.count, 1)))
            VStack(spacing: 0) {
                if days.count > 1 {
                    dayHeaders(colWidth)
                }
                allDayStrip(colWidth)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            hourLabels
                            ForEach(days, id: \.self) { day in
                                dayColumn(day, width: colWidth)
                            }
                        }
                        .frame(height: hourHeight * 24)
                    }
                    .onAppear { proxy.scrollTo(8, anchor: .top) }
                }
            }
        }
    }

    func dayHeaders(_ w: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let today = Calendar.current.isDateInToday(d)
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Slyy.font(12))
                        .foregroundStyle(today ? Slyy.accent : Slyy.muted)
                    Text(d.formatted(.dateTime.day()))
                        .font(Slyy.font(18, today ? .bold : .medium))
                        .foregroundStyle(today ? Slyy.accent : Slyy.ink)
                }
                .padding(8)
                .frame(width: w, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Slyy.line).frame(width: 1) }
            }
        }
    }

    func allDayStrip(_ w: CGFloat) -> some View {
        let allDay = model.visibleEvents.filter(\.isAllDay)
        return HStack(alignment: .top, spacing: 0) {
            Text("all-day").font(Slyy.font(11)).foregroundStyle(Slyy.muted)
                .frame(width: gutter - 6, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 4)
            ForEach(days, id: \.self) { d in
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: d)!
                VStack(spacing: 2) {
                    ForEach(allDay.filter { $0.overlaps(d, dayEnd) }) { e in
                        Button { model.selectedEvent = e } label: { EventChip(event: e) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .frame(width: w, alignment: .top)
                .overlay(alignment: .leading) { Rectangle().fill(Slyy.line).frame(width: 1) }
            }
        }
        .frame(minHeight: 26)
        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
        .bottomHairline()
    }

    var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                // Label sits just below its hour line; padding stays inside the fixed row height so rows never drift.
                Text(String(format: "%02d:00", h))
                    .font(Slyy.font(11))
                    .foregroundStyle(Slyy.muted)
                    .padding(.top, 2)
                    .padding(.trailing, 6)
                    .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                    .id(h)
            }
        }
    }

    func columnBackground(_ day: Date) -> Color {
        if Calendar.current.isDateInToday(day) { return Slyy.todayTint }
        if Calendar.current.isDateInWeekend(day) { return Slyy.sidebar }
        return Color.white
    }

    func dayColumn(_ day: Date, width: CGFloat) -> some View {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let timed = model.visibleEvents.filter { !$0.isAllDay && $0.overlaps(day, dayEnd) }
        let layout = Self.layout(timed)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle().fill(columnBackground(day))
                        .frame(height: hourHeight)
                        .overlay(alignment: .top) { Rectangle().fill(Slyy.line).frame(height: 1) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { p in
                let minutes = Int(p.y / hourHeight * 60) / 30 * 30
                model.newEvent(at: Calendar.current.date(byAdding: .minute, value: minutes, to: day))
            }
            ForEach(timed) { e in
                let slot = layout[e.id] ?? (0, 1)
                let start = max(e.start, day)
                let end = min(e.end, dayEnd)
                let y = CGFloat(start.timeIntervalSince(day) / 3600) * hourHeight
                let h = max(22, CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight - 2)
                let w = (width - 6) / CGFloat(slot.1)
                Button { model.selectedEvent = e } label: {
                    EventBlock(event: e, selected: model.selectedEvent?.id == e.id, compact: h < 40)
                }
                .buttonStyle(.plain)
                .frame(width: max(10, w - 2), height: h)
                .offset(x: 3 + CGFloat(slot.0) * w, y: y + 1)
            }
            if Calendar.current.isDateInToday(day) {
                let y = CGFloat(Date().timeIntervalSince(day) / 3600) * hourHeight
                Rectangle().fill(Slyy.accent).frame(height: 2).offset(y: y).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: hourHeight * 24)
        .overlay(alignment: .leading) { Rectangle().fill(Slyy.line).frame(width: 1) }
    }

    /// Column index and column count for overlapping events.
    static func layout(_ events: [CalendarEvent]) -> [String: (Int, Int)] {
        let sorted = events.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        var result: [String: (Int, Int)] = [:]
        var cluster: [CalendarEvent] = []
        var columnsEnd: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            for e in cluster { result[e.id] = (result[e.id]?.0 ?? 0, columnsEnd.count) }
            cluster = []
            columnsEnd = []
        }
        for e in sorted {
            if e.start >= clusterEnd { flush() }
            if let col = columnsEnd.firstIndex(where: { $0 <= e.start }) {
                columnsEnd[col] = e.end
                result[e.id] = (col, 1)
            } else {
                columnsEnd.append(e.end)
                result[e.id] = (columnsEnd.count - 1, 1)
            }
            cluster.append(e)
            clusterEnd = max(clusterEnd, e.end)
        }
        flush()
        return result
    }
}

extension AppModel {
    func color(of event: CalendarEvent) -> Color {
        Color(hex: calendars.first { $0.url == event.calendarURL }?.color) ?? Slyy.accent
    }

    func iDeclined(_ event: CalendarEvent) -> Bool {
        myStatus(in: event) == .declined
    }
}

/// Tinted block with a 3 px top border in the calendar colour; solid accent when selected.
struct EventBlock: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent
    var selected = false
    var compact = false

    var body: some View {
        let color = model.color(of: event)
        let declined = model.iDeclined(event)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if event.videoURL != nil { Image(systemName: SlyyIcon.video).font(.system(size: 9, weight: .bold)) }
                Text(event.summary.isEmpty ? String(localized: "New event") : event.summary)
                    .font(Slyy.font(12, .semibold))
                    .lineLimit(compact ? 1 : 2)
                if declined { Text("· declined").font(Slyy.font(12)) }
            }
            if !compact {
                Text(event.start.formatted(date: .omitted, time: .shortened)).font(Slyy.font(12))
                if !event.location.isEmpty && event.location != event.videoURL?.absoluteString {
                    Text(event.location).font(Slyy.font(12)).lineLimit(1)
                }
            }
        }
        .foregroundStyle(selected ? Color.white : Slyy.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? Slyy.accent : color.opacity(0.14))
        .overlay(alignment: .top) { Rectangle().fill(selected ? Slyy.accent : color).frame(height: 3) }
        .overlay(selected ? Rectangle().stroke(Slyy.ink, lineWidth: 2).padding(-1) : nil)
        .opacity(declined ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

struct EventChip: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent

    var body: some View {
        Text(event.summary)
            .font(Slyy.font(12))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.color(of: event).opacity(0.18))
    }
}

struct MonthGridView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let start = model.range(for: model.calendarDate, mode: .month).0
        let month = Calendar.current.component(.month, from: model.calendarDate)
        let days = (0..<42).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(days[i].formatted(.dateTime.weekday(.abbreviated)))
                        .font(Slyy.font(12))
                        .foregroundStyle(Slyy.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 6)
            .bottomHairline()
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            cell(days[row * 7 + col], inMonth: Calendar.current.component(.month, from: days[row * 7 + col]) == month)
                        }
                    }
                }
            }
        }
    }

    func cell(_ day: Date, inMonth: Bool) -> some View {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let list = model.visibleEvents.filter { $0.overlaps(day, end) }
        let today = Calendar.current.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.day()))
                .font(Slyy.font(13, today ? .bold : .regular))
                .foregroundStyle(today ? Color.white : (inMonth ? Slyy.ink : Slyy.lineStrong))
                .frame(minWidth: 22, minHeight: 22)
                .background(today ? Slyy.accent : Color.clear, in: Circle())
            ForEach(list.prefix(3)) { e in
                Button { model.selectedEvent = e } label: {
                    HStack(spacing: 4) {
                        Rectangle().fill(model.color(of: e)).frame(width: 3, height: 12)
                        Text(e.isAllDay ? e.summary : "\(e.start.formatted(date: .omitted, time: .shortened)) \(e.summary)")
                            .lineLimit(1)
                    }
                    .font(Slyy.font(11))
                    .foregroundStyle(Slyy.ink)
                }
                .buttonStyle(.plain)
            }
            if list.count > 3 {
                Text("+\(list.count - 3) more").font(Slyy.font(11)).foregroundStyle(Slyy.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 84)
        .background(Calendar.current.isDateInWeekend(day) ? Slyy.sidebar : Color.white)
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) { Rectangle().stroke(Slyy.line, lineWidth: 0.5) }
        .onTapGesture(count: 2) {
            model.newEvent(at: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day))
        }
        .onTapGesture {
            model.calendarDate = day
            model.calendarMode = .day
        }
    }
}
