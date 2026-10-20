import SwiftUI
import BrainCore

struct EventEditor: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    @State var event: BrainEvent
    @State private var confirmDelete = false

    private var weekdaySymbols: [String] { Calendar.current.shortWeekdaySymbols }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $event.title).font(.title3.weight(.semibold))
                    TextField("Location", text: Binding($event.location, default: ""))
                    TextField("Tag (e.g. school, sports)", text: Binding($event.tag, default: ""))
                }
                Section {
                    Toggle("All day", isOn: $event.isAllDay)
                    DatePicker("Starts", selection: $event.start, displayedComponents: event.isAllDay ? .date : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $event.end, in: event.start..., displayedComponents: event.isAllDay ? .date : [.date, .hourAndMinute])
                }
                Section("Repeat") {
                    Picker("Repeat", selection: $event.recurrence.frequency) {
                        ForEach(RecurrenceRule.Frequency.allCases) { Text($0.label).tag($0) }
                    }
                    if event.recurrence.frequency == .weekly {
                        HStack {
                            ForEach(1...7, id: \.self) { d in
                                let on = event.recurrence.weekdays.contains(d)
                                Button(String(weekdaySymbols[d - 1].prefix(2))) {
                                    if on { event.recurrence.weekdays.removeAll { $0 == d } } else { event.recurrence.weekdays.append(d) }
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.bold))
                                .frame(width: 32, height: 32)
                                .background(on ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Circle())
                                .foregroundStyle(on ? .white : .primary)
                            }
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: Binding($event.notes, default: ""), axis: .vertical).lineLimit(3...8)
                }
                if store.event(event.id) != nil {
                    Section {
                        Button("Delete event", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(store.event(event.id) == nil ? "New event" : "Edit event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if event.end < event.start { event.end = event.start.addingTimeInterval(3600) }
                        store.upsert(event)
                        dismiss()
                    }
                    .disabled(event.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(event.title)?", isPresented: $confirmDelete) {
                Button(event.recurrence.isRepeating ? "Delete all repeats" : "Delete", role: .destructive) {
                    store.delete(event)
                    dismiss()
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
    }
}

struct TaskEditor: View {
    @EnvironmentObject var store: BrainStore
    @Environment(\.dismiss) private var dismiss
    @State var task: BrainTask

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $task.title).font(.title3.weight(.semibold))
                    TextField("Class / course", text: Binding($task.course, default: ""))
                    if let link = task.link, let url = URL(string: link) {
                        Button { Platform.open(url) } label: { Label("Open in Google Classroom", systemImage: "arrow.up.right.square") }
                    }
                }
                Section("Due") {
                    Toggle("Has a due date", isOn: Binding(
                        get: { task.due != nil },
                        set: { task.due = $0 ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) : nil }))
                    if task.due != nil {
                        DatePicker("Due", selection: Binding($task.due, default: Date()))
                    }
                }
                Section {
                    Stepper(value: Binding(get: { task.estimatedMinutes }, set: { task.estimatedMinutes = $0; task.estimateIsUserSet = true }),
                            in: 5...600, step: 5) {
                        LabeledContent("Time needed", value: Scheduler.durationText(task.estimatedMinutes))
                    }
                    Picker("Difficulty", selection: $task.difficulty) {
                        Text("Easy").tag(1)
                        Text("Medium").tag(2)
                        Text("Hard").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Picker("Priority", selection: $task.priority) {
                        ForEach(BrainTask.Priority.allCases) { Text($0.label).tag($0) }
                    }
                    if let actual = task.actualMinutes {
                        LabeledContent("Time spent so far", value: Scheduler.durationText(actual))
                    }
                } header: {
                    Text("Planning")
                } footer: {
                    Text("The check-in planner uses time, difficulty and priority to order your work. Hard tasks go where your energy is.")
                }
                Section("Notes") {
                    TextField("Notes", text: Binding($task.notes, default: ""), axis: .vertical).lineLimit(3...10)
                }
                if store.task(task.id) != nil {
                    Section {
                        Toggle("Completed", isOn: $task.isCompleted)
                        Button("Delete", role: .destructive) {
                            store.delete(task)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(store.task(task.id) == nil ? "New to-do" : "Edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if task.isCompleted && task.completedAt == nil { task.completedAt = Date() }
                        store.upsert(task)
                        dismiss()
                    }
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 560)
    }
}

extension Binding {
    /// Edit an optional value with a non-optional control; empty strings become nil.
    init<T: Equatable>(_ source: Binding<T?>, default value: T) where Value == T {
        self.init(
            get: { source.wrappedValue ?? value },
            set: { newValue in
                if let s = newValue as? String, s.isEmpty { source.wrappedValue = nil } else { source.wrappedValue = newValue }
            })
    }
}
