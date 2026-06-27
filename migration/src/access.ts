import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  AccessApplyResult,
  AccessMigrationAction,
  AccessMigrationPlan,
  AccessMigrationReport,
  AccessMigrationReportSummary,
  AccessMigrationSkippedUser,
  IdentityDryRunReport,
  JsonRecord,
  JsonValue,
  MapsFile,
  SourceSnapshot,
  TargetSnapshot
} from "./types.js";
import { isUuid, normalizeEmail, validRoles } from "./remap.js";

export function buildAccessMigrationPlan(input: {
  v1: SourceSnapshot;
  v2: TargetSnapshot;
  maps: MapsFile;
  identityReport: IdentityDryRunReport;
  vineyardId?: string;
  fallbackUserId?: string;
  mode?: "dry-run" | "apply-access-plan";
}): AccessMigrationPlan {
  const generatedAt = new Date().toISOString();
  const warnings: string[] = [];
  const risks: string[] = [];
  const skippedUsers: AccessMigrationSkippedUser[] = [];
  const existingVineyards = rowsById(getTargetRows(input.v2, "vineyards", warnings));
  const existingMemberships = getTargetRows(input.v2, "vineyard_members", warnings);
  const existingInvitations = getTargetRows(input.v2, "invitations", warnings);
  const existingDisclaimerAcceptances = getTargetRows(input.v2, "disclaimer_acceptances", warnings);
  const existingMembershipKeys = new Map(existingMemberships.map((row) => [membershipKey(asString(row.vineyard_id), asString(row.user_id)), row]).filter(([key]) => key !== null) as Array<[string, JsonRecord]>);
  const existingPendingInvitationKeys = new Map(existingInvitations.filter((row) => invitationStatus(row) === "pending").map((row) => [invitationKey(asString(row.vineyard_id), normalizeEmail(row.email)), row]).filter(([key]) => key !== null) as Array<[string, JsonRecord]>);
  const existingDisclaimerKeys = new Map(existingDisclaimerAcceptances.map((row) => [disclaimerKey(asString(row.user_id), asString(row.version)), row]).filter(([key]) => key !== null) as Array<[string, JsonRecord]>);
  const fallbackUserId = input.fallbackUserId ?? null;
  const fallbackProfileExists = fallbackUserId ? input.v2.profiles.rows.some((row) => asString(row.id ?? row.user_id) === fallbackUserId) : false;

  if (!input.v1.vineyards.exists) risks.push("V1 vineyards table was missing or inaccessible");
  if (!input.v1.vineyardMembers.exists) risks.push("V1 vineyard_members table was missing or inaccessible");
  if (!input.v1.disclaimerAcceptances.exists) risks.push("V1 disclaimer_acceptances table was missing or inaccessible");
  if (input.identityReport.duplicateV1Emails.length > 0) risks.push("Duplicate V1 emails require review before relying on email-based user mapping");
  if (input.identityReport.duplicateV2Emails.length > 0) risks.push("Duplicate V2 emails require review before relying on email-based user mapping");

  const vineyardsToUpsert: AccessMigrationAction[] = [];
  const membershipsToUpsert: AccessMigrationAction[] = [];
  const invitationsToCreate: AccessMigrationAction[] = [];
  const invitationUpdates: AccessMigrationAction[] = [];
  const disclaimerAcceptancesToUpsert: AccessMigrationAction[] = [];
  let vineyardsSkipped = 0;
  let membershipsSkipped = 0;
  let invitationsSkipped = 0;
  let disclaimerAcceptancesSkipped = 0;

  const sourceVineyards = filterVineyards(input.v1.vineyards.rows, input.vineyardId);
  const validVineyardIds = new Set<string>();
  const proposedVineyardIds = new Set<string>();
  for (const vineyard of sourceVineyards) {
    const vineyardId = asString(vineyard.id);
    if (!isUuid(vineyardId)) {
      vineyardsSkipped += 1;
      continue;
    }
    validVineyardIds.add(vineyardId);
    if (proposedVineyardIds.has(vineyardId)) {
      vineyardsSkipped += 1;
      continue;
    }
    proposedVineyardIds.add(vineyardId);
    input.maps.vineyardsById[vineyardId] = vineyardId;
    const existing = existingVineyards.get(vineyardId) ?? null;
    const ownerId = asString(vineyard.owner_id ?? vineyard.user_id);
    const mappedOwnerId = ownerId ? input.maps.v1UserIdToV2UserId[ownerId] ?? null : null;
    if (ownerId && !mappedOwnerId) {
      skippedUsers.push({ sourceTable: "vineyards", v1UserId: ownerId, email: normalizeEmail(vineyard.email), vineyardId, reason: "vineyard owner_id has no V2 user mapping; owner_id will not be changed" });
    }
    const insertRow = compactJsonRecord({
      id: vineyardId,
      name: nonEmptyString(vineyard.name) ?? "Untitled Vineyard",
      country: nullableString(vineyard.country),
      owner_id: mappedOwnerId,
      created_at: stringOrUndefined(vineyard.created_at),
      updated_at: stringOrUndefined(vineyard.updated_at),
      deleted_at: stringOrUndefined(vineyard.deleted_at)
    });
    const updateRow = compactJsonRecord({
      id: vineyardId,
      name: nonEmptyString(vineyard.name),
      country: stringOrUndefined(vineyard.country),
      owner_id: mappedOwnerId ?? undefined
    });
    const row = existing ? updateRow : insertRow;
    const changedFields = existing ? changedFieldsFor(existing, row, ["id"]) : Object.keys(row);
    if (existing && changedFields.length === 0) {
      vineyardsSkipped += 1;
      continue;
    }
    vineyardsToUpsert.push({
      table: "vineyards",
      action: existing ? "update" : "insert",
      key: vineyardId,
      sourceId: vineyardId,
      row,
      existingRow: existing,
      changedFields,
      warnings: ownerId && !mappedOwnerId ? ["owner_id not updated because V1 owner does not map to a V2 user"] : []
    });
  }

  const sourceMemberships = filterRowsByVineyard(input.v1.vineyardMembers.rows, input.vineyardId);
  const proposedMembershipKeys = new Set<string>();
  const proposedInvitationKeys = new Set<string>();
  for (const membership of sourceMemberships) {
    const vineyardId = asString(membership.vineyard_id);
    const v1UserId = asString(membership.user_id);
    const email = emailForV1User(input.v1, v1UserId) ?? normalizeEmail(membership.email);
    const role = normalizeRole(membership.role);
    if (!isUuid(vineyardId) || !validVineyardIds.has(vineyardId)) {
      membershipsSkipped += 1;
      skippedUsers.push({ sourceTable: "vineyard_members", v1UserId, email, vineyardId, reason: "membership references an invalid or unmapped vineyard" });
      continue;
    }
    if (!role) {
      membershipsSkipped += 1;
      skippedUsers.push({ sourceTable: "vineyard_members", v1UserId, email, vineyardId, reason: "membership role is missing or invalid" });
      continue;
    }
    const mappedUserId = v1UserId ? input.maps.v1UserIdToV2UserId[v1UserId] ?? null : null;
    if (mappedUserId) {
      const key = membershipKey(vineyardId, mappedUserId);
      if (!key) {
        membershipsSkipped += 1;
        continue;
      }
      if (proposedMembershipKeys.has(key)) {
        membershipsSkipped += 1;
        continue;
      }
      proposedMembershipKeys.add(key);
      const existing = existingMembershipKeys.get(key) ?? null;
      const displayName = nonEmptyString(membership.display_name);
      const insertRow = compactJsonRecord({
        vineyard_id: vineyardId,
        user_id: mappedUserId,
        role,
        display_name: displayName,
        joined_at: stringOrUndefined(membership.joined_at ?? membership.created_at)
      });
      const updateRow = compactJsonRecord({
        vineyard_id: vineyardId,
        user_id: mappedUserId,
        role,
        display_name: displayName
      });
      const row = existing ? updateRow : insertRow;
      const changedFields = existing ? changedFieldsFor(existing, row, ["vineyard_id", "user_id"]) : Object.keys(row);
      if (existing && changedFields.length === 0) {
        membershipsSkipped += 1;
        continue;
      }
      membershipsToUpsert.push({ table: "vineyard_members", action: existing ? "update" : "insert", key, sourceId: asString(membership.id), row, existingRow: existing, changedFields, warnings: [] });
      continue;
    }
    if (!email) {
      membershipsSkipped += 1;
      skippedUsers.push({ sourceTable: "vineyard_members", v1UserId, email, vineyardId, reason: "unmapped V1 user has no usable email for invitation" });
      continue;
    }
    if (!fallbackUserId) {
      risks.push("MIGRATION_FALLBACK_USER_ID is required before applying invitation creation for unmapped V1 users");
    } else if (!fallbackProfileExists) {
      risks.push("MIGRATION_FALLBACK_USER_ID does not match a V2 profile id; invitation inserts may fail foreign key validation");
    }
    const key = invitationKey(vineyardId, email);
    if (!key) {
      membershipsSkipped += 1;
      continue;
    }
    if (proposedInvitationKeys.has(key)) {
      invitationsSkipped += 1;
      skippedUsers.push({ sourceTable: "vineyard_members", v1UserId, email, vineyardId, reason: "duplicate unmapped V1 membership for the same vineyard/email pending invitation key" });
      continue;
    }
    proposedInvitationKeys.add(key);
    const existing = existingPendingInvitationKeys.get(key) ?? null;
    const row = compactJsonRecord({
      id: existing ? asString(existing.id) : randomUUID(),
      vineyard_id: vineyardId,
      email,
      role,
      status: "pending",
      invited_by: fallbackUserId ?? undefined,
      created_at: stringOrUndefined(membership.created_at),
      updated_at: stringOrUndefined(membership.updated_at ?? membership.created_at)
    });
    if (existing) {
      const updateRow = compactJsonRecord({
        id: asString(existing.id),
        role,
        invited_by: fallbackUserId ?? undefined
      });
      const changedFields = changedFieldsFor(existing, updateRow, ["id"]);
      if (changedFields.length === 0) {
        invitationsSkipped += 1;
      } else {
        invitationUpdates.push({ table: "invitations", action: "update", key, sourceId: asString(membership.id), row: updateRow, existingRow: existing, changedFields, warnings: ["existing pending invitation will be updated rather than duplicated"] });
      }
      skippedUsers.push({ sourceTable: "vineyard_members", v1UserId, email, vineyardId, reason: "V1 user is unmapped; access will be represented as a pending V2 invitation" });
      continue;
    }
    invitationsToCreate.push({ table: "invitations", action: "insert", key, sourceId: asString(membership.id), row, existingRow: null, changedFields: Object.keys(row), warnings: ["created from unmapped V1 vineyard membership"] });
    skippedUsers.push({ sourceTable: "vineyard_members", v1UserId, email, vineyardId, reason: "V1 user is unmapped; access will be represented as a pending V2 invitation" });
  }

  const sourceDisclaimers = input.v1.disclaimerAcceptances.rows;
  const proposedDisclaimerKeys = new Set<string>();
  for (const acceptance of sourceDisclaimers) {
    const v1UserId = asString(acceptance.user_id);
    const mappedUserId = v1UserId ? input.maps.v1UserIdToV2UserId[v1UserId] ?? null : null;
    const version = nonEmptyString(acceptance.version);
    const email = normalizeEmail(acceptance.email) ?? emailForV1User(input.v1, v1UserId);
    if (!mappedUserId) {
      disclaimerAcceptancesSkipped += 1;
      skippedUsers.push({ sourceTable: "disclaimer_acceptances", v1UserId, email, vineyardId: null, reason: "disclaimer acceptance user has no clean V2 user mapping" });
      continue;
    }
    if (!version) {
      disclaimerAcceptancesSkipped += 1;
      skippedUsers.push({ sourceTable: "disclaimer_acceptances", v1UserId, email, vineyardId: null, reason: "disclaimer acceptance is missing version" });
      continue;
    }
    const key = disclaimerKey(mappedUserId, version);
    if (!key) {
      disclaimerAcceptancesSkipped += 1;
      continue;
    }
    if (proposedDisclaimerKeys.has(key)) {
      disclaimerAcceptancesSkipped += 1;
      continue;
    }
    proposedDisclaimerKeys.add(key);
    const existing = existingDisclaimerKeys.get(key) ?? null;
    if (existing) {
      disclaimerAcceptancesSkipped += 1;
      continue;
    }
    const row = compactJsonRecord({
      id: isUuid(acceptance.id) ? acceptance.id : undefined,
      user_id: mappedUserId,
      version,
      display_name: nonEmptyString(acceptance.display_name),
      email,
      accepted_at: stringOrUndefined(acceptance.accepted_at ?? acceptance.created_at)
    });
    disclaimerAcceptancesToUpsert.push({ table: "disclaimer_acceptances", action: "insert", key, sourceId: asString(acceptance.id), row, existingRow: null, changedFields: Object.keys(row), warnings: [] });
  }

  const existingV2RowsThatWillBeUpdated = [...vineyardsToUpsert, ...membershipsToUpsert, ...invitationUpdates, ...disclaimerAcceptancesToUpsert].filter((action) => action.action === "update");
  const uniqueRisks = Array.from(new Set(risks));
  const uniqueWarnings = Array.from(new Set(warnings));
  const counts = {
    vineyardsToUpsert: vineyardsToUpsert.length,
    vineyardsInserted: vineyardsToUpsert.filter((action) => action.action === "insert").length,
    vineyardsUpdated: vineyardsToUpsert.filter((action) => action.action === "update").length,
    vineyardsSkipped,
    membershipsToUpsert: membershipsToUpsert.length,
    membershipsInserted: membershipsToUpsert.filter((action) => action.action === "insert").length,
    membershipsUpdated: membershipsToUpsert.filter((action) => action.action === "update").length,
    membershipsSkipped,
    invitationsToCreate: invitationsToCreate.length,
    invitationsToUpdate: invitationUpdates.length,
    invitationsSkipped,
    disclaimerAcceptancesToUpsert: disclaimerAcceptancesToUpsert.length,
    disclaimerAcceptancesSkipped,
    skippedUsers: skippedUsers.length,
    duplicateV1Emails: input.identityReport.duplicateV1Emails.length,
    duplicateV2Emails: input.identityReport.duplicateV2Emails.length,
    unmappedUsers: input.identityReport.unmappedV1Users.length,
    existingV2RowsThatWillBeUpdated: existingV2RowsThatWillBeUpdated.length,
    risks: uniqueRisks.length
  };

  return {
    generatedAt,
    mode: input.mode ?? "dry-run",
    stage: "access",
    filters: { vineyardId: input.vineyardId },
    fallbackUserId,
    vineyardsToUpsert,
    membershipsToUpsert,
    invitationsToCreate,
    invitationUpdates,
    disclaimerAcceptancesToUpsert,
    skippedUsers,
    duplicateEmails: {
      v1: input.identityReport.duplicateV1Emails,
      v2: input.identityReport.duplicateV2Emails
    },
    unmappedUsers: input.identityReport.unmappedV1Users,
    existingV2RowsThatWillBeUpdated,
    risks: uniqueRisks,
    warnings: uniqueWarnings,
    counts
  };
}

export function buildAccessMigrationReport(plan: AccessMigrationPlan): AccessMigrationReport {
  return {
    generatedAt: new Date().toISOString(),
    mode: "dry-run",
    stage: "access",
    counts: plan.counts,
    vineyardsToUpsert: plan.vineyardsToUpsert,
    membershipsToUpsert: plan.membershipsToUpsert,
    invitationsToCreate: plan.invitationsToCreate,
    invitationUpdates: plan.invitationUpdates,
    disclaimerAcceptancesToUpsert: plan.disclaimerAcceptancesToUpsert,
    skippedUsers: plan.skippedUsers,
    duplicateEmails: plan.duplicateEmails,
    unmappedUsers: plan.unmappedUsers,
    existingV2RowsThatWillBeUpdated: plan.existingV2RowsThatWillBeUpdated,
    risks: plan.risks,
    warnings: plan.warnings
  };
}

export function buildAccessSummary(plan: AccessMigrationPlan): AccessMigrationReportSummary {
  return {
    vineyardsToUpsert: plan.vineyardsToUpsert.length,
    membershipsToUpsert: plan.membershipsToUpsert.length,
    invitationsToCreate: plan.invitationsToCreate.length,
    disclaimerAcceptancesToUpsert: plan.disclaimerAcceptancesToUpsert.length,
    skippedUsers: plan.skippedUsers.length,
    duplicateV1Emails: plan.duplicateEmails.v1.length,
    duplicateV2Emails: plan.duplicateEmails.v2.length,
    unmappedUsers: plan.unmappedUsers.length,
    existingV2RowsThatWillBeUpdated: plan.existingV2RowsThatWillBeUpdated.length,
    risks: plan.risks
  };
}

export async function applyAccessMigrationPlan(client: SupabaseClient, plan: AccessMigrationPlan): Promise<AccessApplyResult> {
  if (plan.invitationsToCreate.length > 0 && !plan.fallbackUserId) {
    throw new Error("Cannot apply access migration: MIGRATION_FALLBACK_USER_ID is required to create pending invitations.");
  }

  const result: AccessApplyResult = {
    generatedAt: new Date().toISOString(),
    mode: "apply-access",
    counts: {
      vineyards: { inserted: 0, updated: 0, skipped: numberCount(plan.counts.vineyardsSkipped) },
      memberships: { inserted: 0, updated: 0, skipped: numberCount(plan.counts.membershipsSkipped) },
      invitations: { inserted: 0, updated: 0, skipped: numberCount(plan.counts.invitationsSkipped) },
      disclaimerAcceptances: { inserted: 0, skipped: numberCount(plan.counts.disclaimerAcceptancesSkipped) }
    },
    errors: []
  };

  for (const action of plan.vineyardsToUpsert) {
    const error = action.action === "insert"
      ? await upsert(client, "vineyards", action.row, "id")
      : await updateBy(client, "vineyards", withoutKeys(action.row, ["id"]), { id: asString(action.row.id) });
    recordApplyResult(result, "vineyards", action, error);
  }

  for (const action of plan.membershipsToUpsert) {
    const error = action.action === "insert"
      ? await upsert(client, "vineyard_members", action.row, "vineyard_id,user_id")
      : await updateBy(client, "vineyard_members", withoutKeys(action.row, ["vineyard_id", "user_id"]), { vineyard_id: asString(action.row.vineyard_id), user_id: asString(action.row.user_id) });
    recordApplyResult(result, "memberships", action, error);
  }

  for (const action of plan.invitationsToCreate) {
    const error = await insert(client, "invitations", action.row);
    recordApplyResult(result, "invitations", action, error);
  }

  for (const action of plan.invitationUpdates) {
    const error = await updateBy(client, "invitations", withoutKeys(action.row, ["id"]), { id: asString(action.row.id) });
    recordApplyResult(result, "invitations", action, error);
  }

  for (const action of plan.disclaimerAcceptancesToUpsert) {
    const error = await upsert(client, "disclaimer_acceptances", action.row, "user_id,version", true);
    if (error) {
      result.errors.push({ table: action.table, key: action.key, action: action.action, message: error });
    } else {
      result.counts.disclaimerAcceptances.inserted += 1;
    }
  }

  return result;
}

function getTargetRows(v2: TargetSnapshot, table: string, warnings: string[]): JsonRecord[] {
  const result = v2.vineyardDataTargetTables[table];
  if (!result) {
    warnings.push(`V2 table ${table} was missing from snapshot; treating as empty`);
    return [];
  }
  if (!result.exists || result.error) {
    warnings.push(`V2 table ${table} was unavailable; treating as empty${result.error ? ` (${result.error})` : ""}`);
    return [];
  }
  return Array.isArray(result.rows) ? result.rows : [];
}

function rowsById(rows: JsonRecord[]): Map<string, JsonRecord> {
  return new Map(rows.map((row) => [asString(row.id), row]).filter(([id]) => Boolean(id)) as Array<[string, JsonRecord]>);
}

function filterVineyards(rows: JsonRecord[], vineyardId?: string): JsonRecord[] {
  if (!vineyardId) return rows;
  return rows.filter((row) => row.id === vineyardId);
}

function filterRowsByVineyard(rows: JsonRecord[], vineyardId?: string): JsonRecord[] {
  if (!vineyardId) return rows;
  return rows.filter((row) => row.vineyard_id === vineyardId || row.vineyardId === vineyardId);
}

function emailForV1User(v1: SourceSnapshot, userId: string | null): string | null {
  if (!userId) return null;
  const authUser = v1.users.find((user) => user.id === userId);
  const authEmail = normalizeEmail(authUser?.email);
  if (authEmail) return authEmail;
  const profile = v1.profiles.rows.find((row) => asString(row.id ?? row.user_id) === userId);
  return normalizeEmail(profile?.email);
}

function normalizeRole(value: unknown): string | null {
  const role = asString(value)?.toLowerCase() ?? null;
  return role && validRoles.has(role) ? role : null;
}

function membershipKey(vineyardId: string | null, userId: string | null): string | null {
  return vineyardId && userId ? `${vineyardId}|${userId}` : null;
}

function invitationKey(vineyardId: string | null, email: string | null): string | null {
  return vineyardId && email ? `${vineyardId}|${email}|pending` : null;
}

function disclaimerKey(userId: string | null, version: string | null): string | null {
  return userId && version ? `${userId}|${version}` : null;
}

function invitationStatus(row: JsonRecord): string {
  return asString(row.status)?.toLowerCase() ?? "pending";
}

function changedFieldsFor(existing: JsonRecord, row: JsonRecord, ignoredKeys: string[]): string[] {
  return Object.keys(row).filter((key) => !ignoredKeys.includes(key) && stableJson(existing[key]) !== stableJson(row[key]));
}

function compactJsonRecord(values: Record<string, JsonValue | undefined>): JsonRecord {
  const row: JsonRecord = {};
  for (const [key, value] of Object.entries(values)) {
    if (value !== undefined) row[key] = value;
  }
  return row;
}

function nullableString(value: unknown): string | null | undefined {
  if (value === null) return null;
  return stringOrUndefined(value);
}

function stringOrUndefined(value: unknown): string | undefined {
  const stringValue = asString(value);
  return stringValue ?? undefined;
}

function nonEmptyString(value: unknown): string | undefined {
  return stringOrUndefined(value);
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function withoutKeys(row: JsonRecord, keys: string[]): JsonRecord {
  const copy: JsonRecord = {};
  for (const [key, value] of Object.entries(row)) {
    if (!keys.includes(key)) copy[key] = value;
  }
  return copy;
}

async function upsert(client: SupabaseClient, table: string, row: JsonRecord, onConflict: string, ignoreDuplicates = false): Promise<string | null> {
  const { error } = await client.from(table).upsert(row, { onConflict, ignoreDuplicates });
  return error?.message ?? null;
}

async function insert(client: SupabaseClient, table: string, row: JsonRecord): Promise<string | null> {
  const { error } = await client.from(table).insert(row);
  return error?.message ?? null;
}

async function updateBy(client: SupabaseClient, table: string, row: JsonRecord, match: Record<string, string | null>): Promise<string | null> {
  let query = client.from(table).update(row);
  for (const [key, value] of Object.entries(match)) {
    if (!value) return `Missing match value for ${key}`;
    query = query.eq(key, value);
  }
  const { error } = await query;
  return error?.message ?? null;
}

function recordApplyResult(result: AccessApplyResult, group: "vineyards" | "memberships" | "invitations", action: AccessMigrationAction, error: string | null): void {
  if (error) {
    result.errors.push({ table: action.table, key: action.key, action: action.action, message: error });
    return;
  }
  if (action.action === "insert") result.counts[group].inserted += 1;
  else if (action.action === "update") result.counts[group].updated += 1;
  else result.counts[group].skipped += 1;
}

function numberCount(value: unknown): number {
  return typeof value === "number" ? value : 0;
}
