// Stage 5E — remaining-unresolved AWRI names: classification DRY RUN runner.
//
//   cd supabase/functions/chemical-info-lookup/ingestion
//   deno run --allow-net --allow-read --allow-write seeds/run_awri_match.ts \
//     [--manifest seeds/awri_dogbook_2026_27.json] \
//     [--dryrun seeds/awri_dogbook_2026_27.dryrun.json] \
//     [--out seeds/awri_dogbook_2026_27.match.json] \
//     [--products /tmp/pubcris_products.json] \
//     [--prodcon /tmp/stage5e_prodcon.json] \
//     [--constit /tmp/stage5e_constit.json]
//
// Reads the Stage 5A dry-run artifact, takes ONLY the unresolved names, and
// classifies each against the current APVMA PubCRIS register (public
// data.gov.au CKAN datastore, read-only) with the Stage 5E discipline in
// ../seed_awri_match.ts. Register product rows and the constituent data for
// shortlisted rows come from snapshot files when provided; anything missing
// is fetched read-only from the datastore. Output is a local JSON artifact
// plus a console report.
//
// ZERO writes to any database. There is no Supabase client in this runner,
// no apply step, and no state file — classification only.

import {
  buildRegisterIndex,
  classifyUnresolved,
  collectCandidatePcodes,
  formatMatchReport,
  type RegisterActive,
  type Stage5EResolution,
  type UnmatchedInput,
} from "../seed_awri_match.ts";
import type { AwriSeedManifest, RegisterProductRow, SeedDryRunResult } from "../seed_awri.ts";
import { APVMA_DATASTORE_URL, APVMA_RESOURCES } from "../apvma.ts";

interface Args {
  manifest: string;
  dryrun: string;
  out: string;
  products: string | null;
  prodcon: string | null;
  constit: string | null;
}

function parseArgs(argv: string[]): Args {
  const get = (flag: string): string | null => {
    const i = argv.indexOf(flag);
    return i >= 0 && argv[i + 1] ? argv[i + 1] : null;
  };
  return {
    manifest: get("--manifest") ?? "seeds/awri_dogbook_2026_27.json",
    dryrun: get("--dryrun") ?? "seeds/awri_dogbook_2026_27.dryrun.json",
    out: get("--out") ?? "seeds/awri_dogbook_2026_27.match.json",
    products: get("--products"),
    prodcon: get("--prodcon"),
    constit: get("--constit"),
  };
}

// deno-lint-ignore no-explicit-any
type RawRecord = Record<string, any>;

function toRegisterRow(raw: RawRecord): RegisterProductRow | null {
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

async function datastore(params: Record<string, string>): Promise<RawRecord[]> {
  const url = new URL(APVMA_DATASTORE_URL);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`PubCRIS datastore HTTP ${res.status}`);
  const payload = await res.json();
  if (payload?.success !== true || !Array.isArray(payload?.result?.records)) {
    throw new Error("PubCRIS datastore malformed payload");
  }
  return payload.result.records as RawRecord[];
}

/** Page through the full product resource (read-only, public CKAN). */
async function fetchProductSnapshot(): Promise<RawRecord[]> {
  const limit = 5000;
  const records: RawRecord[] = [];
  let offset = 0;
  for (;;) {
    const url = new URL(APVMA_DATASTORE_URL);
    url.searchParams.set("resource_id", APVMA_RESOURCES.product);
    url.searchParams.set("limit", String(limit));
    url.searchParams.set("offset", String(offset));
    url.searchParams.set("sort", "_id asc");
    url.searchParams.set("fields", "_id,pcode,fpname,sname,hlevel1,fdesc,regcode,expdate");
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
    console.error(`products: ${records.length}/${total}`);
    if (page.length < limit || (total > 0 && offset >= total)) break;
  }
  return records;
}

async function readJsonIfGiven(path: string | null): Promise<RawRecord[] | null> {
  if (!path) return null;
  return JSON.parse(await Deno.readTextFile(path)) as RawRecord[];
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);

  const manifest = JSON.parse(await Deno.readTextFile(args.manifest)) as AwriSeedManifest;
  const dryrun = JSON.parse(await Deno.readTextFile(args.dryrun)) as SeedDryRunResult;

  // ---- Input: ONLY the Stage 5A unresolved names --------------------------
  const unresolved: UnmatchedInput[] = dryrun.resolutions
    .filter((r) => r.kind === "unresolved_no_match" || r.kind === "unresolved_ambiguous")
    .map((r) => ({
      awri_product_name: r.awri_product_name,
      expansion: r.expansion,
      sections: r.sections,
    }));
  const existingIdentities = new Set<string>([
    ...dryrun.candidate_identities,
    ...dryrun.conflict_identities,
  ]);

  // ---- Register product rows ----------------------------------------------
  let rawProducts = await readJsonIfGiven(args.products);
  let productsOrigin: string;
  if (rawProducts) {
    productsOrigin = `file:${args.products}`;
  } else {
    rawProducts = await fetchProductSnapshot();
    productsOrigin = "live CKAN datastore (data.gov.au)";
  }
  const registerRows: RegisterProductRow[] = [];
  for (const raw of rawProducts) {
    const row = toRegisterRow(raw);
    if (row) registerRows.push(row);
  }

  // ---- Constituents for every shortlisted row ------------------------------
  const index = buildRegisterIndex(registerRows);
  const wantedPcodes = collectCandidatePcodes(
    unresolved.map((u) => u.awri_product_name),
    index,
  );

  const prodconRows: RawRecord[] = (await readJsonIfGiven(args.prodcon)) ?? [];
  const havePcodes = new Set(prodconRows.map((r) => String(r?.pcode ?? "").trim()));
  const missingPcodes = wantedPcodes.filter((p) => !havePcodes.has(p));
  let fetchedProdcon = 0;
  for (const batch of chunk(missingPcodes, 150)) {
    const rows = await datastore({
      resource_id: APVMA_RESOURCES.productConstituents,
      filters: JSON.stringify({ pcode: batch }),
      limit: "5000",
    });
    prodconRows.push(...rows);
    fetchedProdcon += rows.length;
  }

  const constitRows: RawRecord[] = (await readJsonIfGiven(args.constit)) ?? [];
  const haveCcodes = new Set(constitRows.map((r) => String(r?.ccode ?? "")));
  const wantedCcodes = Array.from(
    new Set(
      prodconRows
        .filter((r) => String(r?.ctype ?? "").trim().toUpperCase() === "A" && r?.ccode)
        .map((r) => String(r.ccode)),
    ),
  ).filter((c) => !haveCcodes.has(c));
  for (const batch of chunk(wantedCcodes, 300)) {
    const rows = await datastore({
      resource_id: APVMA_RESOURCES.constituentNames,
      filters: JSON.stringify({ ccode: batch }),
      limit: "5000",
    });
    constitRows.push(...rows);
  }

  const cnameByCcode = new Map<string, string>();
  for (const row of constitRows) {
    if (row?.ccode && row?.cname) cnameByCcode.set(String(row.ccode), String(row.cname));
  }
  const activesByPcode = new Map<string, RegisterActive[]>();
  for (const row of prodconRows) {
    if (String(row?.ctype ?? "").trim().toUpperCase() !== "A") continue;
    const pcode = String(row?.pcode ?? "").trim();
    if (!pcode) continue;
    const parsed = Number.parseFloat(String(row?.camount ?? ""));
    const amount = Number.isFinite(parsed) && parsed > 0 ? parsed : null;
    const active: RegisterActive = {
      name: cnameByCcode.get(String(row?.ccode ?? "")) ?? "",
      amount,
    };
    const bucket = activesByPcode.get(pcode);
    if (bucket) bucket.push(active);
    else activesByPcode.set(pcode, [active]);
  }

  // ---- Classification (pure) ------------------------------------------------
  const result = classifyUnresolved({
    manifest,
    unresolved,
    registerRows,
    activesByPcode,
    existingIdentities,
  });

  const artifact = {
    generated_at: new Date().toISOString(),
    stage: "5E — remaining AWRI names, classification only (no writes)",
    register_snapshot: {
      products_origin: productsOrigin,
      product_resource_id: APVMA_RESOURCES.product,
      product_rows: registerRows.length,
      shortlisted_pcodes: wantedPcodes.length,
      prodcon_rows: prodconRows.length,
      prodcon_rows_fetched_live: fetchedProdcon,
      constituent_names: cnameByCcode.size,
      archived_register:
        "not machine-readable — APVMA publishes no archived-product dataset; " +
        "classification is against the CURRENT register only (regcode R)",
    },
    ...result,
  };
  await Deno.writeTextFile(args.out, JSON.stringify(artifact, null, 1) + "\n");

  console.log(formatMatchReport(result, "(see deno test ingestion/)"));
  console.log("");

  const byClass = (cls: Stage5EResolution["match_class"]): Stage5EResolution[] =>
    result.resolutions.filter((r) => r.match_class === cls);
  const show = (r: Stage5EResolution): string =>
    r.matched
      ? `${r.awri_product_name} -> ${r.matched.registration_number} ${r.matched.registered_product_name} [${r.tier}]`
      : r.awri_product_name;
  console.log("examples — deterministic:");
  for (const r of byClass("deterministic_match").slice(0, 5)) console.log(`  ${show(r)}`);
  console.log("examples — probable/manual review:");
  for (const r of byClass("probable_manual_review").slice(0, 5)) console.log(`  ${show(r)}`);
  console.log("examples — ambiguous:");
  for (const r of byClass("ambiguous").slice(0, 3)) {
    console.log(
      `  ${r.awri_product_name} -> ${r.ambiguous_rows.map((m) => m.registration_number).join(" | ")}`,
    );
  }
  console.log("examples — no match:");
  for (const r of byClass("no_apvma_match").slice(0, 5)) console.log(`  ${r.awri_product_name}`);
  console.log("");
  console.log(`match artifact: ${args.out}`);
}

if (import.meta.main) {
  await main();
}
