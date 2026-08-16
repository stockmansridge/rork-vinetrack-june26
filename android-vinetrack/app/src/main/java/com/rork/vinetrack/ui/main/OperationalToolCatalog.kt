package com.rork.vinetrack.ui.main

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Coronavirus
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.rork.vinetrack.ui.theme.VineColors

/**
 * One tile in the Home "Operational Tools" grid.
 *
 * [id] is a STABLE identifier shared with iOS, the Supabase preference table
 * (SQL 159) and later the portal. Renaming a tool changes [title]/[icon] only.
 */
data class OperationalToolDefinition(
    val id: String,
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val tint: Color,
    val route: ToolRoute,
    /** Owner/Manager costing permission. Customisation never overrides this. */
    val requiresCosting: Boolean = false,
)

/**
 * The single source of truth for the Android Operational Tools grid. The grid
 * and the customisation screen both render from this list — there is
 * deliberately no second hard-coded list.
 *
 * Order matches the iOS `OperationalToolCatalog.all` and the SQL 159
 * `display_order` exactly, so the VineTrack default layout is identical on
 * every platform.
 */
object OperationalToolCatalog {

    val all: List<OperationalToolDefinition> = listOf(
        OperationalToolDefinition(
            id = "work_tasks",
            title = "Work Tasks",
            subtitle = "Log & calculate",
            icon = Icons.Filled.Group,
            tint = VineColors.Indigo,
            route = ToolRoute.WorkTasks,
        ),
        OperationalToolDefinition(
            id = "equipment_maintenance",
            title = "Maintenance Log",
            subtitle = "Repairs & jobs",
            icon = Icons.Filled.Build,
            tint = VineColors.EarthBrown,
            route = ToolRoute.Maintenance,
        ),
        OperationalToolDefinition(
            id = "fuel_log",
            title = "Fuel Log",
            subtitle = "Purchases & refuelling",
            icon = Icons.Filled.LocalGasStation,
            tint = VineColors.Pink,
            route = ToolRoute.FuelLog,
        ),
        OperationalToolDefinition(
            id = "irrigation_advisor",
            title = "Irrigation Advisor",
            subtitle = "Water planning",
            icon = Icons.Filled.Opacity,
            tint = VineColors.Cyan,
            route = ToolRoute.Irrigation,
        ),
        OperationalToolDefinition(
            id = "disease_risk",
            title = "Disease Risk",
            subtitle = "Downy/Powdery/Botrytis",
            icon = Icons.Filled.Coronavirus,
            tint = VineColors.LeafGreen,
            route = ToolRoute.DiseaseRisk,
        ),
        OperationalToolDefinition(
            id = "yield_records",
            title = "Yields",
            subtitle = "Forecasting, Sampling & Recording",
            icon = Icons.Filled.Scale,
            tint = VineColors.Orange,
            route = ToolRoute.Yield,
        ),
        OperationalToolDefinition(
            id = "growth_stages",
            title = "Growth Stage Records",
            subtitle = "Phenology records",
            icon = Icons.Filled.Spa,
            tint = VineColors.LeafGreen,
            route = ToolRoute.Growth,
        ),
        OperationalToolDefinition(
            id = "optimal_ripeness",
            title = "Optimal Ripeness",
            subtitle = "GDD & harvest window",
            icon = Icons.Filled.Thermostat,
            tint = VineColors.Orange,
            route = ToolRoute.OptimalRipeness,
        ),
        OperationalToolDefinition(
            id = "cost_reports",
            title = "Cost Reports",
            subtitle = "Season, block & variety",
            icon = Icons.Filled.Payments,
            tint = VineColors.Indigo,
            route = ToolRoute.CostReports,
            requiresCosting = true,
        ),
        OperationalToolDefinition(
            id = "fertiliser_calculator",
            title = "Fertiliser Calculator",
            subtitle = "Rates, packs & costs",
            icon = Icons.Filled.Grain,
            tint = VineColors.LeafGreen,
            route = ToolRoute.FertiliserCalculator,
        ),
        OperationalToolDefinition(
            id = "pruning_tracker",
            title = "Pruning Tracker",
            subtitle = "Row progress & crew rates",
            icon = Icons.Filled.ContentCut,
            tint = VineColors.Cyan,
            route = ToolRoute.PruningTracker,
        ),
        // Public release (SQL 151): Irrigation Records is available to all
        // vineyard roles. The screen resolves the caller's capabilities via
        // get_irrigation_capabilities and the server enforces every action.
        OperationalToolDefinition(
            id = "irrigation_records",
            title = "Irrigation Records",
            subtitle = "Water applied, valves & blocks",
            icon = Icons.Filled.WaterDrop,
            tint = VineColors.Cyan,
            route = ToolRoute.IrrigationRecords,
        ),
        // A dedicated planning tool, deliberately its own tile rather than a screen
        // inside the Spray Calculator: the rotation is decided weeks before a tank is
        // filled, and the individual sprays are drawn from the plan, not the reverse.
        //
        // `id` matches iOS exactly so a saved layout, and the SQL 159 preference row
        // behind it, mean the same thing on both platforms.
        OperationalToolDefinition(
            id = "resistance_planner",
            title = "Resistance Planner",
            subtitle = "Season FRAC rotation",
            icon = Icons.Filled.Shield,
            tint = VineColors.Purple,
            route = ToolRoute.ResistancePlanner,
        ),
    )

    val defaultOrder: List<String> = all.map { it.id }

    fun tool(id: String): OperationalToolDefinition? = all.firstOrNull { it.id == id }

    /**
     * Tools the caller is entitled to see, in VineTrack default order. The grid
     * and the customisation screen both filter through this, so a saved layout
     * can never expose a restricted tool.
     */
    fun authorised(canViewCosting: Boolean): List<OperationalToolDefinition> =
        all.filter { !it.requiresCosting || canViewCosting }

    fun authorisedIds(canViewCosting: Boolean): List<String> =
        authorised(canViewCosting).map { it.id }
}
