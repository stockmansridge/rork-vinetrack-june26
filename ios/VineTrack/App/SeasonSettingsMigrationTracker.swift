import Foundation

/// Remembers, per vineyard, whether this device has already reconciled its
/// legacy local season start (month/day) with the shared vineyard value in
/// Supabase (sql/108). Before a decision is recorded, an editing user whose
/// local value diverges from the shared one gets a one-time prompt; after a
/// decision (or for read-only members) the shared value is always adopted.
enum SeasonSettingsMigrationTracker {
    private static let keyPrefix = "seasonSettingsMigrationDecided."

    static func hasDecided(_ vineyardId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: keyPrefix + vineyardId.uuidString)
    }

    static func markDecided(_ vineyardId: UUID) {
        UserDefaults.standard.set(true, forKey: keyPrefix + vineyardId.uuidString)
    }
}

/// Payload for the one-time local-vs-shared season settings reconciliation
/// prompt shown to owners/managers whose device has a diverging legacy value.
struct SeasonMigrationPrompt: Identifiable, Equatable {
    let vineyardId: UUID
    let localMonth: Int
    let localDay: Int
    let sharedMonth: Int
    let sharedDay: Int

    var id: UUID { vineyardId }

    private static func label(month: Int, day: Int) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        let name = df.standaloneMonthSymbols[max(0, min(11, month - 1))]
        return "\(day) \(name)"
    }

    var localLabel: String { Self.label(month: localMonth, day: localDay) }
    var sharedLabel: String { Self.label(month: sharedMonth, day: sharedDay) }
}
