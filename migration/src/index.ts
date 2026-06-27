import { loadConfig } from "./config.js";
import { createMigrationClients } from "./clients.js";
import { readV1Snapshot } from "./readers/v1.js";
import { readV2Snapshot } from "./readers/v2.js";
import {
  applyAccessMigrationPlan,
  buildAccessMigrationPlan,
  buildAccessMigrationReport,
  buildAccessSummary
} from "./access.js";
import {
  buildDisclaimerReport,
  buildIdentityReport,
  buildInvitationReport,
  buildMemberReport,
  buildPhase16CSummary,
  buildVineyardDataInventory,
  buildVineyardDataTransformReport,
  buildVineyardReport
} from "./remap.js";
import { writeJson } from "./report.js";
import type { AccessMigrationReportSummary, Phase16CReportSummary, ReportSummary, VineyardDataTransformReport } from "./types.js";

async function main(): Promise<void> {
  const config = loadConfig(process.argv.slice(2));
  const clients = createMigrationClients(config);
  const [v1, v2] = await Promise.all([readV1Snapshot(clients.v1), readV2Snapshot(clients.v2)]);
  const filesWritten: string[] = [];
  const warnings: string[] = [];

  const { report: identityReport, maps } = buildIdentityReport(v1, v2);
  filesWritten.push(await writeJson(config.outDir, "maps.json", maps));

  if (config.stage === "access") {
    const plan = buildAccessMigrationPlan({
      v1,
      v2,
      maps,
      identityReport,
      vineyardId: config.vineyardId,
      fallbackUserId: config.migrationFallbackUserId,
      mode: config.applyAccess ? "apply-access-plan" : "dry-run"
    });
    const report = buildAccessMigrationReport(plan);
    if (config.applyAccess) {
      filesWritten.push(await writeJson(config.outDir, "access-apply-plan.json", plan));
      const applyResult = await applyAccessMigrationPlan(clients.v2, plan);
      filesWritten.push(await writeJson(config.outDir, "access-apply-result.json", applyResult));
      console.log(`Phase 16C-lite access apply complete. Wrote ${filesWritten.length} files to migration/out.`);
      return;
    }
    filesWritten.push(await writeJson(config.outDir, "access-migration-plan.json", plan));
    filesWritten.push(await writeJson(config.outDir, "access-migration-report.json", report));
    const accessSummary = buildAccessSummary(plan);
    const count = (key: string): number => plan.counts[key] ?? 0;
    const summary = buildReportSummary({
      config,
      filesWritten,
      warnings: [...plan.warnings, ...plan.risks],
      v1,
      v2,
      identityReport,
      vineyardSourceCount: count("vineyardsToUpsert") + count("vineyardsSkipped"),
      mappedVineyards: count("vineyardsToUpsert"),
      vineyardMembers: count("membershipsToUpsert") + count("membershipsSkipped"),
      pendingInvitations: count("invitationsToCreate"),
      disclaimerAcceptances: count("disclaimerAcceptancesToUpsert") + count("disclaimerAcceptancesSkipped"),
      accessSummary
    });
    filesWritten.push(await writeJson(config.outDir, "report-summary.json", summary));
    console.log(`Phase 16C-lite access dry-run complete. Wrote ${filesWritten.length} files to migration/out.`);
    return;
  }

  if (config.stage === "identity" || config.stage === "all") {
    filesWritten.push(await writeJson(config.outDir, "dry-run-identity.json", identityReport));
  }

  const vineyardReport = buildVineyardReport(v1, maps, config.vineyardId);
  const memberReport = buildMemberReport(v1, maps, config.vineyardId);
  const disclaimerReport = buildDisclaimerReport(v1, maps);

  if (config.stage === "vineyards" || config.stage === "all") {
    filesWritten.push(await writeJson(config.outDir, "dry-run-vineyards.json", {
      vineyards: vineyardReport,
      vineyardMembers: memberReport,
      disclaimerAcceptances: disclaimerReport
    }));
  }

  const invitationReport = buildInvitationReport(v1, maps, config.vineyardId);
  if (config.stage === "invitations" || config.stage === "all") {
    filesWritten.push(await writeJson(config.outDir, "dry-run-invitations.json", invitationReport));
  }

  let vineyardDataTransformReport: VineyardDataTransformReport | null = null;
  let phase16cSummary: Phase16CReportSummary | undefined;
  if (config.stage === "all") {
    const inventory = buildVineyardDataInventory(v1, config.vineyardId);
    vineyardDataTransformReport = buildVineyardDataTransformReport(v1, v2, maps, config.vineyardId);
    phase16cSummary = buildPhase16CSummary(vineyardDataTransformReport);
    filesWritten.push(await writeJson(config.outDir, "vineyard-data-inventory.json", inventory));
    filesWritten.push(await writeJson(config.outDir, "vineyard-data-proposed-v2-rows.json", {
      generatedAt: vineyardDataTransformReport.generatedAt,
      sourceCount: vineyardDataTransformReport.sourceCount,
      proposedRowCount: vineyardDataTransformReport.proposedRowCount,
      proposedRowsByTable: vineyardDataTransformReport.proposedRowsByTable,
      rows: vineyardDataTransformReport.rows
    }));
    filesWritten.push(await writeJson(config.outDir, "phase16c-transform-report.json", vineyardDataTransformReport));
  }

  for (const tableResult of [v1.profiles, v1.vineyards, v1.vineyardMembers, v1.invitations, v1.disclaimerAcceptances, v1.vineyardData, v2.profiles]) {
    if (!tableResult.exists) warnings.push(`Optional table missing or inaccessible: ${tableResult.table}${tableResult.error ? ` (${tableResult.error})` : ""}`);
  }
  for (const table of v2.schemaCoverage.tables) {
    if (!table.exists) warnings.push(`V2 destination table missing or inaccessible: ${table.table}${table.error ? ` (${table.error})` : ""}`);
  }
  if (vineyardDataTransformReport) {
    warnings.push(...vineyardDataTransformReport.warnings);
    if (vineyardDataTransformReport.fallbackCount > 0) warnings.push(`${vineyardDataTransformReport.fallbackCount} vineyard_data transform fallback(s) flagged`);
    if (vineyardDataTransformReport.skippedRows.length > 0) warnings.push(`${vineyardDataTransformReport.skippedRows.length} vineyard_data row(s) skipped from proposed V2 transform`);
    if (vineyardDataTransformReport.duplicateProposedRowIds.length > 0) warnings.push(`${vineyardDataTransformReport.duplicateProposedRowIds.length} proposed V2 row id duplicate group(s) found`);
    if (vineyardDataTransformReport.duplicateProposedNaturalKeys.length > 0) warnings.push(`${vineyardDataTransformReport.duplicateProposedNaturalKeys.length} proposed V2 natural key duplicate group(s) found`);
    if (vineyardDataTransformReport.existingV2RowIdConflicts.length > 0) warnings.push(`${vineyardDataTransformReport.existingV2RowIdConflicts.length} proposed row id conflict(s) against existing V2 rows found`);
    if (vineyardDataTransformReport.existingV2NaturalKeyConflicts.length > 0) warnings.push(`${vineyardDataTransformReport.existingV2NaturalKeyConflicts.length} proposed natural key conflict(s) against existing V2 rows found`);
  }

  const summary = buildReportSummary({
    config,
    filesWritten,
    warnings,
    v1,
    v2,
    identityReport,
    vineyardSourceCount: vineyardReport.sourceCount,
    mappedVineyards: vineyardReport.mapped.length,
    vineyardMembers: memberReport.sourceCount,
    pendingInvitations: invitationReport.pendingCurrentCount,
    disclaimerAcceptances: disclaimerReport.sourceCount,
    vineyardDataTransformReport,
    phase16cSummary
  });

  filesWritten.push(await writeJson(config.outDir, "report-summary.json", summary));
  console.log(`Phase 16C dry-run complete. Wrote ${filesWritten.length} files to migration/out.`);
  if (warnings.length > 0) console.log(`${warnings.length} warning(s) written to report-summary.json.`);
}

type ReportSummaryInput = {
  config: ReturnType<typeof loadConfig>;
  filesWritten: string[];
  warnings: string[];
  v1: Awaited<ReturnType<typeof readV1Snapshot>>;
  v2: Awaited<ReturnType<typeof readV2Snapshot>>;
  identityReport: ReturnType<typeof buildIdentityReport>["report"];
  vineyardSourceCount: number;
  mappedVineyards: number;
  vineyardMembers: number;
  pendingInvitations: number;
  disclaimerAcceptances: number;
  vineyardDataTransformReport?: VineyardDataTransformReport | null;
  phase16cSummary?: Phase16CReportSummary;
  accessSummary?: AccessMigrationReportSummary;
};

function buildReportSummary(input: ReportSummaryInput): ReportSummary {
  const phase16cSummary = input.phase16cSummary;
  const vineyardDataTransformReport = input.vineyardDataTransformReport;
  return {
    generatedAt: new Date().toISOString(),
    mode: "dry-run",
    stage: input.config.stage,
    filters: { vineyardId: input.config.vineyardId },
    filesWritten: input.filesWritten.map((file) => file.replace(`${input.config.outDir}/`, "migration/out/")),
    counts: {
      v1AuthUsers: input.v1.users.length,
      v1Profiles: input.v1.profiles.rows.length,
      v2AuthUsers: input.v2.users.length,
      mappedUsers: input.identityReport.mappedUsers.filter((entry) => entry.v2UserId).length,
      unmappedV1Users: input.identityReport.unmappedV1Users.length,
      vineyards: input.vineyardSourceCount,
      mappedVineyards: input.mappedVineyards,
      vineyardMembers: input.vineyardMembers,
      pendingInvitations: input.pendingInvitations,
      disclaimerAcceptances: input.disclaimerAcceptances,
      v1VineyardDataRows: input.config.stage === "access" ? 0 : input.v1.vineyardData.rows.length,
      proposedV2VineyardDataRows: vineyardDataTransformReport?.proposedRowCount ?? 0,
      vineyardDataTransformFallbacks: vineyardDataTransformReport?.fallbackCount ?? 0,
      vineyardDataSkippedRows: phase16cSummary?.skippedRowCount ?? 0,
      vineyardDataFallbackCreatedByCount: phase16cSummary?.fallbackCreatedByCount ?? 0,
      vineyardDataDuplicateProposedRowIds: phase16cSummary?.duplicateProposedRowIds.length ?? 0,
      vineyardDataDuplicateNaturalKeys: phase16cSummary?.duplicateProposedNaturalKeys.length ?? 0,
      vineyardDataExistingRowIdConflicts: phase16cSummary?.existingV2RowIdConflicts.length ?? 0,
      vineyardDataExistingNaturalKeyConflicts: phase16cSummary?.existingV2NaturalKeyConflicts.length ?? 0
    },
    warnings: input.warnings,
    schemaCoverage: input.v2.schemaCoverage,
    phase16c: phase16cSummary,
    access: input.accessSummary
  };
}

main().catch((error: unknown) => {
  if (error instanceof Error) {
    console.error(error.stack ?? error.message);
  } else {
    console.error(String(error));
  }
  process.exit(1);
});
