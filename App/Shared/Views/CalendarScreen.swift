import SwiftUI
import BrainCore

struct CalendarScreen: View {
    @EnvironmentObject var store: BrainStore
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var editingEvent: BrainEvent?
    @State private var editingTask: BrainTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                QuickAddBar()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        monthCard.frame(width: 380)
                        dayCard.frame(minWidth: 320)
                    }
                    VStack(spacing: 20) {
                        monthCard
                        dayCard
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.canvas)
        .navigationTitle("Calendar")
        .sheet(item: $editingEvent) { EventEditor(event: $0) }
        .sheet(item: $editingTask) { TaskEditor(task: $0) }
        .toolbar {
            ToolbarItem {
                Button("Today") { jump(to: Date()) }
            }
        }
    }

    private func jump(to date: Date) {
        withAnimation {
            selected = Calendar.current.startOfDay(for: date)
            month = Calendar.current.dateInterval(of: .month, for: date)!.start
        }
    }

    // MARK: Month grid

    private var gridDays: [Date] {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: month)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let first = cal.date(byAdding: .day, value: -lead, to: month)!
        return (0..<42).map { cal.date(byAdding: .day, value: $0, to: first)! }
    }

    private var monthCard: some View {
        let cal = Calendar.current
        let days = gridDays
        let range = DateInterval(start: days.first!, end: cal.date(byAdding: .day, value: 1, to: days.last!)!)
        let occ = store.occurrences(in: range)
        let byDay = Dictionary(grouping: occ) { cal.startOfDay(for: $0.start) }
        let dueByDay = Dictionary(grouping: store.pendingTasks.filter { $0.due != nil }) { cal.startOfDay(for: $0.due!) }
        let symbols = (0..<7).map { cal.veryShortWeekdaySymbols[($0 + cal.firstWeekday - 1) % 7] }

        return VStack(spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.title3.weight(.bold))
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(symbols.indices, id: \.self) { i in
                    Text(symbols[i]).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    DayCell(day: day,
                            inMonth: cal.isDate(day, equalTo: month, toGranularity: .month),
                            isSelected: cal.isDate(day, inSameDayAs: selected),
                            isToday: cal.isDateInToday(day),
                            colors: (byDay[day] ?? []).prefix(3).map { Brand.color(for: $0) },
                            dueCount: dueByDay[day]?.count ?? 0)
                        .onTapGesture { withAnimation(.snappy) { selected = day } }
                }
            }
        }
        .card()
    }

    private func shiftMonth(_ delta: Int) {
        withAnimation { month = Calendar.current.date(byAdding: .month, value: delta, to: month)! }
    }

    // MARK: Selected day

    private var dayCard: some View {
        let occ = store.occurrences(on: selected)
        let due = store.tasksDue(on: selected)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: selected.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                         trailing: Calendar.current.isDateInToday(selected) ? "Today" : nil)
            if occ.isEmpty && due.isEmpty {
                EmptyHint(icon: "calendar.badge.plus", text: "Free day. Type above to add something.")
            }
            ForEach(occ) { o in
                OccurrenceRow(occurrence: o)
                    .contentShape(Rectangle())
                    .onTapGesture { editingEvent = store.event(o.eventID) }
                    .contextMenu {
                        if o.eventID != nil {
                            Button("Edit") { editingEvent = store.event(o.eventID) }
                            Button("Delete this one", role: .destructive) { store.deleteOccurrence(o) }
                        }
                    }
                Divider()
            }
            if !due.isEmpty {
                Text("DUE").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(due) { t in
                    TaskRow(task: t).contentShape(Rectangle()).onTapGesture { editingTask = t }
                }
            }
        }
        .card()
    }
}

struct DayCell: View {
    var day: Date
    var inMonth: Bool
    var isSelected: Bool
    var isToday: Bool
    var colors: [Color]
    var dueCount: Int

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.callout.weight(isToday || isSelected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? .white : (inMonth ? (isToday ? Brand.violet : .primary) : .secondary.opacity(0.5)))
                .frame(width: 32, height: 32)
                .background {
                    if isSelected { Circle().fill(Brand.gradient) }
                    else if isToday { Circle().stroke(Brand.violet, lineWidth: 1.5) }
                }
            HStack(spacing: 2) {
                ForEach(colors.indices, id: \.self) { i in Circle().fill(colors[i]).frame(width: 5, height: 5) }
                if dueCount > 0 { RoundedRectangle(cornerRadius: 1).fill(.orange).frame(width: 5, height: 5) }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}
