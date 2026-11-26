import SwiftUI
import SlyyMailKit

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            switch effectiveMode {
            case .month:
                MonthGridView()
            case .week, .day:
                TimeGridView(days: days)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.newEvent(at: nil) } label: { Label("New Event", systemImage: "plus") }
                Button { model.meetNow() } label: { Label("Meet Now", systemImage: "video") }
            }
        }
        .task(id: model.account?.id) { await model.loadEvents(force: false) }
        .refreshable { await model.loadEvents(force: true) }
    }

    /// iPhone (compact width) shows day instead of week.
    var effectiveMode: CalendarMode {
        if sizeClass == .compact && model.calendarMode == .week { return .day }
        return model.calendarMode
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

    var title: String {
        switch effectiveMode {
        case .day: return model.calendarDate.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .week, .month: return model.calendarDate.formatted(.dateTime.month(.wide).year())
        }
    }

    var header: some View {
        @Bindable var model = model
        return HStack {
            Button("Today") { model.calendarDate = Date(); Task { await model.loadEvents(force: false) } }
            Button { model.moveCalendar(by: -1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button { model.moveCalendar(by: 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            Picker("View", selection: $model.calendarMode) {
                ForEach(CalendarMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .onChange(of: model.calendarMode) { _, _ in Task { await model.loadEvents(force: false) } }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Day/week grid: all-day strip on top, hours below; events placed by time, overlapping ones side by side.
struct TimeGridView: View {
    @Environment(AppModel.self) private var model
    let days: [Date]
    let hourHeight: CGFloat = 48
    let gutter: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            let colWidth = max(40, (geo.size.width - gutter) / CGFloat(max(days.count, 1)))
            VStack(spacing: 0) {
                dayHeaders(colWidth)
                allDayStrip(colWidth)
                Divider()
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
                    .onAppear { proxy.scrollTo(7, anchor: .top) }
                }
            }
        }
    }

    func dayHeaders(_ w: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let today = Calendar.current.isDateInToday(d)
                VStack(spacing: 0) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                    Text(d.formatted(.dateTime.day()))
                        .font(.title3.weight(today ? .bold : .regular))
                        .foregroundStyle(today ? Color.accentColor : .primary)
                }
                .frame(width: w)
                .padding(.vertical, 4)
            }
        }
    }

    func allDayStrip(_ w: CGFloat) -> some View {
        let allDay = model.visibleEvents.filter(\.isAllDay)
        return HStack(alignment: .top, spacing: 0) {
            Text("all-day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
            ForEach(days, id: \.self) { d in
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: d)!
                VStack(spacing: 2) {
                    ForEach(allDay.filter { $0.overlaps(d, dayEnd) }) { e in
                        EventChip(event: e).onTapGesture { model.selectedEvent = e }
                    }
                }
                .frame(width: w)
            }
        }
        .frame(minHeight: allDay.isEmpty ? 0 : 22)
    }

    var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter - 6, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 6)
                    .id(h)
            }
        }
    }

    func dayColumn(_ day: Date, width: CGFloat) -> some View {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let timed = model.visibleEvents.filter { !$0.isAllDay && $0.overlaps(day, dayEnd) }
        let layout = Self.layout(timed)
        return ZStack(alignment: .topLeading) {
            // Hour lines + tap to create
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle().fill(.clear)
                        .frame(height: hourHeight)
                        .overlay(alignment: .top) { Divider() }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { p in
                let minutes = Int(p.y / hourHeight * 60) / 30 * 30
                model.newEvent(at: Calendar.current.date(byAdding: .minute, value: minutes, to: day))
            }
            if Calendar.current.isDateInToday(day) {
                let y = CGFloat(Date().timeIntervalSince(day) / 3600) * hourHeight
                Rectangle().fill(Color.red).frame(height: 1.5).offset(y: y)
            }
            ForEach(timed) { e in
                let slot = layout[e.id] ?? (0, 1)
                let start = max(e.start, day)
                let end = min(e.end, dayEnd)
                let y = CGFloat(start.timeIntervalSince(day) / 3600) * hourHeight
                let h = max(20, CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight - 2)
                let w = (width - 4) / CGFloat(slot.1)
                EventBlock(event: e, selected: model.selectedEvent?.id == e.id)
                    .frame(width: w - 2, height: h)
                    .offset(x: 2 + CGFloat(slot.0) * w, y: y + 1)
                    .onTapGesture { model.selectedEvent = e }
            }
        }
        .frame(width: width, height: hourHeight * 24)
        .overlay(alignment: .leading) { Divider() }
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

struct EventBlock: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent
    var selected = false

    var color: Color {
        Color(hex: model.calendars.first { $0.url == event.calendarURL }?.color) ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if event.videoURL != nil { Image(systemName: "video.fill").imageScale(.small) }
                Text(event.summary.isEmpty ? String(localized: "New Event") : event.summary).fontWeight(.semibold).lineLimit(2)
            }
            Text(event.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(selected ? 0.45 : 0.22), in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(myDecline ? 0.5 : 1)
    }

    var myDecline: Bool {
        model.account.flatMap { event.status(of: $0.email) } == .declined
    }
}

struct EventChip: View {
    @Environment(AppModel.self) private var model
    let event: CalendarEvent

    var body: some View {
        let color = Color(hex: model.calendars.first { $0.url == event.calendarURL }?.color) ?? .accentColor
        Text(event.summary)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
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
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(.caption.weight(today ? .bold : .regular))
                .foregroundStyle(today ? Color.accentColor : inMonth ? .primary : .secondary)
            ForEach(list.prefix(3)) { e in
                HStack(spacing: 3) {
                    Circle().fill(Color(hex: model.calendars.first { $0.url == e.calendarURL }?.color) ?? .accentColor).frame(width: 6, height: 6)
                    Text(e.isAllDay ? e.summary : "\(e.start.formatted(date: .omitted, time: .shortened)) \(e.summary)")
                        .lineLimit(1)
                }
                .font(.caption2)
                .onTapGesture { model.selectedEvent = e }
            }
            if list.count > 3 {
                Text("+\(list.count - 3) more").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) { Rectangle().stroke(.quaternary, lineWidth: 0.5) }
        .onTapGesture(count: 2) {
            model.newEvent(at: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day))
        }
        .onTapGesture {
            model.calendarDate = day
            model.calendarMode = .day
        }
    }
}
