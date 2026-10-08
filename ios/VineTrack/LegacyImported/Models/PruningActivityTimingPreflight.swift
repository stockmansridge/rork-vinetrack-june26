import Foundation

/// One pure validation boundary before pruning-editor activity and Work Task writes.
nonisolated enum PruningActivityTimingPreflight {
    nonisolated enum Failure: LocalizedError, Equatable {
        case missingDate, invalidZone, invalidTiming
        var errorDescription: String? {
            switch self {
            case .missingDate: "Business date unavailable. Choose the activity's actual work date before saving or changing Work Tasks."
            case .invalidZone: "The vineyard timezone is unavailable. Correct Region & Units before continuing."
            case .invalidTiming: "Finish time must follow start time. Your pruning draft has not been discarded."
            }
        }
    }

    static func prepare(_ draft: PruningActivityDraft, timezone: String) throws -> PruningActivityDraft {
        guard draft.businessDateUnavailable != true, draft.date.timeIntervalSince1970.isFinite else { throw Failure.missingDate }
        guard let zone = TimeZone(identifier: timezone) else { throw Failure.invalidZone }
        if let start = draft.startTime, let finish = draft.finishTime, finish <= start { throw Failure.invalidTiming }
        var result = draft
        if draft.businessDateSnapshot == nil || draft.businessDateSnapshotInstant != draft.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            result.businessDateSnapshot = formatter.string(from: draft.date)
            result.businessDateSnapshotInstant = draft.date
        }
        return result
    }
}
