// Stage 5F — audit runner for the Stage 5E deterministic matches. READ-ONLY.
//
//   cd supabase/functions/chemical-info-lookup/ingestion
//   deno run --allow-net --allow-read --allow-write seeds/run_awri_audit.ts \
//     [--match seeds/awri_dogbook_2026_27.match.json] \
//     [--dryrun seeds/awri_dogbook_2026_27.dryrun.json] \
//     [--manifest seeds/awri_dogbook_2026_27.json] \
//     [--out seeds/awri_dogbook_2026_27.audit.json] \
//     [--products <file>] [--prodcon <file>] [--constit <file>] \
//     [--extract-date 2026-06-25]
//
// Takes ONLY the deterministic_match resolutions from the Stage 5E artifact,
// re-fetches their register rows and constituents LIVE from the public CKAN
// datastore (data.gov.au), and audits each one with ../seed_awri_audit.ts.
// Also composes the register-provenance reconciliation the Stage 5F report
// requires: what the PubCRIS extract actually contains (regcode R products
// vs regcode A approved actives), that no machine-readable archived register
// exists, and what that means for the 38 no_apvma_match names.
//
// ZERO writes to any database. No Supabase client, no apply step, no state
// file. The only output is a local JSON artifact plus a console report.
// The 162 probable_manual_review items are NOT touched.

import {
  auditDeterministicMatches,
  crossCheckNamesAgainstActiveNames,
  formatAuditReport,
  type AuditItem,
} from "../seed_awri_audit.ts";
import type { RegisterActive, Stage5EResolution } from "../seed_awri_match.ts";
import type { AwriSeedManifest, RegisterProductRow, SeedDryRunResult } from "../seed_awri.ts";
import { APVMA_DATASTORE_URL, APVMA_RESOURCES } from "../apvma.ts";

interface Args {
  match: string;
  dryrun: string;
  manifest: string;
  out: string;
  products: string | null;
  prodcon: string | null;
  constit: string | null;
  extractDate: string | null;
}

function parseArgs(argv: string[]): Args {
  const get = (flag: string): string | null => {
    const i = argv.indexOf(flag);
    return i >= 0 && argv[i + 1] ? argv[i + 1] : null;
  };
  return {
    match: get("--match") ?? "seeds/awri_dogbook_2026_27.match.json",
    dryrun: get("--dryrun") ?? "seeds/awri_dogbook_2026_27.dryrun.json",
    manifest: get("--manifest") ?? "seeds/awri_dogbook_2026_27.json",
    out: get("--out") ?? "seeds/awri_dogbook_2026_27.audit.json",
    products: get("--products"),
    prodcon: get("--prodcon"),
    constit: get("--constit"),
    extractDate: get("--extract-date"),
  };
}

// deno-lint-ignore no-explicit-any
type RawRecord = Record<string, any>;

const PUBCRIS_PACKAGE_URL =
  "https://data.gov.au/data/api/3/action/package_show?id=0de37904-43e0-4814-b21b-5b64fafefe6f";

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

async function datastoreTotal(filters: Record<string, string>): Promise<number | null> {
  try {
    const url = new URL(APVMA_DATASTORE_URL);
    url.searchParams.set("resource_id", APVMA_RESOURCES.product);
    url.searchParams.set("filters", JSON.stringify(filters));
    url.searchParams.set("limit", "1");
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const payload = await res.json();
    const total = Number(payload?.result?.total);
    return Number.isFinite(total) ? total : null;
  } catch {
    return null;
  }
}

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

async function readJsonIfGiven(path: string | null): Promise<RawRecord[] | null> {
  if (!path) return null;
  return JSON.parse(await Deno.readTextFile(path)) as RawRecord[];
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

interface PackageInfo {
  title: string | null;
  notesExcerpt: string | null;
  resources: { name: string; last_modified: string | null }[];
  productLastModified: string | null;
}

async function fetchPackageInfo(): Promise<PackageInfo | null> {
  try {
    const res = await fetch(PUBCRIS_PACKAGE_URL, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const payload = await res.json();
    const result = payload?.result;
    if (!result) return null;
    const resources = Array.isArray(result.resources)
      ? result.resources.map((r: RawRecord) => ({
        name: String(r?.name ?? ""),
        last_modified: r?.last_modified ? String(r.last_modified) : null,
      }))
      : [];
    const product = resources.find((r: { name: string }) => r.name === "product.csv");
    return {
      title: result.title ? String(result.title) : null,
      notesExcerpt: result.notes ? String(result.notes).slice(0, 300) : null,
      resources,
      productLastModified: product?.last_modified ?? null,
    };
  } catch {
    return null;
  }
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);

  const matchArtifact = JSON.parse(await Deno.readTextFile(args.match)) as {
    resolutions: Stage5EResolution[];
  };
  const dryrun = JSON.parse(await Deno.readTextFile(args.dryrun)) as SeedDryRunResult;
  const manifest = JSON.parse(await Deno.readTextFile(args.manifest)) as AwriSeedManifest;

  // ---- Scope: ONLY the deterministic matches -------------------------------
  const deterministic = matchArtifact.resolutions.filter(
    (r) => r.match_class === "deterministic_match",
  );
  const noMatchNames = matchArtifact.resolutions
    .filter((r) => r.match_class === "no_apvma_match")
    .map((r) => r.awri_product_name);
  const detPcodes = Array.from(
    new Set(
      deterministic
        .map((r) => r.matched?.registration_number ?? "")
        .filter(Boolean),
    ),
  ).sort((a, b) => (Number(a) || 0) - (Number(b) || 0));

  const manifestActivesByName = new Map<string, string[]>();
  for (const entry of manifest.entries) {
    manifestActivesByName.set(entry.awri_product_name, entry.active_constituents ?? []);
  }
  const existingIdentities = new Set<string>([
    ...dryrun.candidate_identities,
    ...dryrun.conflict_identities,
  ]);

  // ---- Register provenance (reconciliation) --------------------------------
  const pkg = await fetchPackageInfo();
  const extractDate = args.extractDate ??
    (pkg?.productLastModified ? pkg.productLastModified.slice(0, 10) : "2026-06-25");

  const totalR = await datastoreTotal({ regcode: "R" });
  const totalA = await datastoreTotal({ regcode: "A" });

  // ---- Live register rows for the audited registrations --------------------
  const productFile = await readJsonIfGiven(args.products);
  const liveRowsByPcode = new Map<string, RegisterProductRow>();
  if (productFile) {
    const wanted = new Set(detPcodes);
    for (const raw of productFile) {
      const row = toRegisterRow(raw);
      if (row && wanted.has(row.pcode) && !liveRowsByPcode.has(row.pcode)) {
        liveRowsByPcode.set(row.pcode, row);
      }
    }
  } else {
    for (const batch of chunk(detPcodes, 150)) {
      const rows = await datastore({
        resource_id: APVMA_RESOURCES.product,
        filters: JSON.stringify({ pcode: batch }),
        limit: "5000",
      });
      for (const raw of rows) {
        const row = toRegisterRow(raw);
        if (row && !liveRowsByPcode.has(row.pcode)) liveRowsByPcode.set(row.pcode, row);
      }
    }
  }

  // ---- Live constituents for the audited registrations ---------------------
  const prodconRows: RawRecord[] = (await readJsonIfGiven(args.prodcon)) ?? [];
  const havePcodes = new Set(prodconRows.map((r) => String(r?.pcode ?? "").trim()));
  const missingPcodes = detPcodes.filter((p) => !havePcodes.has(p));
  for (const batch of chunk(missingPcodes, 150)) {
    prodconRows.push(...await datastore({
      resource_id: APVMA_RESOURCES.productConstituents,
      filters: JSON.stringify({ pcode: batch }),
      limit: "5000",
    }));
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
    constitRows.push(...await datastore({
      resource_id: APVMA_RESOURCES.constituentNames,
      filters: JSON.stringify({ ccode: batch }),
      limit: "5000",
    }));
  }

  const cnameByCcode = new Map<string, string>();
  for (const row of constitRows) {
    if (row?.ccode && row?.cname) cnameByCcode.set(String(row.ccode), String(row.cname));
  }
  const liveActivesByPcode = new Map<string, RegisterActive[]>();
  const detPcodeSet = new Set(detPcodes);
  for (const row of prodconRows) {
    if (String(row?.ctype ?? "").trim().toUpperCase() !== "A") continue;
    const pcode = String(row?.pcode ?? "").trim();
    if (!pcode || !detPcodeSet.has(pcode)) continue;
    const parsed = Number.parseFloat(String(row?.camount ?? ""));
    const amount = Number.isFinite(parsed) && parsed > 0 ? parsed : null;
    const active: RegisterActive = {
      name: cnameByCcode.get(String(row?.ccode ?? "")) ?? "",
      amount,
    };
    const bucket = liveActivesByPcode.get(pcode);
    if (bucket) bucket.push(active);
    else liveActivesByPcode.set(pcode, [active]);
  }

  // ---- Approved-active (regcode A) cross-check for the 38 no-match names ---
  let aRows: { pcode: string; fpname: string }[] = [];
  try {
    const limit = 5000;
    let offset = 0;
    for (;;) {
      const url = new URL(APVMA_DATASTORE_URL);
      url.searchParams.set("resource_id", APVMA_RESOURCES.product);
      url.searchParams.set("filters", JSON.stringify({ regcode: "A" }));
      url.searchParams.set("fields", "pcode,fpname");
      url.searchParams.set("limit", String(limit));
      url.searchParams.set("offset", String(offset));
      const res = await fetch(url, { headers: { Accept: "application/json" } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const payload = await res.json();
      const page = payload?.result?.records;
      if (payload?.success !== true || !Array.isArray(page)) throw new Error("malformed");
      aRows.push(
        ...page.map((r: RawRecord) => ({
          pcode: String(r?.pcode ?? ""),
          fpname: String(r?.fpname ?? ""),
        })),
      );
      offset += page.length;
      if (page.length < limit) break;
    }
  } catch {
    aRows = [];
  }
  const activeNameCrossCheck = crossCheckNamesAgainstActiveNames(
    noMatchNames,
    aRows.map((r) => r.fpname),
  );
  const crossCheckHits = activeNameCrossCheck.filter((c) => c.hits.length > 0);

  // ---- The audit (pure) -----------------------------------------------------
  const audit = auditDeterministicMatches({
    deterministic,
    manifestActivesByName,
    liveRowsByPcode,
    liveActivesByPcode,
    existingIdentities,
    extractDate,
  });

  const artifact = {
    generated_at: new Date().toISOString(),
    stage: "5F — audit of Stage 5E deterministic matches (review only, no writes)",
    scope: {
      audited: "181 deterministic_match resolutions from the Stage 5E artifact",
      probable_manual_review: "NOT touched (162 items remain pending)",
      apply_step: "none — this stage recommends, it never imports",
    },
    register_provenance: {
      dataset_title: pkg?.title ?? null,
      dataset_update_claim: pkg?.notesExcerpt ?? null,
      product_extract_last_modified: pkg?.productLastModified ?? null,
      extract_date_used_for_lapse_test: extractDate,
      expiry_semantics: "the extract predates the 30 June renewal rollover, so " +
        "'expires 30/06/2026' is the normal current-registration value; lapsed " +
        "means expiry BEFORE the extract date, removed means absent from the live register",
      resources: pkg?.resources ?? [],
      regcode_semantics: {
        R_rows_total_live: totalR,
        A_rows_total_live: totalA,
        a_row_meaning: "regcode A rows are approved ACTIVE CONSTITUENTS " +
          "(hlevel1 = 'ACTIVE CONSTITUENT') — active-ingredient approvals, NOT " +
          "archived products. Earlier Stage 5 references to 'A rows' meant these; " +
          "they are structurally excluded from product matching.",
      },
      archived_register: {
        machine_readable: false,
        bulk_dataset: "none — no resource in the PubCRIS dataset carries archived " +
          "or cancelled products; the extract holds regcode R and regcode A rows only",
        portal: "portal.apvma.gov.au/pubcris offers status filters " +
          "REGISTERED_APPROVED / CANCELLED / SUSPENDED / ARCHIVED — interactive " +
          "per-product HTML only, no API and no bulk export",
        portal_probe: "2026-08-20: scripted POSTs to the Liferay search action " +
          "(fresh session cookie + p_auth token) returned the search form, not a " +
          "results table — archived records are not scriptable from this sandbox",
        no_match_checked_against_archived: false,
        implication_for_no_match: `the ${noMatchNames.length} no_apvma_match names ` +
          "were classified against the CURRENT register only (extract " +
          `${extractDate}); checking them against archived/cancelled records is a ` +
          "manual task in the interactive portal",
      },
      no_match_active_name_crosscheck: {
        names_checked: noMatchNames.length,
        names_with_active_constituent_name_hits: crossCheckHits.length,
        meaning: "a hit only means the product name CONTAINS an approved active's " +
          "name — an A row is never a product registration and can never resolve " +
          "a product match",
        hits: crossCheckHits,
      },
    },
    ...audit,
  };
  await Deno.writeTextFile(args.out, JSON.stringify(artifact, null, 1) + "\n");

  // ---- Console report --------------------------------------------------------
  console.log(formatAuditReport(audit, "(see deno test ingestion/)"));
  console.log("");
  console.log(`register extract: ${extractDate} | live R rows: ${totalR} | live A rows: ${totalA}`);
  console.log(
    `no-match names vs approved-active names: ${crossCheckHits.length}/${noMatchNames.length} contain an active's name (informational only)`,
  );
  console.log("");
  const line = (i: { awri_product_name: string; registration_number: string; strength_score: number; tier: string | null; decision: string }): string =>
    `  [${String(i.strength_score).padStart(3)}] ${i.awri_product_name} -> ${i.registration_number} (${i.tier}) ${i.decision === "reject" ? "REJECTED" : ""}`;
  console.log("strongest 10:");
  for (const i of audit.strongest) console.log(line(i));
  console.log("weakest 10:");
  for (const i of audit.weakest) console.log(line(i));
  const rejected = audit.items.filter((i: AuditItem) => i.decision === "reject");
  if (rejected.length) {
    console.log("");
    console.log("rejected:");
    for (const i of rejected) {
      console.log(`  ${i.awri_product_name} -> ${i.apvma_registration_number}: ${i.reject_reasons.join("; ")}`);
    }
  }
  console.log("");
  console.log(`audit artifact: ${args.out}`);
}

if (import.meta.main) {
  await main();
}
