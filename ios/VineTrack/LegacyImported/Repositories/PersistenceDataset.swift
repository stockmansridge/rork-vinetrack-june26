import Foundation

/// Static categories only: persistence keys and their account/vineyard suffixes never leave the store.
nonisolated enum PersistenceDataset: String, Sendable {
    case pins, blocks, chemicals, trips, sprayRecords, equipment, fuel, growth, workTasks, settings, metadata, other
    case vineyards, sprayPresets, equipmentOptions, sprayEquipment, savedInputs
    case tractors, vineyardMachines, fuelPurchases, tractorFuelLogs, operatorCategories
    case workTaskTypes, workTaskLabour, workTaskMachines, workTaskBlocks, workTaskPieceRates, workTaskMaterials
    case materialCatalogue, vineyardMaterials, tripCostAllocations, pruningLabour, maintenance
    case yieldSessions, damageRecords, historicalYield, yieldDeterminations, pickingRecords, pruningSettings
    case pinMetadata, blockMetadata, chemicalMetadata

    static func classify(_ key: String) -> Self {
        switch key {
        case "vinetrack_pins": return .pins
        case "vinetrack_paddocks": return .blocks
        case "vinetrack_saved_chemicals": return .chemicals
        case "vinetrack_trips": return .trips
        case "vinetrack_spray_records": return .sprayRecords
        case "vinetrack_vineyards": return .vineyards
        case "vinetrack_saved_spray_presets": return .sprayPresets
        case "vinetrack_saved_equipment_options": return .equipmentOptions
        case "vinetrack_spray_equipment": return .sprayEquipment
        case "vinetrack_saved_inputs": return .savedInputs
        case "vinetrack_tractors": return .tractors
        case "vinetrack_vineyard_machines": return .vineyardMachines
        case "vinetrack_fuel_purchases": return .fuelPurchases
        case "vinetrack_tractor_fuel_logs": return .tractorFuelLogs
        case "vinetrack_operator_categories": return .operatorCategories
        case "vinetrack_work_task_types": return .workTaskTypes
        case "vinetrack_work_tasks": return .workTasks
        case "vinetrack_work_task_labour_lines": return .workTaskLabour
        case "vinetrack_work_task_machine_lines": return .workTaskMachines
        case "vinetrack_work_task_paddocks": return .workTaskBlocks
        case "vinetrack_work_task_piece_rate_rows": return .workTaskPieceRates
        case "vinetrack_work_task_materials": return .workTaskMaterials
        case "vinetrack_material_catalogue": return .materialCatalogue
        case "vinetrack_vineyard_materials": return .vineyardMaterials
        case "vinetrack_trip_cost_allocations": return .tripCostAllocations
        case "vinetrack_pruning_activity_labour_lines": return .pruningLabour
        case "vinetrack_maintenance_logs": return .maintenance
        case "vinetrack_yield_sessions": return .yieldSessions
        case "vinetrack_damage_records": return .damageRecords
        case "vinetrack_historical_yield_records": return .historicalYield
        case "vinetrack_yield_determination_results": return .yieldDeterminations
        case "vinetrack_picking_records": return .pickingRecords
        case "vinetrack_pruning_yield_settings": return .pruningSettings
        case "vinetrack_pin_sync_metadata": return .pinMetadata
        case "vinetrack_paddock_sync_metadata": return .blockMetadata
        case "vinetrack_saved_chemical_sync_metadata": return .chemicalMetadata
        default:
            // Only return an allowlisted category, never the input string.
            if key.contains("metadata") || key.contains("pending") { return .metadata }
            if key.contains("growth") { return .growth }
            if key.contains("fuel") { return .fuel }
            if key.contains("equipment") || key.contains("tractor") || key.contains("machine") { return .equipment }
            if key.contains("work_task") { return .workTasks }
            if key.contains("settings") { return .settings }
            return .other
        }
    }
}
