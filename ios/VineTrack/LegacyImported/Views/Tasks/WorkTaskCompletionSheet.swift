import SwiftUI

struct WorkTaskCompletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: WorkTask
    let timeZone: TimeZone
    let onConfirm: (Date) -> Bool
    @State private var selectedDate: Date

    init(task: WorkTask, timeZone: TimeZone, onConfirm: @escaping (Date) -> Bool) {
        self.task = task
        self.timeZone = timeZone
        self.onConfirm = onConfirm
        let initial = task.isFinalized ? WorkTaskCompletion.displayedDate(task) ?? Date() : Date()
        _selectedDate = State(initialValue: initial)
    }

    private var today: Date { WorkTaskCompletion.calendar(timeZone).startOfDay(for: Date()) }
    private var firstDay: Date { WorkTaskCompletion.calendar(timeZone).startOfDay(for: WorkTaskCompletion.workDate(task)) }
    private var valid: Bool { WorkTaskCompletion.isValid(selectedDate, task: task, timeZone: timeZone, now: Date()) }

    private var workDateLabel: String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        return formatter.string(from: WorkTaskCompletion.workDate(task))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Work Date") {
                        Text(workDateLabel)
                    }
                    if firstDay <= today {
                        DatePicker("Completed Date", selection: $selectedDate, in: firstDay...today, displayedComponents: .date)
                            .environment(\.timeZone, timeZone)
                            .environment(\.calendar, WorkTaskCompletion.calendar(timeZone))
                    } else {
                        Text("This Work Date is in the future. The task cannot be completed yet.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Completed Date is when the work finished. The time you press Complete is recorded separately for audit.")
                }
            }
            .navigationTitle(task.isFinalized ? "Edit Completed Date" : "Complete Work Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(task.isFinalized ? "Save date" : "Complete") {
                        if onConfirm(selectedDate) { dismiss() }
                    }
                    .disabled(!valid)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
    }
}
