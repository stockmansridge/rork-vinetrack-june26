import Foundation

nonisolated enum ActiveRouteError: LocalizedError {
    case invalidPath
    case alreadyCovered

    var errorDescription: String? {
        switch self {
        case .invalidPath: "Choose a valid starting path in the selected blocks."
        case .alreadyCovered: "That path is already completed or skipped. Choose an unfinished starting path."
        }
    }
}
