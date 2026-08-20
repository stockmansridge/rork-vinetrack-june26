// Stage 5 — AWRI Dog Book seed DRY RUN runner (read-only, no database).
//
//   cd supabase/functions/chemical-info-lookup/ingestion
//   deno run --allow-net --allow-read --allow-write seeds/run_awri_dryrun.ts \
//     --manifest seeds/awri_dogbook_2026_27.json \
//     --out seeds/awri_dogbook_2026_27.dryrun.json \
//     --sql-out ../../../../sql/stage5_awri_dryrun_compare.sql \
//     [--snapshot /tmp/pubcris_products.json]
//
// Reads the versioned seed manifest, obtains an APVMA PubCRIS product
// snapshot (from --snapshot, or read-only from the public data.gov.au CKAN
// datastore), resolves every seed name with the ingestion pipeline's
// deterministic discipline, and writes:
//   * the dry-run classification artifact (--out)
//   * the read-only master_chemicals comparison SQL (--sql-out)
// It performs ZERO writes to any database. There is no Supabase client here
// at all — "Already in Master" stays pending until the operator runs the
// comparison SQL manually.

import {
  buildComparisonSql,
  formatSeedReport,
  runSeedDryRun,
  type AwriSeedManifest,
  type RegisterProductRow,
} from "../seed_awri.ts";
import { APVMA_DATASTORE_URL, APVMA_RESOURCES } from "../apvma.ts";

interface Args {
  manifest: string;
  out: string;
  sqlOut: string;
  snapshot: string | null;
}

function parseArgs(argv: string[]): Args {
  const get = (flag: string): string | null => {
    const i = argv.indexOf(flag);
    return i >= 0 && argv[i + 1] ? argv[i + 1] : null;
  };
  const manifest = get("--manifest");
  const out = get("--out");
  const sqlOut = get("--sql-out");
  if (!manifest || !out || !sqlOut) {
    console.error("required: --manifest <path> --out <path> --sql-out <path> [--snapshot <path>]");
    Deno.exit(2);
  }
  return { manifest, out, sqlOut, snapshot: get("--snapshot") };
}

// deno-lint-ignore no-explicit-any
function toRegisterRow(raw: any): RegisterProductRow | null {
  const pcode = String(raw?.pcode ?? "").trim();
  const fpname = String(raw?.fpname ?? "").trim();
  if (!pcode || !fpname) return null;
  return {
    pcode,
    fpname,
    sname: raw?.sname ? String(raw.sname) : null,
    hlevel1: raw?.hlevel1 ? String(raw.hlevel1) : null,
    fdesc: raw?.fdesc ? String(raw.fdesc) : null,
    regcode: raw?.regcode ? String(raw.regcode) : null,
    expdate: raw?.expdate ? String(raw.expdate) : null,
  };
}

/** Page through the full PubCRIS product resource (read-only, public CKAN). */
// deno-lint-ignore no-explicit-any
async function fetchRegisterSnapshot(): Promise<any[]> {
  const limit = 5000;
  // deno-lint-ignore no-explicit-any
  const records: any[] = [];
  let offset = 0;
  for (;;) {
    const url = new URL(APVMA_DATASTORE_URL);
    url.searchParams.set("resource_id", APVMA_RESOURCES.product);
    url.searchParams.set("limit", String(limit));
    url.searchParams.set("offset", String(offset));
    url.searchParams.set("sort", "_id asc");
    url.searchParams.set(
      "fields",
      "_id,pcode,fpname,sname,hlevel1,fdesc,regcode,expdate",
    );
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error(`PubCRIS snapshot HTTP ${res.status} at offset ${offset}`);
    const payload = await res.json();
    const page = payload?.result?.records;
    if (payload?.success !== true || !Array.isArray(page)) {
      throw new Error(`PubCRIS snapshot malformed payload at offset ${offset}`);
    }
    records.push(...page);
    const total = Number(payload?.result?.total ?? 0);
    offset += page.length;
    console.error(`snapshot: ${records.length}/${total}`);
    if (page.length < limit || (total > 0 && offset >= total)) break;
  }
  return records;
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);

  const manifest = JSON.parse(
    await Deno.readTextFile(args.manifest),
  ) as AwriSeedManifest;

  // deno-lint-ignore no-explicit-any
  let rawRecords: any[];
  let snapshotOrigin: string;
  if (args.snapshot) {
    rawRecords = JSON.parse(await Deno.readTextFile(args.snapshot));
    snapshotOrigin = `file:${args.snapshot}`;
  } else {
    rawRecords = await fetchRegisterSnapshot();
    snapshotOrigin = "live CKAN datastore (data.gov.au)";
  }

  const rows: RegisterProductRow[] = [];
  for (const raw of rawRecords) {
    const row = toRegisterRow(raw);
    if (row) rows.push(row);
  }
  const regcodeCounts: Record<string, number> = {};
  for (const row of rows) {
    const code = (row.regcode ?? "«null»").trim() || "«blank»";
    regcodeCounts[code] = (regcodeCounts[code] ?? 0) + 1;
  }

  const result = runSeedDryRun(manifest, rows);

  const artifact = {
    generated_at: new Date().toISOString(),
    register_snapshot: {
      origin: snapshotOrigin,
      resource_id: APVMA_RESOURCES.product,
      total_rows: rows.length,
      regcode_counts: regcodeCounts,
    },
    ...result,
  };
  await Deno.writeTextFile(args.out, JSON.stringify(artifact, null, 1) + "\n");
  await Deno.writeTextFile(args.sqlOut, buildComparisonSql(result));

  console.log(formatSeedReport(result, "(see deno test ingestion/)"));
  console.log("");
  console.log(`dry-run artifact: ${args.out}`);
  console.log(`comparison SQL:   ${args.sqlOut}`);
}

if (import.meta.main) {
  await main();
}
