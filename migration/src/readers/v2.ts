import type { SupabaseClient } from "@supabase/supabase-js";
import type { AuthUserRecord, JsonRecord, SchemaCoverageReport, TableReadResult, TargetSnapshot } from "../types.js";

export const expectedV2Tables = [
  "profiles",
  "vineyards",
  "vineyard_members",
  "invitations",
  "disclaimer_acceptances",
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
];

export async function readV2Snapshot(client: SupabaseClient): Promise<TargetSnapshot> {
  const [users, profiles, schemaCoverage, vineyardDataTargetTables] = await Promise.all([
    listAuthUsers(client),
    readTable(client, "profiles"),
    readSchemaCoverage(client),
    readVineyardDataTargetTables(client)
  ]);
  return { users, profiles, schemaCoverage, vineyardDataTargetTables };
}

async function readVineyardDataTargetTables(client: SupabaseClient): Promise<Record<string, TableReadResult<JsonRecord>>> {
  const targetTables = expectedV2Tables.filter((table) => table !== "profiles");
  const results = await Promise.all(targetTables.map(async (table) => readTable(client, table)));
  return Object.fromEntries(results.map((result) => [result.table, result]));
}

export async function readSchemaCoverage(client: SupabaseClient): Promise<SchemaCoverageReport> {
  const tables = await Promise.all(expectedV2Tables.map(async (table) => {
    const result = await readTable(client, table, { limit: 1, count: true });
    return {
      table,
      exists: result.exists,
      rowCount: result.count ?? null,
      error: result.error
    };
  }));
  return { generatedAt: new Date().toISOString(), tables };
}

export async function listAuthUsers(client: SupabaseClient): Promise<AuthUserRecord[]> {
  const users: AuthUserRecord[] = [];
  let page = 1;
  const perPage = 1000;
  while (true) {
    const { data, error } = await client.auth.admin.listUsers({ page, perPage });
    if (error) throw new Error(`auth.admin.listUsers failed: ${error.message}`);
    const pageUsers = data.users ?? [];
    users.push(...pageUsers.map((user) => ({
      id: user.id,
      email: user.email ?? null,
      createdAt: user.created_at ?? null,
      provider: typeof user.app_metadata?.provider === "string" ? user.app_metadata.provider : null
    })));
    if (pageUsers.length < perPage) break;
    page += 1;
  }
  return users;
}

export async function readTable<T extends JsonRecord = JsonRecord>(
  client: SupabaseClient,
  table: string,
  options: { limit?: number; count?: boolean } = {}
): Promise<TableReadResult<T> & { count?: number | null }> {
  const rows: T[] = [];
  const pageSize = options.limit ?? 1000;
  let from = 0;
  let totalCount: number | null = null;

  while (true) {
    let query = client.from(table).select("*", options.count ? { count: "exact" } : undefined).range(from, from + pageSize - 1);
    const { data, error, count } = await query;
    if (error) {
      return { table, rows: [], exists: !isMissingTableError(error.message), error: error.message, count: null };
    }
    if (typeof count === "number") totalCount = count;
    const pageRows = (data ?? []) as T[];
    rows.push(...pageRows);
    if (options.limit || pageRows.length < pageSize) break;
    from += pageSize;
  }

  return { table, rows, exists: true, count: totalCount };
}

function isMissingTableError(message: string): boolean {
  const lower = message.toLowerCase();
  return lower.includes("could not find the table") || lower.includes("does not exist") || lower.includes("schema cache");
}
