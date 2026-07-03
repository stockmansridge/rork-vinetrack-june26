package com.rork.vinetrack.ui.main

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.Coronavirus
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.FactCheck
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.AdminPanelSettings
import androidx.compose.material.icons.filled.GppGood
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.PrecisionManufacturing
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.rork.vinetrack.ui.theme.VineColors

/**
 * Stable, named bottom-navigation destinations. Using an enum (rather than raw
 * indices) means future tab changes can't silently break existing navigation.
 */
enum class MainTab(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Filled.Home),
    Pins("Pins", Icons.Filled.LocationOn),
    Trip("Trip", Icons.Filled.DirectionsCar),
    Program("Program", Icons.Filled.WaterDrop),
    Settings("Settings", Icons.Filled.Settings),
}

/** Logical grouping used to organise the More / Tools hub. */
enum class ToolGroup(val label: String) {
    Vineyard("Vineyard"),
    Operations("Operations"),
    Records("Records"),
    Account("Account"),
}

/**
 * Secondary surfaces reachable from the More hub (and a few Home shortcuts).
 * Each carries its own presentation metadata so the hub can render every tool
 * consistently from a single source of truth.
 */
enum class ToolRoute(
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val tint: Color,
    val group: ToolGroup,
) {
    Pins("Pins", "Map markers & issues", Icons.Filled.LocationOn, VineColors.Orange, ToolGroup.Vineyard),
    Blocks("Blocks", "Paddocks & rows", Icons.Filled.Grass, VineColors.LeafGreen, ToolGroup.Vineyard),
    Growth("Growth Stage Records", "Phenology records", Icons.Filled.Spa, VineColors.LeafGreen, ToolGroup.Vineyard),
    GrowthStageImages("Growth Stage Images", "E-L reference photos", Icons.Filled.PhotoLibrary, VineColors.LeafGreen, ToolGroup.Vineyard),
    GrowthStageConfig("E-L Growth Stages", "Enable stages for recording", Icons.Filled.Checklist, VineColors.LeafGreen, ToolGroup.Vineyard),
    Irrigation("Irrigation", "Water planning", Icons.Filled.Opacity, VineColors.Cyan, ToolGroup.Vineyard),
    WorkTasks("Work Tasks", "Labour & machine logs", Icons.Filled.Assignment, VineColors.Indigo, ToolGroup.Operations),
    DiseaseRisk("Disease Risk", "Downy, Powdery & Botrytis", Icons.Filled.Coronavirus, VineColors.LeafGreen, ToolGroup.Operations),
    Spray("Spray", "Applications & programs", Icons.Filled.WaterDrop, VineColors.Info, ToolGroup.Operations),
    SprayEquipment("Spray & Equipment", "Spray Management, Equipment & Tractors, Chemicals", Icons.Filled.WaterDrop, VineColors.Info, ToolGroup.Operations),
    SprayManagement("Spray Management", "Chemicals, equipment & presets", Icons.Filled.Science, VineColors.Info, ToolGroup.Operations),
    OptimalRipeness("Optimal Ripeness", "GDD progress to harvest target", Icons.Filled.Thermostat, VineColors.Orange, ToolGroup.Operations),
    Yield("Yield", "Forecasts & harvest", Icons.Filled.Scale, VineColors.Orange, ToolGroup.Records),
    CostReports("Cost Reports", "Season, block & variety costs", Icons.Filled.Payments, VineColors.Indigo, ToolGroup.Records),
    Maintenance("Service & Maintenance", "Equipment & repairs", Icons.Filled.Build, VineColors.EarthBrown, ToolGroup.Records),
    FuelLog("Fuel Log", "Fills & usage rate", Icons.Filled.LocalGasStation, VineColors.Pink, ToolGroup.Records),
    Equipment("Equipment", "Tractors, machines, spray & fuel", Icons.Filled.PrecisionManufacturing, VineColors.EarthBrown, ToolGroup.Records),
    TeamAccess("Team & Access", "Manage members and invitations", Icons.Filled.Group, VineColors.Info, ToolGroup.Account),
    RolesPermissions("Roles & Permissions", "What each role can see and do", Icons.Filled.GppGood, VineColors.Info, ToolGroup.Account),
    Alerts("Alerts & Notifications", "Irrigation, pins, weather & spray reminders", Icons.Filled.NotificationsActive, VineColors.Destructive, ToolGroup.Account),
    OperationPreferences("Operation Preferences", "Season E-L, spray/tank, yield", Icons.Filled.Tune, VineColors.Orange, ToolGroup.Operations),
    AppPreferences("Preferences", "Appearance, tracking, photos & AI", Icons.Filled.Tune, VineColors.Indigo, ToolGroup.Account),
    TripFunctions("Trip Functions", "Custom maintenance operations", Icons.Filled.Agriculture, VineColors.Indigo, ToolGroup.Operations),
    OperatorCategories("Team Operations", "Operator Categories", Icons.Filled.Group, VineColors.Info, ToolGroup.Operations),
    TripAudit("Trip Audit", "Find & fix trips on the wrong vineyard", Icons.Filled.FactCheck, VineColors.Orange, ToolGroup.Account),
    WeatherData("Weather Data & Forecasting", "Forecast source, station & sensors", Icons.Filled.CloudQueue, VineColors.Info, ToolGroup.Operations),
    VineyardLocation("Location & Calculation", "Coordinates, GDD mode & reset", Icons.Filled.Thermostat, VineColors.Orange, ToolGroup.Vineyard),
    Settings("Settings", "Account & preferences", Icons.Filled.Settings, VineColors.Primary, ToolGroup.Account),
    RegionUnits("Region & Units", "Country, currency & units", Icons.Filled.Straighten, VineColors.Indigo, ToolGroup.Account),
    SyncStatus("Sync", "Cloud sync for pins, paddocks & trips", Icons.Filled.Sync, VineColors.Cyan, ToolGroup.Account),
    OfflineReadiness("Offline Readiness", "Check this device is ready for no-service areas", Icons.Filled.GppGood, VineColors.Success, ToolGroup.Account),
    BiometricSettings("Sign-in", "Biometric unlock for this device", Icons.Filled.Fingerprint, VineColors.LeafGreen, ToolGroup.Account),
    ContactSupport("Contact Support", "Send feedback, feature requests or report an issue", Icons.Filled.Email, VineColors.Success, ToolGroup.Account),
    DeleteAccount("Delete Account", "Permanently remove your account", Icons.Filled.DeleteForever, VineColors.Destructive, ToolGroup.Account),
    Admin("Admin", "Platform users, vineyards & feature flags", Icons.Filled.AdminPanelSettings, VineColors.Destructive, ToolGroup.Account),
}
