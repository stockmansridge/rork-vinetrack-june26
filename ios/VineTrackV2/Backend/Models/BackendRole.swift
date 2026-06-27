import Foundation

nonisolated enum BackendRole: String, Codable, CaseIterable, Sendable {
    case owner
    case manager
    case supervisor
    case `operator`

    var canViewFinancials: Bool {
        switch self {
        case .owner, .manager:
            true
        case .supervisor, .operator:
            false
        }
    }

    /// Whether this role may see any costing data (labour/fuel/chemical/
    /// total trip cost, operator hourly rates, fuel cost per litre, etc.).
    /// Owners and managers only. Supervisors and operators are blocked from
    /// every costing surface — UI, exports, debug views — to keep rates private.
    var canViewCosting: Bool { canViewFinancials }

    var canChangeSettings: Bool {
        switch self {
        case .owner, .manager:
            true
        case .supervisor, .operator:
            false
        }
    }

    var canDeleteOperationalRecords: Bool {
        switch self {
        case .owner, .manager, .supervisor:
            true
        case .operator:
            false
        }
    }

    var canInviteMembers: Bool {
        switch self {
        case .owner, .manager:
            true
        case .supervisor, .operator:
            false
        }
    }

    var canExportFinancialReports: Bool {
        switch self {
        case .owner, .manager:
            true
        case .supervisor, .operator:
            false
        }
    }

    var canManageBilling: Bool {
        switch self {
        case .owner, .manager:
            true
        case .supervisor, .operator:
            false
        }
    }

    var canEditRecords: Bool {
        switch self {
        case .owner, .manager, .supervisor, .operator:
            true
        }
    }

    var canCreateOperationalRecords: Bool {
        switch self {
        case .owner, .manager, .supervisor, .operator:
            true
        }
    }
}
