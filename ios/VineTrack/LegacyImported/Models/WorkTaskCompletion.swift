import Foundation

/// Vineyard-calendar business dates remain independent from completion audit instants.
nonisolated enum WorkTaskCompletion {
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func workDate(_ task: WorkTask) -> Date { task.startDate ?? task.date }

    static func displayedDate(_ task: WorkTask) -> Date? {
        task.isFinalized ? (task.endDate ?? task.completedAt ?? task.finalizedAt) : nil
    }

    static func isValid(_ selected: Date, task: WorkTask, timeZone: TimeZone, now: Date) -> Bool {
        let calendar = calendar(timeZone)
        let day = calendar.startOfDay(for: selected)
        return (task.isStageScheduled || day >= calendar.startOfDay(for: workDate(task))) && day <= calendar.startOfDay(for: now)
    }

    static func complete(_ task: WorkTask, selected: Date, timeZone: TimeZone, now: Date, userId: String) -> WorkTask? {
        guard isValid(selected, task: task, timeZone: timeZone, now: now) else { return nil }
        var result = task
        result.isFinalized = true
        result.endDate = calendar(timeZone).startOfDay(for: selected)
        result.finalizedAt = now
        result.finalizedBy = userId
        return result
    }

    static func editDate(_ task: WorkTask, selected: Date, timeZone: TimeZone, now: Date) -> WorkTask? {
        guard task.isFinalized, isValid(selected, task: task, timeZone: timeZone, now: now) else { return nil }
        var result = task
        result.endDate = calendar(timeZone).startOfDay(for: selected)
        return result
    }

    static func reopen(_ task: WorkTask) -> WorkTask {
        var result = task
        result.isFinalized = false
        result.endDate = nil
        result.finalizedAt = nil
        result.finalizedBy = nil
        return result
    }
}
