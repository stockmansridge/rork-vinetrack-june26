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

    /// Whether this role may AGREE a price in the field — today, the piece rate
    /// per vine on a job that has not been priced yet — and see the resulting
    /// total while entering it.
    ///
    /// Deliberately WIDER than `canViewFinancials`: supervisors run the crew and
    /// settle the rate at the vine, so blocking them would push pricing onto
    /// paper. It is deliberately NARROWER than review authority: entering a
    /// price is not permission to revisit or change one. Once a job is priced,
    /// only `canViewFinancials` roles may see or amend that figure, and no
    /// aggregate total or report is ever exposed by this flag.
    var canEnterPricing: Bool {
        switch self {
        case .owner, .manager, .supervisor:
            true
        case .operator:
            false
        }
    }

    /// May change the vineyard's shared spray program.
    ///
    /// Mirrors the `spray_jobs_update_managers` RLS policy (sql/032) EXACTLY:
    /// `has_vineyard_role(vineyard_id, ['owner','manager'])`. Stated as its own
    /// flag rather than borrowed from a similar one so that if the policy ever
    /// changes, there is a single place on the client that has to change with
    /// it — and so it can never be widened by accident to make a button appear.
    var canManageSprayProgram: Bool {
        switch self {
        case .owner, .manager:
            true
        case .supervisor, .operator:
            false
        }
    }

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
