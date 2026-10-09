import Foundation

/// Vineyard-calendar business dates remain independent from completion audit instants.
nonisolated enum WorkTaskCompletion {
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func workDate(_ task: WorkTask) -> Date { task.startDate ?? task.date }

    /// PostgreSQL business date fields use the leading UTC calendar component, like Portal calendarDate.
    static func businessDay(_ stored: Date, timeZone: TimeZone) -> Date {
        let utc = calendar(TimeZone(secondsFromGMT: 0)!)
        let parts = utc.dateComponents([.year, .month, .day], from: stored)
        return calendar(timeZone).date(from: parts) ?? stored
    }

    static func workDate(_ task: WorkTask, timeZone: TimeZone) -> Date { businessDay(workDate(task), timeZone: timeZone) }

    static func displayedDate(_ task: WorkTask, timeZone: TimeZone) -> Date? {
        guard task.isFinalized else { return nil }
        if let end = task.endDate { return businessDay(end, timeZone: timeZone) }
        return task.completedAt ?? task.finalizedAt
    }

    static func displayedDate(_ task: WorkTask) -> Date? {
        task.isFinalized ? (task.endDate ?? task.completedAt ?? task.finalizedAt) : nil
    }

    static func isValid(_ selected: Date, task: WorkTask, timeZone: TimeZone, now: Date) -> Bool {
        let calendar = calendar(timeZone)
        let day = calendar.startOfDay(for: selected)
        return (task.isStageScheduled || day >= calendar.startOfDay(for: workDate(task, timeZone: timeZone))) && day <= calendar.startOfDay(for: now)
    }

    static func complete(_ task: WorkTask, selected: Date, timeZone: TimeZone, now: Date, userId: String) -> WorkTask? {
        guard isValid(selected, task: task, timeZone: timeZone, now: now) else { return nil }
        var result = task
        result.isFinalized = true
        result.endDate = calendar(timeZone).startOfDay(for: selected)
        result.finalizedAt = now
        result.finalizedBy = userId
        result.completedBy = UUID(uuidString: userId)
        result.completedAt = now
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
        result.completedBy = nil
        result.completedAt = nil
        return result
    }
}
