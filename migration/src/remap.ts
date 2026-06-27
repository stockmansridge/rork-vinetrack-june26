import { createHash } from "node:crypto";

import type {
  AuthUserRecord,
  DisclaimerAcceptanceRecord,
  DisclaimerDryRunReport,
  DuplicateEmailReport,
  IdentityDryRunReport,
  IdentityMapEntry,
  InvitationDryRunReport,
  InvitationRecord,
  JsonRecord,
  JsonValue,
  MapsFile,
  TableReadResult,
  MemberMappingReport,
  Phase16CReportSummary,
  ProfileRecord,
  SourceSnapshot,
  TargetSnapshot,
  VineyardDataConflictReport,
  VineyardDataInventoryEntry,
  VineyardDataInventoryReport,
  VineyardDataPayloadKind,
  VineyardDataTransformReport,
  VineyardDataTransformSkippedRow,
  VineyardMappingReport,
  VineyardMemberRecord,
  VineyardRecord
} from "./types.js";

export const validRoles = new Set(["owner", "manager", "supervisor", "operator"]);

export const vineyardDataKeys = [
  "pins",
  "paddocks",
  "trips",
  "sprayRecords",
  "savedChemicals",
  "savedSprayPresets",
  "savedEquipmentOptions",
  "sprayEquipment",
  "tractors",
  "fuelPurchases",
  "operatorCategories",
  "buttonTemplates",
  "repairButtons",
  "growthButtons",
  "savedCustomPatterns",
  "settings",
  "yieldSessions",
  "damageRecords",
  "historicalYieldRecords",
  "maintenanceLogs",
  "workTasks",
  "grapeVarieties"
];

export const phase16cDestinationTables = [
  "pins",
  "paddocks",
  "trips",
  "spray_records",
  "saved_chemicals",
  "saved_spray_presets",
  "spray_equipment",
  "tractors",
  "fuel_purchases",
  "operator_categories",
  "work_tasks",
  "maintenance_logs",
  "yield_estimation_sessions",
  "damage_records",
  "historical_yield_records",
  "vineyard_button_configs",
  "vineyard_growth_stage_images"
] as const;

export type Phase16CDestinationTable = typeof phase16cDestinationTables[number];

export const vineyardDataTypeToEntityName: Record<string, string> = {
  pins: "pins",
  paddocks: "paddocks",
  trips: "trips",
  spray_records: "sprayRecords",
  sprayRecords: "sprayRecords",
  saved_chemicals: "savedChemicals",
  savedChemicals: "savedChemicals",
  saved_spray_presets: "savedSprayPresets",
  savedSprayPresets: "savedSprayPresets",
  saved_equipment_options: "savedEquipmentOptions",
  savedEquipmentOptions: "savedEquipmentOptions",
  spray_equipment: "sprayEquipment",
  sprayEquipment: "sprayEquipment",
  tractors: "tractors",
  fuel_purchases: "fuelPurchases",
  fuelPurchases: "fuelPurchases",
  operator_categories: "operatorCategories",
  operatorCategories: "operatorCategories",
  button_templates: "buttonTemplates",
  buttonTemplates: "buttonTemplates",
  repair_buttons: "repairButtons",
  repairButtons: "repairButtons",
  growth_buttons: "growthButtons",
  growthButtons: "growthButtons",
  custom_patterns: "savedCustomPatterns",
  saved_custom_patterns: "savedCustomPatterns",
  savedCustomPatterns: "savedCustomPatterns",
  settings: "settings",
  yield_sessions: "yieldSessions",
  yieldSessions: "yieldSessions",
  damage_records: "damageRecords",
  damageRecords: "damageRecords",
  historical_yield_records: "historicalYieldRecords",
  historicalYieldRecords: "historicalYieldRecords",
  maintenance_logs: "maintenanceLogs",
  maintenanceLogs: "maintenanceLogs",
  work_tasks: "workTasks",
  workTasks: "workTasks",
  grape_varieties: "grapeVarieties",
  grapeVarieties: "grapeVarieties"
};

export function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().toLowerCase();
  return trimmed.length > 0 ? trimmed : null;
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export function buildIdentityReport(v1: SourceSnapshot, v2: TargetSnapshot): { report: IdentityDryRunReport; maps: MapsFile } {
  const generatedAt = new Date().toISOString();
  const v1EmailEntries = collectUserEmailEntries(v1.users, v1.profiles.rows);
  const v2EmailEntries = collectUserEmailEntries(v2.users, v2.profiles.rows);
  const v2ByEmail = firstIdByEmail(v2EmailEntries);
  const mappedUsers: IdentityMapEntry[] = [];
  const unmappedV1Users: IdentityMapEntry[] = [];
  const v1UserIdToV2UserId: Record<string, string> = {};

  for (const entry of v1EmailEntries) {
    const v2UserId = entry.email ? v2ByEmail[entry.email] ?? null : null;
    const result: IdentityMapEntry = {
      v1UserId: entry.id,
      v1Email: entry.email,
      v2UserId,
      source: v2UserId ? entry.source : "unmapped"
    };
    mappedUsers.push(result);
    if (v2UserId) v1UserIdToV2UserId[entry.id] = v2UserId;
    else unmappedV1Users.push(result);
  }

  const usersByEmail: Record<string, string> = {};
  for (const [email, id] of Object.entries(v2ByEmail)) usersByEmail[email] = id;

  return {
    report: {
      generatedAt,
      v1AuthUserCount: v1.users.length,
      v1ProfileCount: v1.profiles.rows.length,
      v2AuthUserCount: v2.users.length,
      v2ProfileCount: v2.profiles.rows.length,
      mappedUsers,
      unmappedV1Users,
      duplicateV1Emails: duplicateEmails(v1EmailEntries),
      duplicateV2Emails: duplicateEmails(v2EmailEntries),
      missingOptionalTables: [v1.profiles, v2.profiles].filter((result) => !result.exists).map((result) => result.table)
    },
    maps: {
      generatedAt,
      usersByEmail,
      v1UserIdToV2UserId,
      vineyardsById: {}
    }
  };
}

export function buildVineyardReport(v1: SourceSnapshot, maps: MapsFile, vineyardFilter?: string): VineyardMappingReport {
  const rows = filterByVineyard(v1.vineyards.rows, vineyardFilter);
  const mapped: VineyardMappingReport["mapped"] = [];
  const invalidUuidRecords: JsonRecord[] = [];
  const ownerMappingFailures: VineyardMappingReport["ownerMappingFailures"] = [];

  for (const row of rows) {
    const id = row.id;
    if (!isUuid(id)) {
      invalidUuidRecords.push(row);
      continue;
    }
    const ownerId = asNullableString(row.owner_id ?? row.user_id);
    const v2OwnerId = ownerId ? maps.v1UserIdToV2UserId[ownerId] ?? null : null;
    if (ownerId && !v2OwnerId) {
      ownerMappingFailures.push({ vineyardId: id, name: asNullableString(row.name), ownerId, reason: "owner_id has no V2 user mapping" });
    }
    maps.vineyardsById[id] = id;
    mapped.push({
      v1VineyardId: id,
      targetVineyardId: id,
      name: asNullableString(row.name),
      v1OwnerId: ownerId,
      v2OwnerId,
      ownerMapped: ownerId ? Boolean(v2OwnerId) : false
    });
  }

  return {
    generatedAt: new Date().toISOString(),
    sourceCount: rows.length,
    validUuidCount: mapped.length,
    invalidUuidRecords,
    mapped,
    ownerMappingFailures,
    missingOptionalTables: v1.vineyards.exists ? [] : [v1.vineyards.table]
  };
}

export function buildMemberReport(v1: SourceSnapshot, maps: MapsFile, vineyardFilter?: string): MemberMappingReport {
  const rows = filterByVineyard(v1.vineyardMembers.rows, vineyardFilter);
  const orphanMemberships: JsonRecord[] = [];
  const missingUsers: JsonRecord[] = [];
  const invalidRoles: JsonRecord[] = [];
  let mappedCount = 0;

  for (const row of rows) {
    if (!isUuid(row.vineyard_id) || !maps.vineyardsById[row.vineyard_id]) orphanMemberships.push(row);
    const userId = asNullableString(row.user_id);
    const mappedUserId = userId ? maps.v1UserIdToV2UserId[userId] : null;
    if (!mappedUserId && !normalizeEmail(row.email)) missingUsers.push(row);
    if (!row.role || !validRoles.has(row.role)) invalidRoles.push(row);
    if (isUuid(row.vineyard_id) && (mappedUserId || normalizeEmail(row.email)) && row.role && validRoles.has(row.role)) mappedCount += 1;
  }

  return {
    generatedAt: new Date().toISOString(),
    sourceCount: rows.length,
    mappedCount,
    orphanMemberships,
    missingUsers,
    invalidRoles
  };
}

export function buildInvitationReport(v1: SourceSnapshot, maps: MapsFile, vineyardFilter?: string): InvitationDryRunReport {
  const rows = filterByVineyard(v1.invitations.rows, vineyardFilter);
  const now = Date.now();
  const pendingCurrent: InvitationRecord[] = [];
  const staleOrExpired: InvitationRecord[] = [];
  const invalidRoles: InvitationRecord[] = [];
  const invalidVineyards: InvitationRecord[] = [];

  for (const row of rows) {
    const email = normalizeEmail(row.email);
    const status = typeof row.status === "string" ? row.status.toLowerCase() : "pending";
    const expiresAt = typeof row.expires_at === "string" ? Date.parse(row.expires_at) : Number.NaN;
    const isExpired = Number.isFinite(expiresAt) && expiresAt < now;
    if (!row.role || !validRoles.has(row.role)) invalidRoles.push(row);
    if (!isUuid(row.vineyard_id) || !maps.vineyardsById[row.vineyard_id]) invalidVineyards.push(row);
    if (status === "pending" && !isExpired && email) pendingCurrent.push({ ...row, email });
    else staleOrExpired.push(row);
  }

  return {
    generatedAt: new Date().toISOString(),
    sourceCount: rows.length,
    pendingCurrentCount: pendingCurrent.length,
    staleOrExpiredCount: staleOrExpired.length,
    pendingCurrent,
    staleOrExpired,
    invalidRoles,
    invalidVineyards,
    duplicatePendingEmails: duplicateEmails(pendingCurrent.map((row) => ({ id: asNullableString(row.id) ?? "unknown", email: normalizeEmail(row.email), source: "profile_email" as const })))
  };
}

export function buildDisclaimerReport(v1: SourceSnapshot, maps: MapsFile): DisclaimerDryRunReport {
  const missingUsers: DisclaimerAcceptanceRecord[] = [];
  const missingVersion: DisclaimerAcceptanceRecord[] = [];
  let mappedCount = 0;

  for (const row of v1.disclaimerAcceptances.rows) {
    const userId = asNullableString(row.user_id);
    if (!row.version) missingVersion.push(row);
    if (userId && maps.v1UserIdToV2UserId[userId]) mappedCount += 1;
    else missingUsers.push(row);
  }

  return {
    generatedAt: new Date().toISOString(),
    sourceCount: v1.disclaimerAcceptances.rows.length,
    mappedCount,
    missingUsers,
    missingVersion
  };
}

export function buildVineyardDataInventory(v1: SourceSnapshot, vineyardFilter?: string): VineyardDataInventoryReport {
  const rows = filterByVineyard(v1.vineyardData.rows, vineyardFilter);
  const totalKnownCounts = Object.fromEntries(vineyardDataKeys.map((key) => [key, 0]));
  const allUnknownKeys = new Set<string>();
  const entries: VineyardDataInventoryEntry[] = [];

  for (const row of rows) {
    const dataType = normalizeDataType(row.data_type);
    const mappedEntityName = dataType ? vineyardDataTypeToEntityName[dataType] ?? null : null;
    const payload = extractVineyardPayload(row);
    const vineyardId = asNullableString(row.vineyard_id ?? row.vineyardId);
    const knownCounts: Record<string, number> = Object.fromEntries(vineyardDataKeys.map((key) => [key, 0]));
    const keysFound = getPayloadKeys(payload.value);
    const unknownKeys = buildUnknownVineyardDataKeys(dataType, mappedEntityName, payload.value);
    const recordCount = mappedEntityName
      ? countPayloadRecords(payload.value, mappedEntityName)
      : dataType
        ? countPayloadRecords(payload.value, null)
        : countLegacyRecordVolume(payload.value);
    let estimatedRecordVolume = recordCount;

    if (mappedEntityName) {
      knownCounts[mappedEntityName] = recordCount;
      totalKnownCounts[mappedEntityName] = (totalKnownCounts[mappedEntityName] ?? 0) + recordCount;
    } else if (!dataType) {
      for (const key of vineyardDataKeys) {
        const count = countPayloadRecords(getValueAsRecord(payload.value)?.[key], key);
        knownCounts[key] = count;
        totalKnownCounts[key] = (totalKnownCounts[key] ?? 0) + count;
      }
      estimatedRecordVolume = Object.values(knownCounts).reduce((sum, count) => sum + count, 0);
    }

    for (const key of unknownKeys) allUnknownKeys.add(key);
    const invalidIds = collectInvalidIds(payload.value);
    const storageReferences = collectStorageReferences(payload.value);
    const likelyTransformBlockers = buildBlockers({ vineyardId, mappedEntityName, unknownKeys, invalidIds, recordCount, parseError: payload.parseError });

    entries.push({
      vineyardId,
      rowId: asNullableString(row.id),
      dataType,
      mappedEntityName,
      payloadKind: payload.kind,
      recordCount,
      keysFound,
      knownCounts,
      unknownKeys,
      estimatedRecordVolume,
      missingVineyardId: !isUuid(vineyardId),
      invalidIds,
      storageReferences,
      likelyTransformBlockers
    });
  }

  return {
    generatedAt: new Date().toISOString(),
    sourceCount: rows.length,
    keysInspected: vineyardDataKeys,
    totalKnownCounts,
    entries,
    recordsWithMissingVineyardId: entries.filter((entry) => entry.missingVineyardId).length,
    rowsWithInvalidIds: entries.filter((entry) => entry.invalidIds.length > 0).length,
    unknownKeys: Array.from(allUnknownKeys).sort()
  };
}

export function buildVineyardDataTransformReport(v1: SourceSnapshot, v2: TargetSnapshot, maps: MapsFile, vineyardFilter?: string): VineyardDataTransformReport {
  const sourceRows = filterByVineyard(v1.vineyardData?.rows ?? [], vineyardFilter);
  const rows: VineyardDataTransformReport["rows"] = [];
  const skippedRows: VineyardDataTransformSkippedRow[] = [];
  const normalizedTargetBuckets = normalizeTargetTableBuckets(v2.vineyardDataTargetTables);
  const existingByTable = normalizedTargetBuckets.tables;
  const warnings = [...normalizedTargetBuckets.warnings];

  for (const sourceRow of sourceRows) {
    const dataType = normalizeDataType(sourceRow.data_type);
    const mappedEntityName = dataType ? vineyardDataTypeToEntityName[dataType] ?? null : null;
    const payload = extractVineyardPayload(sourceRow);
    const vineyardId = asNullableString(sourceRow.vineyard_id ?? sourceRow.vineyardId);
    const baseSkip = {
      sourceRowId: asNullableString(sourceRow.id),
      vineyardId,
      dataType,
      mappedEntityName,
      payloadKind: payload.kind
    };

    if (!isUuid(vineyardId)) {
      skippedRows.push({ ...baseSkip, reason: "missing or invalid vineyard_id", fallbacks: [] });
      continue;
    }
    const targetVineyardId = maps.vineyardsById[vineyardId] ?? vineyardId;
    const fallbackPrefix = maps.vineyardsById[vineyardId] ? [] : ["vineyard_id reused because no alternate V2 vineyard mapping exists"];

    if (!dataType || !mappedEntityName) {
      skippedRows.push({ ...baseSkip, reason: dataType ? `unknown data_type ${dataType}` : "missing data_type", fallbacks: fallbackPrefix });
      continue;
    }
    const config = vineyardDataTransformConfigs[mappedEntityName];
    if (!config) {
      skippedRows.push({ ...baseSkip, reason: `no V2 target table mapping for ${mappedEntityName}`, fallbacks: fallbackPrefix });
      continue;
    }
    if (payload.parseError) {
      skippedRows.push({ ...baseSkip, reason: `payload JSON parse failed: ${payload.parseError}`, fallbacks: fallbackPrefix });
      continue;
    }

    if (config.mode === "buttonConfig") {
      const proposed = transformButtonConfigRow(sourceRow, payload.value, mappedEntityName, targetVineyardId, config, fallbackPrefix);
      if (proposed) rows.push(proposed);
      else skippedRows.push({ ...baseSkip, reason: "no button config payload records found", fallbacks: fallbackPrefix });
      continue;
    }

    const extracted = extractPayloadRecordObjects(payload.value, mappedEntityName);
    if (extracted.records.length === 0) {
      skippedRows.push({ ...baseSkip, reason: "no object records found in payload", fallbacks: [...fallbackPrefix, ...extracted.fallbacks] });
      continue;
    }
    extracted.records.forEach((record, index) => {
      rows.push(transformRecordRow(sourceRow, record, mappedEntityName, targetVineyardId, config, index, maps, [...fallbackPrefix, ...extracted.fallbacks]));
    });
  }

  const proposedRowsGroupedByTable = groupProposedRowsByTable(rows);
  const proposedRowsByTable = countRowsByTable(proposedRowsGroupedByTable);
  const duplicateProposedRowIds = findProposedRowIdDuplicates(rows);
  const duplicateProposedNaturalKeys = findProposedNaturalKeyDuplicates(rows);
  const existingNaturalKeysByTable = buildExistingNaturalKeysByTable(existingByTable);
  const existingV2RowIdConflicts = findExistingRowIdConflicts(rows, existingByTable);
  const existingV2NaturalKeyConflicts = findExistingNaturalKeyConflicts(rows, existingByTable, existingNaturalKeysByTable);
  const existingV2TablesRead = phase16cDestinationTables.map((table) => {
    const result = getTableReadResult(table, existingByTable);
    return {
      table,
      exists: result.exists,
      rowCount: getRows(table, existingByTable).length,
      error: result.error
    };
  });

  return {
    generatedAt: new Date().toISOString(),
    sourceCount: sourceRows.length,
    proposedRowCount: rows.length,
    proposedRowsByTable,
    fallbackCount: rows.reduce((sum, row) => sum + row.fallbacks.length, 0) + skippedRows.reduce((sum, row) => sum + row.fallbacks.length, 0),
    skippedRows,
    rows,
    duplicateProposedRowIds,
    duplicateProposedNaturalKeys,
    existingV2RowIdConflicts,
    existingV2NaturalKeyConflicts,
    existingV2TablesRead,
    warnings
  };
}

export function buildPhase16CSummary(report: VineyardDataTransformReport): Phase16CReportSummary {
  return {
    proposedRowsByTable: report.proposedRowsByTable,
    skippedRowCount: report.skippedRows.length,
    fallbackCreatedByCount: countFallbacksContaining(report, "created_by"),
    fallbackCount: report.fallbackCount,
    duplicateProposedRowIds: report.duplicateProposedRowIds,
    duplicateProposedNaturalKeys: report.duplicateProposedNaturalKeys,
    existingV2RowIdConflicts: report.existingV2RowIdConflicts,
    existingV2NaturalKeyConflicts: report.existingV2NaturalKeyConflicts,
    warnings: report.warnings
  };
}

type TransformMode = "records" | "buttonConfig";

type VineyardDataTransformConfig = {
  targetTable: string;
  mode: TransformMode;
  configType?: string;
  columns: Set<string>;
  naturalKeyGroups: string[][];
  columnMappings?: Record<string, string>;
  payloadColumn?: string;
};

const auditColumns = ["created_by", "updated_by", "created_at", "updated_at", "deleted_at", "client_updated_at", "sync_version"];

const vineyardDataTransformConfigs: Record<string, VineyardDataTransformConfig> = {
  pins: config("pins", ["id", "vineyard_id", "paddock_id", "trip_id", "mode", "category", "priority", "status", "button_name", "button_color", "title", "notes", "latitude", "longitude", "heading", "row_number", "side", "growth_stage_code", "is_completed", "completed_by", "completed_at", "photo_path", ...auditColumns], [["vineyard_id", "latitude", "longitude", "button_name", "created_at"], ["vineyard_id", "title", "created_at"]]),
  paddocks: config("paddocks", ["id", "vineyard_id", "name", "row_direction", "row_width", "row_offset", "vine_spacing", "vine_count_override", "row_length_override", "flow_per_emitter", "emitter_spacing", "budburst_date", "flowering_date", "veraison_date", "harvest_date", "planting_year", "calculation_mode_override", "reset_mode_override", "polygon_points", "rows", "variety_allocations", ...auditColumns], [["vineyard_id", "name"]]),
  trips: config("trips", ["id", "vineyard_id", "paddock_id", "paddock_ids", "paddock_name", "tracking_pattern", "start_time", "end_time", "is_active", "is_paused", "total_distance", "current_path_distance", "current_row_number", "next_row_number", "sequence_index", "row_sequence", "path_points", "completed_paths", "skipped_paths", "pin_ids", "tank_sessions", "active_tank_number", "total_tanks", "pause_timestamps", "resume_timestamps", "is_filling_tank", "filling_tank_number", "person_name", ...auditColumns], [["vineyard_id", "start_time", "person_name"], ["vineyard_id", "start_time", "tracking_pattern"]]),
  sprayRecords: config("spray_records", ["id", "vineyard_id", "trip_id", "date", "start_time", "end_time", "temperature", "wind_speed", "wind_direction", "humidity", "spray_reference", "notes", "number_of_fans_jets", "average_speed", "equipment_type", "tractor", "tractor_gear", "is_template", "operation_type", "tanks", ...auditColumns], [["vineyard_id", "date", "spray_reference"], ["vineyard_id", "start_time", "equipment_type"]]),
  savedChemicals: config("saved_chemicals", ["id", "vineyard_id", "name", "rate_per_ha", "unit", "chemical_group", "use", "manufacturer", "restrictions", "notes", "crop", "problem", "active_ingredient", "rates", "purchase", "label_url", "mode_of_action", ...auditColumns], [["vineyard_id", "name", "active_ingredient"], ["vineyard_id", "name", "manufacturer"]]),
  savedSprayPresets: config("saved_spray_presets", ["id", "vineyard_id", "name", "water_volume", "spray_rate_per_ha", "concentration_factor", ...auditColumns], [["vineyard_id", "name"]]),
  sprayEquipment: config("spray_equipment", ["id", "vineyard_id", "name", "tank_capacity_litres", ...auditColumns], [["vineyard_id", "name"]]),
  tractors: config("tractors", ["id", "vineyard_id", "name", "brand", "model", "model_year", "fuel_usage_l_per_hour", ...auditColumns], [["vineyard_id", "name"], ["vineyard_id", "brand", "model"]]),
  fuelPurchases: config("fuel_purchases", ["id", "vineyard_id", "volume_litres", "total_cost", "date", ...auditColumns], [["vineyard_id", "date", "volume_litres", "total_cost"]]),
  operatorCategories: config("operator_categories", ["id", "vineyard_id", "name", "cost_per_hour", ...auditColumns], [["vineyard_id", "name"]]),
  repairButtons: buttonConfig("repair_buttons"),
  growthButtons: buttonConfig("growth_buttons"),
  buttonTemplates: buttonConfig("button_templates"),
  yieldSessions: config("yield_estimation_sessions", ["id", "vineyard_id", "payload", "is_completed", "completed_at", "session_created_at", ...auditColumns], [["vineyard_id", "session_created_at"]], { payloadColumn: "payload" }),
  damageRecords: config("damage_records", ["id", "vineyard_id", "paddock_id", "date", "damage_type", "damage_percent", "polygon_points", "notes", ...auditColumns], [["vineyard_id", "paddock_id", "date", "damage_type"]]),
  historicalYieldRecords: config("historical_yield_records", ["id", "vineyard_id", "season", "year", "archived_at", "total_yield_tonnes", "total_area_hectares", "notes", "block_results", ...auditColumns], [["vineyard_id", "year", "season"]]),
  maintenanceLogs: config("maintenance_logs", ["id", "vineyard_id", "item_name", "hours", "work_completed", "parts_used", "parts_cost", "labour_cost", "date", "photo_path", "is_archived", "archived_at", "archived_by", "is_finalized", "finalized_at", "finalized_by", ...auditColumns], [["vineyard_id", "item_name", "date", "work_completed"]]),
  workTasks: config("work_tasks", ["id", "vineyard_id", "paddock_id", "paddock_name", "date", "task_type", "duration_hours", "resources", "notes", "is_archived", "archived_at", "archived_by", "is_finalized", "finalized_at", "finalized_by", ...auditColumns], [["vineyard_id", "date", "task_type", "paddock_name"]])
};

function config(targetTable: string, columns: string[], naturalKeyGroups: string[][], options: { payloadColumn?: string } = {}): VineyardDataTransformConfig {
  return { targetTable, mode: "records", columns: new Set(columns), naturalKeyGroups, payloadColumn: options.payloadColumn };
}

function buttonConfig(configType: string): VineyardDataTransformConfig {
  return {
    targetTable: "vineyard_button_configs",
    mode: "buttonConfig",
    configType,
    columns: new Set(["id", "vineyard_id", "config_type", "config_data", ...auditColumns]),
    naturalKeyGroups: [["vineyard_id", "config_type"]]
  };
}

function transformButtonConfigRow(sourceRow: JsonRecord, payload: unknown, mappedEntityName: string, targetVineyardId: string, config: VineyardDataTransformConfig, fallbackPrefix: string[]): VineyardDataTransformReport["rows"][number] | null {
  const extracted = extractPayloadJsonList(payload, mappedEntityName);
  if (extracted.values.length === 0) return null;
  const sourceRowId = asNullableString(sourceRow.id);
  const rowId = deterministicUuid([targetVineyardId, config.configType ?? mappedEntityName]);
  const row: JsonRecord = {
    id: rowId,
    vineyard_id: targetVineyardId,
    config_type: config.configType ?? toSnakeCase(mappedEntityName),
    config_data: extracted.values,
    client_updated_at: jsonString(asNullableString(sourceRow.updated_at) ?? new Date(0).toISOString())
  };
  const naturalKey = buildNaturalKey(row, config.naturalKeyGroups);
  return {
    sourceRowId,
    sourceDataType: normalizeDataType(sourceRow.data_type),
    sourceEntityName: mappedEntityName,
    sourceRecordIndex: 0,
    targetTable: config.targetTable,
    proposedId: rowId,
    naturalKey,
    row,
    sourceRecord: asJsonValue(payload),
    fallbacks: [...fallbackPrefix, "deterministic id generated for config row", ...extracted.fallbacks],
    blockers: collectInvalidIds(payload)
  };
}

function transformRecordRow(sourceRow: JsonRecord, record: JsonRecord, mappedEntityName: string, targetVineyardId: string, config: VineyardDataTransformConfig, sourceRecordIndex: number, maps: MapsFile, fallbackPrefix: string[]): VineyardDataTransformReport["rows"][number] {
  const fallbacks = [...fallbackPrefix];
  const blockers = collectInvalidIds(record);
  const sourceRowId = asNullableString(sourceRow.id);
  const row: JsonRecord = {};
  const omittedKeys: string[] = [];

  if (config.payloadColumn) row[config.payloadColumn] = asJsonValue(record);
  for (const [key, value] of Object.entries(record)) {
    const targetKey = config.columnMappings?.[key] ?? toSnakeCase(key);
    if (!config.columns.has(targetKey)) {
      omittedKeys.push(key);
      continue;
    }
    row[targetKey] = asJsonValue(value);
  }

  const originalId = asNullableString(record.id);
  const proposedId = isUuid(originalId) ? originalId : deterministicUuid([targetVineyardId, mappedEntityName, sourceRowId ?? "source", String(sourceRecordIndex), stableJson(record)]);
  if (!isUuid(originalId)) fallbacks.push(originalId ? `deterministic id generated because payload id is not a UUID: ${originalId}` : "deterministic id generated because payload id is missing");

  row.id = proposedId;
  row.vineyard_id = targetVineyardId;
  remapUserColumn(row, record, "created_by", maps, fallbacks);
  remapUserColumn(row, record, "updated_by", maps, fallbacks);
  const clientUpdatedAt = firstString(record.client_updated_at, record.clientUpdatedAt, record.updated_at, record.updatedAt, sourceRow.updated_at, record.created_at, record.createdAt);
  if (clientUpdatedAt) row.client_updated_at = jsonString(clientUpdatedAt);
  if (mappedEntityName === "yieldSessions") {
    row.payload = asJsonValue(record);
    row.is_completed = asJsonValue(record.is_completed ?? record.isCompleted ?? false);
    const sessionCreatedAt = firstString(record.session_created_at, record.sessionCreatedAt, record.created_at, record.createdAt, record.date);
    if (sessionCreatedAt) row.session_created_at = jsonString(sessionCreatedAt);
  }
  if (omittedKeys.length > 0) fallbacks.push(`omitted source keys with no V2 column mapping: ${omittedKeys.sort().join(",")}`);
  const naturalKey = buildNaturalKey(row, config.naturalKeyGroups);
  if (!naturalKey) fallbacks.push("natural key could not be derived from proposed row");

  return {
    sourceRowId,
    sourceDataType: normalizeDataType(sourceRow.data_type),
    sourceEntityName: mappedEntityName,
    sourceRecordIndex,
    targetTable: config.targetTable,
    proposedId,
    naturalKey,
    row,
    sourceRecord: asJsonValue(record),
    fallbacks,
    blockers
  };
}

function remapUserColumn(row: JsonRecord, record: JsonRecord, targetKey: "created_by" | "updated_by", maps: MapsFile, fallbacks: string[]): void {
  const sourceValue = firstString(record[targetKey], record[toCamelCase(targetKey)], targetKey === "created_by" ? record.user_id : null, targetKey === "created_by" ? record.userId : null);
  if (!sourceValue) return;
  const mapped = maps.v1UserIdToV2UserId[sourceValue];
  if (mapped) row[targetKey] = jsonString(mapped);
  else if (isUuid(sourceValue)) {
    row[targetKey] = null;
    fallbacks.push(`${targetKey} cleared because V1 user has no V2 mapping: ${sourceValue}`);
  } else {
    row[targetKey] = null;
    fallbacks.push(`${targetKey} cleared because source value is not a UUID: ${sourceValue}`);
  }
}

function extractPayloadRecordObjects(value: unknown, mappedEntityName: string): { records: JsonRecord[]; fallbacks: string[] } {
  const fallbacks: string[] = [];
  if (Array.isArray(value)) return { records: value.filter(isJsonRecord), fallbacks: value.some((item) => !isJsonRecord(item)) ? ["non-object payload array items skipped"] : [] };
  const record = getValueAsRecord(value);
  if (!record) return { records: [], fallbacks };
  const list = findRecordList(record, mappedEntityName);
  if (list) return { records: list.filter(isJsonRecord), fallbacks: list.some((item) => !isJsonRecord(item)) ? ["non-object nested list items skipped"] : [] };
  if (hasEntityRecordShape(record)) return { records: [record], fallbacks };
  const objectValues = Object.values(record).filter(isJsonRecord);
  if (objectValues.length > 0 && objectValues.length === Object.keys(record).length) return { records: objectValues, fallbacks: ["object map expanded into proposed rows"] };
  return { records: [record], fallbacks: ["single object payload treated as one proposed row"] };
}

function extractPayloadJsonList(value: unknown, mappedEntityName: string): { values: JsonValue[]; fallbacks: string[] } {
  if (Array.isArray(value)) return { values: value.map(asJsonValue), fallbacks: [] };
  const record = getValueAsRecord(value);
  if (!record) return { values: [], fallbacks: [] };
  const list = findRecordList(record, mappedEntityName);
  if (list) return { values: list.map(asJsonValue), fallbacks: ["nested list extracted into config_data"] };
  return { values: [asJsonValue(record)], fallbacks: ["single object payload wrapped in config_data array"] };
}

function groupProposedRowsByTable(rows: VineyardDataTransformReport["rows"]): Record<string, VineyardDataTransformReport["rows"]> {
  const grouped = emptyProposedRowBuckets();
  for (const row of rows) {
    if (!grouped[row.targetTable]) grouped[row.targetTable] = [];
    grouped[row.targetTable]?.push(row);
  }
  return grouped;
}

function countRowsByTable(proposedRowsByTable: Record<string, VineyardDataTransformReport["rows"]> | undefined): Record<string, number> {
  const counts = emptyTableCounts();
  for (const table of phase16cDestinationTables) counts[table] = getProposedRows(table, proposedRowsByTable).length;
  for (const [table, rows] of Object.entries(proposedRowsByTable ?? {})) counts[table] = Array.isArray(rows) ? rows.length : 0;
  return counts;
}

function emptyTableCounts(): Record<string, number> {
  return Object.fromEntries(phase16cDestinationTables.map((table) => [table, 0]));
}

function emptyProposedRowBuckets(): Record<string, VineyardDataTransformReport["rows"]> {
  return Object.fromEntries(phase16cDestinationTables.map((table) => [table, []]));
}

function countFallbacksContaining(report: VineyardDataTransformReport, needle: string): number {
  return report.rows.reduce((count, row) => count + row.fallbacks.filter((fallback) => fallback.includes(needle)).length, 0) +
    report.skippedRows.reduce((count, row) => count + row.fallbacks.filter((fallback) => fallback.includes(needle)).length, 0);
}

function findProposedRowIdDuplicates(rows: VineyardDataTransformReport["rows"]): VineyardDataConflictReport[] {
  const grouped = groupRows(rows.filter((row) => row.proposedId), (row) => `${row.targetTable}|${row.proposedId ?? ""}`);
  return Array.from(grouped.values()).filter((group) => group.length > 1).map((group) => ({
    targetTable: group[0]?.targetTable ?? "unknown",
    conflictType: "proposed_row_id_duplicate",
    severity: "conflict",
    proposedIds: group.map((row) => row.proposedId).filter(isString),
    existingIds: [],
    sourceRowIds: group.map((row) => row.sourceRowId).filter(isString),
    naturalKey: group[0]?.naturalKey ?? null,
    detail: "multiple proposed rows would use the same V2 row id"
  }));
}

function findProposedNaturalKeyDuplicates(rows: VineyardDataTransformReport["rows"]): VineyardDataConflictReport[] {
  const grouped = groupRows(rows.filter((row) => row.naturalKey), (row) => `${row.targetTable}|${row.naturalKey ?? ""}`);
  return Array.from(grouped.values()).filter((group) => group.length > 1).map((group) => ({
    targetTable: group[0]?.targetTable ?? "unknown",
    conflictType: "proposed_natural_key_duplicate",
    severity: "duplicate",
    proposedIds: group.map((row) => row.proposedId).filter(isString),
    existingIds: [],
    sourceRowIds: group.map((row) => row.sourceRowId).filter(isString),
    naturalKey: group[0]?.naturalKey ?? null,
    detail: "multiple proposed rows share the same natural key"
  }));
}

function findExistingRowIdConflicts(rows: VineyardDataTransformReport["rows"], existingByTable: Record<string, TableReadResult<JsonRecord>> | undefined): VineyardDataConflictReport[] {
  const conflicts: VineyardDataConflictReport[] = [];
  for (const row of rows) {
    if (!row.proposedId) continue;
    const existingRows = getRows(row.targetTable, existingByTable);
    const existing = existingRows.find((candidate) => candidate.id === row.proposedId);
    if (!existing) continue;
    const existingNaturalKey = naturalKeyForExistingRow(row.targetTable, existing);
    conflicts.push({
      targetTable: row.targetTable,
      conflictType: "existing_row_id",
      severity: existingNaturalKey && existingNaturalKey === row.naturalKey ? "duplicate" : "conflict",
      proposedIds: [row.proposedId],
      existingIds: [row.proposedId],
      sourceRowIds: row.sourceRowId ? [row.sourceRowId] : [],
      naturalKey: row.naturalKey,
      detail: existingNaturalKey && existingNaturalKey === row.naturalKey ? "proposed row id already exists in V2 with the same natural key" : "proposed row id already exists in V2 with different or unknown natural key"
    });
  }
  return conflicts;
}

function findExistingNaturalKeyConflicts(rows: VineyardDataTransformReport["rows"], existingByTable: Record<string, TableReadResult<JsonRecord>> | undefined, existingNaturalKeysByTable: Record<string, Set<string>> | undefined): VineyardDataConflictReport[] {
  const conflicts: VineyardDataConflictReport[] = [];
  for (const row of rows) {
    if (!row.naturalKey) continue;
    const naturalKeys = getNaturalKeys(row.targetTable, existingNaturalKeysByTable);
    if (!naturalKeys.has(row.naturalKey)) continue;
    const existingRows = getRows(row.targetTable, existingByTable);
    const matches = existingRows.filter((existing) => naturalKeyForExistingRow(row.targetTable, existing) === row.naturalKey);
    const differentIdMatches = matches.filter((existing) => asNullableString(existing.id) !== row.proposedId);
    if (differentIdMatches.length === 0) continue;
    conflicts.push({
      targetTable: row.targetTable,
      conflictType: "existing_natural_key",
      severity: "duplicate",
      proposedIds: row.proposedId ? [row.proposedId] : [],
      existingIds: differentIdMatches.map((existing) => asNullableString(existing.id)).filter(isString),
      sourceRowIds: row.sourceRowId ? [row.sourceRowId] : [],
      naturalKey: row.naturalKey,
      detail: "V2 already has row(s) with the same natural key but different id"
    });
  }
  return conflicts;
}

function normalizeTargetTableBuckets(input: TargetSnapshot["vineyardDataTargetTables"] | undefined): { tables: Record<string, TableReadResult<JsonRecord>>; warnings: string[] } {
  const tables = emptyTargetTableBuckets();
  const warnings: string[] = [];

  for (const table of phase16cDestinationTables) {
    const result = input?.[table];
    if (!result) {
      warnings.push(`V2 target table ${table} was missing from snapshot; treating as empty`);
      continue;
    }
    if (!Array.isArray(result.rows)) {
      tables[table] = { ...result, table, rows: [], error: result.error ?? "read returned no rows array; treating as empty" };
      warnings.push(`V2 target table ${table} read returned no rows array; treating as empty`);
      continue;
    }
    if (!result.exists || result.error) {
      warnings.push(`V2 target table ${table} read failed or was unavailable; treating rows as empty${result.error ? ` (${result.error})` : ""}`);
      tables[table] = { ...result, table, rows: [] };
      continue;
    }
    tables[table] = { ...result, table, rows: result.rows };
  }

  return { tables, warnings };
}

function emptyTargetTableBuckets(): Record<string, TableReadResult<JsonRecord>> {
  return Object.fromEntries(phase16cDestinationTables.map((table) => [table, emptyTableReadResult(table, "V2 target snapshot did not include this table; treating as empty")]));
}

function emptyNaturalKeyBuckets(): Record<string, Set<string>> {
  return Object.fromEntries(phase16cDestinationTables.map((table) => [table, new Set<string>()]));
}

function buildExistingNaturalKeysByTable(existingByTable: Record<string, TableReadResult<JsonRecord>> | undefined): Record<string, Set<string>> {
  const naturalKeysByTable = emptyNaturalKeyBuckets();
  for (const table of phase16cDestinationTables) {
    const naturalKeys = getNaturalKeys(table, naturalKeysByTable);
    for (const row of getRows(table, existingByTable)) {
      const naturalKey = naturalKeyForExistingRow(table, row);
      if (naturalKey) naturalKeys.add(naturalKey);
    }
  }
  return naturalKeysByTable;
}

function getRows(table: string, existingByTable?: Record<string, TableReadResult<JsonRecord>>): JsonRecord[] {
  const rows = existingByTable?.[table]?.rows;
  return Array.isArray(rows) ? rows : [];
}

function getNaturalKeys(table: string, existingNaturalKeysByTable?: Record<string, Set<string>>): Set<string> {
  return existingNaturalKeysByTable?.[table] ?? new Set<string>();
}

function getProposedRows(table: string, proposedRowsByTable?: Record<string, VineyardDataTransformReport["rows"]>): VineyardDataTransformReport["rows"] {
  const rows = proposedRowsByTable?.[table];
  return Array.isArray(rows) ? rows : [];
}

function getTableReadResult(table: string, existingByTable?: Record<string, TableReadResult<JsonRecord>>): TableReadResult<JsonRecord> {
  return existingByTable?.[table] ?? emptyTableReadResult(table, "V2 target snapshot did not include this table; treating as empty");
}

function emptyTableReadResult(table: string, error: string): TableReadResult<JsonRecord> {
  return { table, rows: [], exists: false, error };
}

function naturalKeyForExistingRow(targetTable: string, row: JsonRecord): string | null {
  const config = Object.values(vineyardDataTransformConfigs).find((candidate) => candidate.targetTable === targetTable);
  if (!config) return null;
  return buildNaturalKey(row, config.naturalKeyGroups);
}

function buildNaturalKey(row: JsonRecord, groups: string[][]): string | null {
  for (const group of groups) {
    const values = group.map((key) => normalizeNaturalKeyValue(row[key]));
    if (values.every((value) => value !== null)) return group.map((key, index) => `${key}=${values[index] ?? ""}`).join("|");
  }
  return null;
}

function normalizeNaturalKeyValue(value: JsonValue | undefined): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") {
    const trimmed = value.trim().toLowerCase();
    return trimmed.length > 0 ? trimmed : null;
  }
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return stableJson(value).toLowerCase();
}

function groupRows<T>(rows: T[], keyForRow: (row: T) => string): Map<string, T[]> {
  const grouped = new Map<string, T[]>();
  for (const row of rows) grouped.set(keyForRow(row), [...(grouped.get(keyForRow(row)) ?? []), row]);
  return grouped;
}

function deterministicUuid(parts: string[]): string {
  const hash = createHash("sha256").update(parts.join("|")).digest("hex");
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-4${hash.slice(13, 16)}-a${hash.slice(17, 20)}-${hash.slice(20, 32)}`;
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function asJsonValue(value: unknown): JsonValue {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) return value.map(asJsonValue);
  if (value && typeof value === "object") {
    const result: Record<string, JsonValue> = {};
    for (const [key, child] of Object.entries(value)) {
      if (child === undefined) continue;
      result[key] = asJsonValue(child);
    }
    return result;
  }
  return null;
}

function jsonString(value: string): JsonValue {
  return value;
}

function isJsonRecord(value: unknown): value is JsonRecord {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function isString(value: unknown): value is string {
  return typeof value === "string";
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    const stringValue = asNullableString(value);
    if (stringValue) return stringValue;
  }
  return null;
}

function toCamelCase(value: string): string {
  return value.replace(/_([a-z])/g, (_, letter: string) => letter.toUpperCase());
}

function collectUserEmailEntries(users: AuthUserRecord[], profiles: ProfileRecord[]): Array<{ id: string; email: string | null; source: "auth_email" | "profile_email" }> {
  const entries = new Map<string, { id: string; email: string | null; source: "auth_email" | "profile_email" }>();
  for (const user of users) entries.set(user.id, { id: user.id, email: normalizeEmail(user.email), source: "auth_email" });
  for (const profile of profiles) {
    const id = asNullableString(profile.id ?? profile.user_id);
    if (!id || entries.has(id)) continue;
    entries.set(id, { id, email: normalizeEmail(profile.email), source: "profile_email" });
  }
  return Array.from(entries.values());
}

function firstIdByEmail(entries: Array<{ id: string; email: string | null }>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const entry of entries) {
    if (entry.email && !result[entry.email]) result[entry.email] = entry.id;
  }
  return result;
}

function duplicateEmails(entries: Array<{ id: string; email: string | null }>): DuplicateEmailReport[] {
  const grouped = new Map<string, string[]>();
  for (const entry of entries) {
    if (!entry.email) continue;
    grouped.set(entry.email, [...(grouped.get(entry.email) ?? []), entry.id]);
  }
  return Array.from(grouped.entries()).filter(([, ids]) => ids.length > 1).map(([email, ids]) => ({ email, ids }));
}

function filterByVineyard<T extends JsonRecord & { vineyard_id?: string | null; vineyardId?: string | null }>(rows: T[], vineyardId?: string): T[] {
  if (!vineyardId) return rows;
  return rows.filter((row) => row.vineyard_id === vineyardId || row.vineyardId === vineyardId || row.id === vineyardId);
}

function asNullableString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function extractVineyardPayload(row: JsonRecord): { value: unknown; kind: VineyardDataPayloadKind; parseError?: string } {
  const candidate = row.data !== undefined ? row.data : row.payload ?? row.json ?? row.value;
  if (candidate === undefined) return { value: null, kind: "null" };
  if (typeof candidate !== "string") return { value: candidate, kind: payloadKind(candidate, false) };

  const trimmed = candidate.trim();
  if ((trimmed.startsWith("{") && trimmed.endsWith("}")) || (trimmed.startsWith("[") && trimmed.endsWith("]"))) {
    try {
      const parsed: unknown = JSON.parse(trimmed);
      return { value: parsed, kind: payloadKind(parsed, true) };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return { value: candidate, kind: "primitive", parseError: message };
    }
  }

  return { value: candidate, kind: "primitive" };
}

function payloadKind(value: unknown, parsedFromString: boolean): VineyardDataPayloadKind {
  if (value === null || value === undefined) return "null";
  if (Array.isArray(value)) return parsedFromString ? "json_string_array" : "array";
  if (typeof value === "object") return parsedFromString ? "json_string_object" : "object";
  return parsedFromString ? "json_string_primitive" : "primitive";
}

function normalizeDataType(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  if (vineyardDataTypeToEntityName[trimmed]) return trimmed;
  const normalized = trimmed
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[\s-]+/g, "_")
    .toLowerCase();
  return normalized.length > 0 ? normalized : null;
}

function getPayloadKeys(value: unknown): string[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  return Object.keys(value as JsonRecord);
}

function buildUnknownVineyardDataKeys(dataType: string | null, mappedEntityName: string | null, payload: unknown): string[] {
  if (dataType) return mappedEntityName ? [] : [dataType];
  const record = getValueAsRecord(payload);
  if (!record) return [];
  return Object.keys(record).filter((key) => !vineyardDataKeys.includes(key));
}

function countLegacyRecordVolume(value: unknown): number {
  const record = getValueAsRecord(value);
  if (!record) return countPayloadRecords(value, null);
  return Object.entries(record).reduce((sum, [key, child]) => {
    const mappedKey = vineyardDataKeys.includes(key) ? key : null;
    return sum + countPayloadRecords(child, mappedKey);
  }, 0);
}

function countPayloadRecords(value: unknown, mappedEntityName: string | null): number {
  if (value === null || value === undefined) return 0;
  if (Array.isArray(value)) return value.length;
  if (typeof value !== "object") return 1;
  if (mappedEntityName === "settings") return 1;

  const record = value as JsonRecord;
  const list = findRecordList(record, mappedEntityName);
  if (list) return list.length;
  return countRecordObject(record, mappedEntityName);
}

function findRecordList(record: JsonRecord, mappedEntityName: string | null): unknown[] | null {
  const keys = preferredListKeys(mappedEntityName);
  for (const key of keys) {
    const value = record[key];
    if (Array.isArray(value)) return value;
  }

  for (const value of Object.values(record)) {
    if (Array.isArray(value)) return value;
  }

  return null;
}

function preferredListKeys(mappedEntityName: string | null): string[] {
  const commonKeys = [
    "items",
    "records",
    "data",
    "values",
    "list",
    "buttons",
    "templates",
    "patterns",
    "chemicals",
    "equipment",
    "varieties",
    "sessions",
    "logs",
    "tasks",
    "purchases"
  ];
  const entityKeys: Record<string, string[]> = {
    repairButtons: ["repairButtons", "repair_buttons", "buttons", "repair_buttons_data"],
    growthButtons: ["growthButtons", "growth_buttons", "buttons", "growth_buttons_data"],
    buttonTemplates: ["buttonTemplates", "button_templates", "templates", "buttons"],
    savedCustomPatterns: ["savedCustomPatterns", "saved_custom_patterns", "custom_patterns", "patterns"],
    savedChemicals: ["savedChemicals", "saved_chemicals", "chemicals"],
    savedSprayPresets: ["savedSprayPresets", "saved_spray_presets", "presets"],
    savedEquipmentOptions: ["savedEquipmentOptions", "saved_equipment_options", "equipmentOptions", "equipment_options"],
    sprayEquipment: ["sprayEquipment", "spray_equipment", "equipment"],
    fuelPurchases: ["fuelPurchases", "fuel_purchases", "purchases"],
    operatorCategories: ["operatorCategories", "operator_categories", "categories"],
    yieldSessions: ["yieldSessions", "yield_sessions", "sessions"],
    damageRecords: ["damageRecords", "damage_records", "records"],
    historicalYieldRecords: ["historicalYieldRecords", "historical_yield_records", "records"],
    maintenanceLogs: ["maintenanceLogs", "maintenance_logs", "logs"],
    workTasks: ["workTasks", "work_tasks", "tasks"],
    grapeVarieties: ["grapeVarieties", "grape_varieties", "varieties"]
  };

  if (!mappedEntityName) return commonKeys;
  return Array.from(new Set([mappedEntityName, toSnakeCase(mappedEntityName), ...(entityKeys[mappedEntityName] ?? []), ...commonKeys]));
}

function countRecordObject(record: JsonRecord, mappedEntityName: string | null): number {
  const entries = Object.entries(record);
  if (entries.length === 0) return 0;
  if (mappedEntityName && hasEntityRecordShape(record)) return 1;
  const objectValueCount = entries.filter(([, value]) => value !== null && typeof value === "object" && !Array.isArray(value)).length;
  const idLikeKeyCount = entries.filter(([key]) => key.length >= 20 || isUuid(key)).length;
  if (objectValueCount === entries.length || idLikeKeyCount > 0) return entries.length;
  return 1;
}

function hasEntityRecordShape(record: JsonRecord): boolean {
  return typeof record.id === "string" || typeof record.created_at === "string" || typeof record.updated_at === "string" || typeof record.createdAt === "string" || typeof record.updatedAt === "string";
}

function toSnakeCase(value: string): string {
  return value.replace(/[A-Z]/g, (match) => `_${match.toLowerCase()}`);
}

function getValueAsRecord(value: unknown): JsonRecord | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as JsonRecord;
}

function collectInvalidIds(value: unknown, path = "root"): string[] {
  const invalid: string[] = [];
  if (Array.isArray(value)) {
    value.forEach((item, index) => invalid.push(...collectInvalidIds(item, `${path}[${index}]`)));
    return invalid;
  }
  if (!value || typeof value !== "object") return invalid;
  for (const [key, child] of Object.entries(value as JsonRecord)) {
    if ((key === "id" || key.endsWith("Id") || key.endsWith("_id")) && typeof child === "string" && child.length > 0 && !isUuid(child)) {
      invalid.push(`${path}.${key}=${child}`);
    }
    invalid.push(...collectInvalidIds(child, `${path}.${key}`));
  }
  return invalid;
}

function collectStorageReferences(value: unknown): string[] {
  const refs = new Set<string>();
  walk(value, (candidate) => {
    if (typeof candidate !== "string") return;
    const lower = candidate.toLowerCase();
    if (lower.includes("storage") || lower.includes(".jpg") || lower.includes(".jpeg") || lower.includes(".png") || lower.includes("el-stage") || lower.includes("growth")) refs.add(candidate);
  });
  return Array.from(refs).slice(0, 100);
}

function buildBlockers(input: { vineyardId: string | null; mappedEntityName: string | null; unknownKeys: string[]; invalidIds: string[]; recordCount: number; parseError?: string }): string[] {
  const blockers: string[] = [];
  if (!isUuid(input.vineyardId)) blockers.push("missing or invalid vineyard_id");
  if (input.parseError) blockers.push(`payload JSON parse failed: ${input.parseError}`);
  if (input.invalidIds.length > 0) blockers.push("invalid payload IDs detected");
  if (input.unknownKeys.length > 0) blockers.push("unknown data_type requires Phase 16C mapping decision");
  if (input.mappedEntityName === "settings" && input.recordCount > 0) blockers.push("settings blob requires explicit V2 ownership/default mapping decision");
  return blockers;
}

function walk(value: unknown, visit: (value: unknown) => void): void {
  visit(value);
  if (Array.isArray(value)) {
    for (const item of value) walk(item, visit);
  } else if (value && typeof value === "object") {
    for (const child of Object.values(value as JsonRecord)) walk(child, visit);
  }
}
