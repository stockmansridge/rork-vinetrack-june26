export type Stage = "identity" | "vineyards" | "invitations" | "access" | "all";

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export type JsonRecord = Record<string, JsonValue>;

export type TableReadResult<T extends JsonRecord = JsonRecord> = {
  table: string;
  rows: T[];
  exists: boolean;
  error?: string;
};

export type AuthUserRecord = {
  id: string;
  email: string | null;
  createdAt?: string | null;
  provider?: string | null;
};

export type ProfileRecord = JsonRecord & {
  id?: string;
  user_id?: string;
  email?: string | null;
  full_name?: string | null;
  name?: string | null;
  display_name?: string | null;
};

export type VineyardRecord = JsonRecord & {
  id?: string;
  name?: string;
  owner_id?: string | null;
  user_id?: string | null;
  email?: string | null;
  country?: string | null;
  deleted_at?: string | null;
};

export type VineyardMemberRecord = JsonRecord & {
  id?: string;
  vineyard_id?: string;
  user_id?: string | null;
  email?: string | null;
  role?: string | null;
  display_name?: string | null;
};

export type InvitationRecord = JsonRecord & {
  id?: string;
  vineyard_id?: string;
  email?: string | null;
  role?: string | null;
  status?: string | null;
  expires_at?: string | null;
  invited_by?: string | null;
  created_at?: string | null;
};

export type DisclaimerAcceptanceRecord = JsonRecord & {
  id?: string;
  user_id?: string | null;
  email?: string | null;
  version?: string | null;
  accepted_at?: string | null;
  display_name?: string | null;
};

export type VineyardDataRecord = JsonRecord & {
  id?: string;
  vineyard_id?: string | null;
  vineyardId?: string | null;
  data_type?: string | null;
  user_id?: string | null;
  data?: JsonValue;
  payload?: JsonValue;
  json?: JsonValue;
  value?: JsonValue;
};

export type SourceSnapshot = {
  users: AuthUserRecord[];
  profiles: TableReadResult<ProfileRecord>;
  vineyards: TableReadResult<VineyardRecord>;
  vineyardMembers: TableReadResult<VineyardMemberRecord>;
  invitations: TableReadResult<InvitationRecord>;
  disclaimerAcceptances: TableReadResult<DisclaimerAcceptanceRecord>;
  vineyardData: TableReadResult<VineyardDataRecord>;
};

export type TargetSnapshot = {
  users: AuthUserRecord[];
  profiles: TableReadResult<ProfileRecord>;
  schemaCoverage: SchemaCoverageReport;
  vineyardDataTargetTables: Record<string, TableReadResult<JsonRecord>>;
};

export type DuplicateEmailReport = {
  email: string;
  ids: string[];
};

export type IdentityMapEntry = {
  v1UserId: string;
  v1Email: string | null;
  v2UserId: string | null;
  source: "auth_email" | "profile_email" | "unmapped";
};

export type IdentityDryRunReport = {
  generatedAt: string;
  v1AuthUserCount: number;
  v1ProfileCount: number;
  v2AuthUserCount: number;
  v2ProfileCount: number;
  mappedUsers: IdentityMapEntry[];
  unmappedV1Users: IdentityMapEntry[];
  duplicateV1Emails: DuplicateEmailReport[];
  duplicateV2Emails: DuplicateEmailReport[];
  missingOptionalTables: string[];
};

export type VineyardMappingReport = {
  generatedAt: string;
  sourceCount: number;
  validUuidCount: number;
  invalidUuidRecords: JsonRecord[];
  mapped: Array<{
    v1VineyardId: string;
    targetVineyardId: string;
    name: string | null;
    v1OwnerId: string | null;
    v2OwnerId: string | null;
    ownerMapped: boolean;
  }>;
  ownerMappingFailures: Array<{
    vineyardId: string | null;
    name: string | null;
    ownerId: string | null;
    reason: string;
  }>;
  missingOptionalTables: string[];
};

export type MemberMappingReport = {
  generatedAt: string;
  sourceCount: number;
  mappedCount: number;
  orphanMemberships: JsonRecord[];
  missingUsers: JsonRecord[];
  invalidRoles: JsonRecord[];
};

export type InvitationDryRunReport = {
  generatedAt: string;
  sourceCount: number;
  pendingCurrentCount: number;
  staleOrExpiredCount: number;
  pendingCurrent: InvitationRecord[];
  staleOrExpired: InvitationRecord[];
  invalidRoles: InvitationRecord[];
  invalidVineyards: InvitationRecord[];
  duplicatePendingEmails: DuplicateEmailReport[];
};

export type DisclaimerDryRunReport = {
  generatedAt: string;
  sourceCount: number;
  mappedCount: number;
  missingUsers: DisclaimerAcceptanceRecord[];
  missingVersion: DisclaimerAcceptanceRecord[];
};

export type VineyardDataPayloadKind = "array" | "object" | "json_string_array" | "json_string_object" | "json_string_primitive" | "primitive" | "null";

export type VineyardDataInventoryEntry = {
  vineyardId: string | null;
  rowId: string | null;
  dataType: string | null;
  mappedEntityName: string | null;
  payloadKind: VineyardDataPayloadKind;
  recordCount: number;
  keysFound: string[];
  knownCounts: Record<string, number>;
  unknownKeys: string[];
  estimatedRecordVolume: number;
  missingVineyardId: boolean;
  invalidIds: string[];
  storageReferences: string[];
  likelyTransformBlockers: string[];
};

export type VineyardDataInventoryReport = {
  generatedAt: string;
  sourceCount: number;
  keysInspected: string[];
  totalKnownCounts: Record<string, number>;
  entries: VineyardDataInventoryEntry[];
  recordsWithMissingVineyardId: number;
  rowsWithInvalidIds: number;
  unknownKeys: string[];
};

export type ProposedV2VineyardDataRow = {
  sourceRowId: string | null;
  sourceDataType: string | null;
  sourceEntityName: string | null;
  sourceRecordIndex: number;
  targetTable: string;
  proposedId: string | null;
  naturalKey: string | null;
  row: JsonRecord;
  sourceRecord: JsonValue;
  fallbacks: string[];
  blockers: string[];
};

export type VineyardDataTransformSkippedRow = {
  sourceRowId: string | null;
  vineyardId: string | null;
  dataType: string | null;
  mappedEntityName: string | null;
  payloadKind: VineyardDataPayloadKind;
  reason: string;
  fallbacks: string[];
};

export type VineyardDataConflictReport = {
  targetTable: string;
  conflictType: "existing_row_id" | "existing_natural_key" | "proposed_row_id_duplicate" | "proposed_natural_key_duplicate";
  severity: "duplicate" | "conflict" | "needs_review";
  proposedIds: string[];
  existingIds: string[];
  sourceRowIds: string[];
  naturalKey: string | null;
  detail: string;
};

export type VineyardDataTransformReport = {
  generatedAt: string;
  sourceCount: number;
  proposedRowCount: number;
  proposedRowsByTable: Record<string, number>;
  fallbackCount: number;
  skippedRows: VineyardDataTransformSkippedRow[];
  rows: ProposedV2VineyardDataRow[];
  duplicateProposedRowIds: VineyardDataConflictReport[];
  duplicateProposedNaturalKeys: VineyardDataConflictReport[];
  existingV2RowIdConflicts: VineyardDataConflictReport[];
  existingV2NaturalKeyConflicts: VineyardDataConflictReport[];
  existingV2TablesRead: Array<{ table: string; exists: boolean; rowCount: number; error?: string }>;
  warnings: string[];
};

export type SchemaCoverageReport = {
  generatedAt: string;
  tables: Array<{
    table: string;
    exists: boolean;
    rowCount?: number | null;
    error?: string;
  }>;
};

export type MapsFile = {
  generatedAt: string;
  usersByEmail: Record<string, string>;
  v1UserIdToV2UserId: Record<string, string>;
  vineyardsById: Record<string, string>;
};

export type Phase16CReportSummary = {
  proposedRowsByTable: Record<string, number>;
  skippedRowCount: number;
  fallbackCreatedByCount: number;
  fallbackCount: number;
  duplicateProposedRowIds: VineyardDataConflictReport[];
  duplicateProposedNaturalKeys: VineyardDataConflictReport[];
  existingV2RowIdConflicts: VineyardDataConflictReport[];
  existingV2NaturalKeyConflicts: VineyardDataConflictReport[];
  warnings: string[];
};

export type AccessMigrationAction = {
  table: "vineyards" | "vineyard_members" | "invitations" | "disclaimer_acceptances";
  action: "insert" | "update" | "skip";
  key: string;
  sourceId: string | null;
  row: JsonRecord;
  existingRow: JsonRecord | null;
  changedFields: string[];
  warnings: string[];
};

export type AccessMigrationSkippedUser = {
  sourceTable: "vineyard_members" | "disclaimer_acceptances" | "vineyards";
  v1UserId: string | null;
  email: string | null;
  vineyardId: string | null;
  reason: string;
};

export type AccessMigrationPlan = {
  generatedAt: string;
  mode: "dry-run" | "apply-access-plan";
  stage: "access";
  filters: { vineyardId?: string };
  fallbackUserId: string | null;
  vineyardsToUpsert: AccessMigrationAction[];
  membershipsToUpsert: AccessMigrationAction[];
  invitationsToCreate: AccessMigrationAction[];
  invitationUpdates: AccessMigrationAction[];
  disclaimerAcceptancesToUpsert: AccessMigrationAction[];
  skippedUsers: AccessMigrationSkippedUser[];
  duplicateEmails: {
    v1: DuplicateEmailReport[];
    v2: DuplicateEmailReport[];
  };
  unmappedUsers: IdentityMapEntry[];
  existingV2RowsThatWillBeUpdated: AccessMigrationAction[];
  risks: string[];
  warnings: string[];
  counts: Record<string, number>;
};

export type AccessMigrationReport = {
  generatedAt: string;
  mode: "dry-run";
  stage: "access";
  counts: Record<string, number>;
  vineyardsToUpsert: AccessMigrationAction[];
  membershipsToUpsert: AccessMigrationAction[];
  invitationsToCreate: AccessMigrationAction[];
  invitationUpdates: AccessMigrationAction[];
  disclaimerAcceptancesToUpsert: AccessMigrationAction[];
  skippedUsers: AccessMigrationSkippedUser[];
  duplicateEmails: {
    v1: DuplicateEmailReport[];
    v2: DuplicateEmailReport[];
  };
  unmappedUsers: IdentityMapEntry[];
  existingV2RowsThatWillBeUpdated: AccessMigrationAction[];
  risks: string[];
  warnings: string[];
};

export type AccessApplyResult = {
  generatedAt: string;
  mode: "apply-access";
  counts: {
    vineyards: { inserted: number; updated: number; skipped: number };
    memberships: { inserted: number; updated: number; skipped: number };
    invitations: { inserted: number; updated: number; skipped: number };
    disclaimerAcceptances: { inserted: number; skipped: number };
  };
  errors: Array<{ table: string; key: string; action: string; message: string }>;
};

export type AccessMigrationReportSummary = {
  vineyardsToUpsert: number;
  membershipsToUpsert: number;
  invitationsToCreate: number;
  disclaimerAcceptancesToUpsert: number;
  skippedUsers: number;
  duplicateV1Emails: number;
  duplicateV2Emails: number;
  unmappedUsers: number;
  existingV2RowsThatWillBeUpdated: number;
  risks: string[];
};

export type ReportSummary = {
  generatedAt: string;
  mode: "dry-run";
  stage: Stage;
  filters: { vineyardId?: string };
  filesWritten: string[];
  counts: Record<string, number>;
  warnings: string[];
  schemaCoverage?: SchemaCoverageReport;
  phase16c?: Phase16CReportSummary;
  access?: AccessMigrationReportSummary;
};
