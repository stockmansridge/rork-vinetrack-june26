import Foundation

/// Bridges a vineyard calendar day to UI dates; persisted snapshots never use UTC conversion.
nonisolated enum FertiliserApplicationDate {
    static func snapshot(_ date: Date, timeZone: TimeZone) -> String {
        formatter(timeZone).string(from: date)
    }

    static func date(_ snapshot: String?, timeZone: TimeZone) -> Date? {
        guard let snapshot, snapshot.count == 10 else { return nil }
        let formatter = formatter(timeZone)
        guard let date = formatter.date(from: snapshot), formatter.string(from: date) == snapshot else { return nil }
        return date
    }

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
