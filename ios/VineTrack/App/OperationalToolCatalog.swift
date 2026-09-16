import SwiftUI

/// One tile in the Home "Operational Tools" grid.
///
/// `id` is a STABLE identifier shared with Android, the Supabase preference
/// table (`sql/159`) and (later) the portal. It is never a display name, a
/// screen title or an array position — renaming a tool changes `title` and
/// `icon` only.
struct OperationalTool: Identifiable, Equatable {
    /// What the caller must be entitled to before the tile is offered at all.
    /// Customisation NEVER overrides this: an unauthorised tool is absent from
    /// the grid AND from both customisation sections.
    enum Requirement: Equatable {
        case always
        case costing
        /// Platform System Admin (`public.system_admins`) AND membership of the
        /// selected vineyard.
        ///
        /// Deliberately separate from `.costing`: costing is a VINEYARD role
        /// permission, whereas this is platform authority. A vineyard owner has
        /// the former and never the latter, and conflating them would hand
        /// every customer's owner an unreleased preview.
        case systemAdminPreview
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let requirement: Requirement

    init(
        id: String,
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        requirement: Requirement = .always
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.requirement = requirement
    }
}

/// The single source of truth for the Operational Tools grid on iOS.
///
/// The customisation screen and the grid both render from this catalogue —
/// there is deliberately no second hard-coded list anywhere in the app.
enum OperationalToolCatalog {
    /// VineTrack default order. Matches `sql/159` `display_order` and the
    /// Android `OperationalToolCatalog.all` order exactly.
    static let all: [OperationalTool] = [
        OperationalTool(
            id: "work_tasks",
            title: "Work Tasks",
            subtitle: "Log & calculate",
            icon: "person.2.badge.gearshape.fill",
            tint: .indigo
        ),
        OperationalTool(
            id: "equipment_maintenance",
            title: "Maintenance Log",
            subtitle: "Repairs & jobs",
            icon: "wrench.and.screwdriver.fill",
            tint: VineyardTheme.earthBrown
        ),
        OperationalTool(
            id: "fuel_log",
            title: "Fuel Log",
            subtitle: "Purchases & refuelling",
            icon: "fuelpump.fill",
            tint: .red
        ),
        OperationalTool(
            id: "irrigation_advisor",
            title: "Irrigation Advisor",
            subtitle: "Water planning",
            icon: "drop.fill",
            tint: .cyan
        ),
        OperationalTool(
            id: "disease_risk",
            title: "Disease Risk",
            subtitle: "Downy/Powdery/Botrytis",
            icon: "leaf.arrow.triangle.circlepath",
            tint: .green
        ),
        OperationalTool(
            id: "yield_records",
            title: "Yields",
            subtitle: "Forecasting, Sampling & Recording",
            icon: "chart.bar.fill",
            tint: .orange
        ),
        OperationalTool(
            id: "growth_stages",
            title: "Growth Stage Records",
            subtitle: "Observations & PDF export",
            icon: "leaf.fill",
            tint: VineyardTheme.leafGreen
        ),
        OperationalTool(
            id: "optimal_ripeness",
            title: "Optimal Ripeness",
            subtitle: "GDD & harvest window",
            icon: "thermometer.sun.fill",
            tint: .pink
        ),
        OperationalTool(
            id: "cost_reports",
            title: "Cost Reports",
            subtitle: "Block & variety costing",
            icon: "dollarsign.circle.fill",
            tint: .green,
            requirement: .costing
        ),
        OperationalTool(
            id: "fertiliser_calculator",
            title: "Fertiliser Calculator",
            subtitle: "Rates, packs & costs",
            icon: "circle.hexagongrid.fill",
            tint: .mint
        ),
        OperationalTool(
            id: "pruning_tracker",
            title: "Pruning Tracker",
            subtitle: "Row progress & crew rates",
            icon: "scissors",
            tint: .teal
        ),
        // Public release (SQL 151): available to all vineyard roles. The view
        // resolves the caller's capabilities via get_irrigation_capabilities
        // and the server enforces every action independently.
        OperationalTool(
            id: "irrigation_records",
            title: "Irrigation Records",
            subtitle: "Water applied, valves & blocks",
            icon: "drop.circle.fill",
            tint: .cyan
        ),
        // A dedicated planning tool, deliberately its own tile rather than a screen
        // inside the Spray Calculator: the rotation is decided weeks before a tank is
        // filled, and the individual sprays are drawn from the plan, not the reverse.
        OperationalTool(
            id: "resistance_planner",
            title: "Resistance Planner",
            subtitle: "Season FRAC rotation",
            icon: "shield.lefthalf.filled",
            tint: .purple
        ),
        // System Admin preview (SQL 236). Not released: only an active row in
        // public.system_admins who is ALSO a member of the selected vineyard
        // may see or open it, and the server enforces the same conjunction on
        // every read and write. `id` matches Android exactly.
        OperationalTool(
            id: "vineyard_insights",
            title: "Vineyard Insights",
            subtitle: "Scouting, vintage notes & reports",
            icon: "chart.line.text.clipboard",
            tint: .purple,
            requirement: .systemAdminPreview
        ),
    ]

    static let defaultOrder: [String] = all.map(\.id)

    static func tool(id: String) -> OperationalTool? {
        all.first { $0.id == id }
    }

    /// Tools the caller is entitled to see, in VineTrack default order.
    /// Everything downstream (grid + customisation screen) filters through
    /// this, so a saved layout can never expose a restricted tool.
    ///
    /// `canUseVineyardInsights` must be the resolved `VineyardInsightsAccess`
    /// decision — System Admin AND membership of the selected vineyard — not a
    /// bare `isSystemAdmin` flag. It defaults to `false` so a caller that has
    /// not yet resolved access (or an older call site) fails closed rather
    /// than briefly exposing the preview while the admin check is in flight.
    static func authorised(
        canViewCosting: Bool,
        canUseVineyardInsights: Bool = false
    ) -> [OperationalTool] {
        all.filter { tool in
            switch tool.requirement {
            case .always: return true
            case .costing: return canViewCosting
            case .systemAdminPreview: return canUseVineyardInsights
            }
        }
    }
}
