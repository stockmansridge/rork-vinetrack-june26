// Controlled, deterministic Chemical Search V2 viticulture-rate backfill.
//
// Plan mode is the default and never writes. --execute updates only an existing
// eligible Master row whose newly parsed rates differ. No AI or general-web
// discovery is used: identity, label resolution and parsing all run through the
// existing APVMA PubCRIS/eLabels adapter.

import { apvmaAdapter } from "../supabase/functions/chemical-info-lookup/ingestion/apvma.ts";
import type { DiscoveryResult } from "../supabase/functions/chemical-info-lookup/ingestion/contract.ts";
import {
  deriveViticultureRates,
  isGrapevineCrop,
  type ViticultureRates,
} from "../supabase/functions/chemical-info-lookup/grapevine_label.ts";

const AWRI_REFERENCE =
  "https://www.awri.com.au/wp-content/uploads/agrochemical_booklet.pdf";
const EMPTY_RATES: ViticultureRates = { per_hectare: [], per_100_litres: [] };

type Json = Record<string, unknown>;

export interface CohortRow {
  id: string;
  registration_country: string;
  registration_scheme: string;
  registration_number: string;
  registered_product_name: string;
  review_status: string;
  source_kind: string;
  verification_status: string;
  verification_sources: Json[];
  registered_uses?: Json[];
  viticulture_rates?: ViticultureRates;
}

export type BackfillClassification =
  | "success"
  | "no_vineyard_direction"
  | "vineyard_direction_no_usable_rate"
  | "label_unavailable"
  | "parser_failure"
  | "source_unavailable";

export interface BackfillRecord {
  id: string;
  registration_number: string;
  registered_product_name: string;
  classification: BackfillClassification;
  label_url: string | null;
  rates: ViticultureRates;
  write: "planned" | "updated" | "unchanged" | "not_applicable";
  detail: string;
}

export interface BackfillReport {
  generated_at: string;
  execute: boolean;
  totals: {
    v2_eligible_products: number;
    labels_successfully_resolved: number;
    products_with_vineyard_evidence: number;
    products_with_per_hectare_rate: number;
    products_with_per_100_litres_rate: number;
    products_with_both_bases: number;
    vineyard_evidence_without_parsed_rate: number;
    no_vineyard_direction_found: number;
    label_unavailable: number;
    parser_failure: number;
    source_unavailable: number;
    updated: number;
    unchanged: number;
  };
  records: BackfillRecord[];
}

/** Mirrors public.master_chemical_is_v2_eligible() in SQL 238. */
export function isV2Eligible(row: CohortRow): boolean {
  if (row.registration_country !== "AU" || row.registration_scheme !== "apvma") return false;
  if (row.review_status === "approved") return true;
  if (
    row.review_status !== "candidate" ||
    row.source_kind !== "official_register" ||
    !["verified", "partially_verified"].includes(row.verification_status)
  ) return false;
  const sources = Array.isArray(row.verification_sources) ? row.verification_sources : [];
  const hasRegister = sources.some((source) => source.kind === "official_register");
  const hasAwri = sources.some((source) =>
    source.kind === "viticulture_reference" && source.reference === AWRI_REFERENCE
  );
  return hasRegister && hasAwri;
}

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value as Json).sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => `${JSON.stringify(key)}:${stable(item)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function ratesEqual(a: ViticultureRates | undefined, b: ViticultureRates): boolean {
  return stable(a ?? EMPTY_RATES) === stable(b);
}

/** Classify one authoritative adapter result without turning failures into absence. */
export function classifyResult(row: CohortRow, result: DiscoveryResult): BackfillRecord {
  const base = {
    id: row.id,
    registration_number: row.registration_number,
    registered_product_name: row.registered_product_name,
  };
  if (result.outcome === "source_unavailable") {
    return { ...base, classification: "source_unavailable", label_url: null, rates: EMPTY_RATES,
      write: "not_applicable", detail: result.error_category ?? "APVMA source unavailable" };
  }
  const registration = result.registration;
  if (
    result.outcome !== "resolved" || !registration ||
    registration.registration_number !== row.registration_number
  ) {
    return { ...base, classification: "source_unavailable", label_url: null, rates: EMPTY_RATES,
      write: "not_applicable", detail: `registration did not resolve exactly (${result.outcome})` };
  }
  const labelUrl = registration.label_document?.url ?? null;
  if (!registration.label_document?.document) {
    return { ...base, classification: "label_unavailable", label_url: labelUrl, rates: EMPTY_RATES,
      write: "not_applicable", detail: labelUrl ? "label URL resolved but PDF unavailable" : "authoritative label unavailable" };
  }
  const evidence = registration.label_evidence;
  if (!evidence?.document) {
    return { ...base, classification: "parser_failure", label_url: labelUrl, rates: EMPTY_RATES,
      write: "not_applicable", detail: "label PDF resolved but deterministic text extraction did not complete" };
  }
  const claims = evidence.claims ?? [];
  const vineyardClaims = claims.filter((claim) => isGrapevineCrop(claim.crop));
  if (!vineyardClaims.length) {
    return { ...base, classification: "no_vineyard_direction", label_url: labelUrl, rates: EMPTY_RATES,
      write: "not_applicable", detail: "authoritative label parsed; no vineyard/grapevine direction found" };
  }
  const rates = deriveViticultureRates(vineyardClaims);
  if (!rates.per_hectare.length && !rates.per_100_litres.length) {
    return { ...base, classification: "vineyard_direction_no_usable_rate", label_url: labelUrl,
      rates, write: "not_applicable", detail: "vineyard direction found; no usable structured rate parsed" };
  }
  return { ...base, classification: "success", label_url: labelUrl, rates,
    write: ratesEqual(row.viticulture_rates, rates) ? "unchanged" : "planned",
    detail: "authoritative vineyard rate parsed" };
}

function reportFor(records: BackfillRecord[], execute: boolean): BackfillReport {
  const count = (predicate: (record: BackfillRecord) => boolean): number => records.filter(predicate).length;
  return {
    generated_at: new Date().toISOString(),
    execute,
    totals: {
      v2_eligible_products: records.length,
      labels_successfully_resolved: count((r) => r.label_url !== null),
      products_with_vineyard_evidence: records.length,
      products_with_per_hectare_rate: count((r) => r.rates.per_hectare.length > 0),
      products_with_per_100_litres_rate: count((r) => r.rates.per_100_litres.length > 0),
      products_with_both_bases: count((r) =>
        r.rates.per_hectare.length > 0 && r.rates.per_100_litres.length > 0
      ),
      vineyard_evidence_without_parsed_rate: count((r) =>
        r.classification === "vineyard_direction_no_usable_rate"
      ),
      no_vineyard_direction_found: count((r) => r.classification === "no_vineyard_direction"),
      label_unavailable: count((r) => r.classification === "label_unavailable"),
      parser_failure: count((r) => r.classification === "parser_failure"),
      source_unavailable: count((r) => r.classification === "source_unavailable"),
      updated: count((r) => r.write === "updated"),
      unchanged: count((r) => r.write === "unchanged"),
    },
    records,
  };
}

async function rest<T>(baseUrl: string, key: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${baseUrl}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
  if (!response.ok) throw new Error(`Supabase REST ${response.status}: ${await response.text()}`);
  if (response.status === 204) return undefined as T;
  return await response.json() as T;
}

async function loadCohort(baseUrl: string, key: string, inputPath: string | null): Promise<CohortRow[]> {
  const rows = inputPath
    ? JSON.parse(await Deno.readTextFile(inputPath)) as CohortRow[]
    : await rest<CohortRow[]>(baseUrl, key,
      "master_chemicals?select=id,registration_country,registration_scheme,registration_number," +
      "registered_product_name,review_status,source_kind,verification_status,verification_sources," +
      "registered_uses&limit=1000");
  const eligible = rows.filter((row) =>
    row.registration_country === "AU" && row.registration_scheme === "apvma" && isV2Eligible(row)
  );
  const identities = new Set(eligible.map((row) => row.registration_number));
  if (identities.size !== eligible.length) throw new Error("duplicate APVMA identity in V2 cohort");
  return eligible.sort((a, b) => a.registration_number.localeCompare(b.registration_number));
}

async function updateRates(baseUrl: string, key: string, record: BackfillRecord): Promise<void> {
  await rest<void>(baseUrl, key, `master_chemicals?id=eq.${encodeURIComponent(record.id)}`, {
    method: "PATCH",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({ viticulture_rates: record.rates }),
  });
}

function arg(name: string): string | null {
  const index = Deno.args.indexOf(name);
  return index >= 0 ? Deno.args[index + 1] ?? null : null;
}

async function main(): Promise<void> {
  const execute = Deno.args.includes("--execute");
  const baseUrl = (Deno.env.get("V2_SUPABASE_URL") ?? "").replace(/\/$/, "");
  const key = Deno.env.get("V2_SERVICE_ROLE_KEY") ?? "";
  const input = arg("--cohort");
  const reportPath = arg("--report") ?? ".rork/tmp/viticulture-rate-backfill-report.json";
  if ((!baseUrl || !key) && !input) throw new Error("V2_SUPABASE_URL and V2_SERVICE_ROLE_KEY are required without --cohort");
  if (execute && (!baseUrl || !key)) throw new Error("database credentials are required for --execute");

  const cohort = await loadCohort(baseUrl, key, input);
  const concurrency = Math.max(1, Math.min(12, Number.parseInt(arg("--concurrency") ?? "6", 10) || 6));
  const records: BackfillRecord[] = new Array(cohort.length);
  let cursor = 0;
  let persistReport: Promise<void> = Promise.resolve();
  const worker = async (): Promise<void> => {
    for (;;) {
      const index = cursor++;
      if (index >= cohort.length) return;
      const row = cohort[index];
      let record: BackfillRecord;
      try {
        const result = await apvmaAdapter.discover(
          row.registered_product_name,
          row.registration_number,
          { fetchFn: fetch, now: () => new Date() },
        );
        record = classifyResult(row, result);
        if (execute && record.classification === "success" && record.write === "planned") {
          await updateRates(baseUrl, key, record);
          record.write = "updated";
        }
      } catch (error) {
        record = {
          id: row.id,
          registration_number: row.registration_number,
          registered_product_name: row.registered_product_name,
          classification: "parser_failure",
          label_url: null,
          rates: EMPTY_RATES,
          write: "not_applicable",
          detail: error instanceof Error ? error.message : String(error),
        };
      }
      records[index] = record;
      console.log(`${row.registration_number}\t${record.classification}\t${record.write}\t${row.registered_product_name}`);
      persistReport = persistReport.then(() =>
        Deno.writeTextFile(
          reportPath,
          JSON.stringify(reportFor(records.filter(Boolean), execute), null, 2),
        )
      );
      await persistReport;
    }
  };
  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  const report = reportFor(records, execute);
  await Deno.writeTextFile(reportPath, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report.totals, null, 2));
  if (!execute) console.log("PLAN ONLY — no Master Chemical rows were written.");
}

if (import.meta.main) await main();
