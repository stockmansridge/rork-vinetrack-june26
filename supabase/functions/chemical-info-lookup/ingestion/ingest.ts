// Ingestion orchestration — turns an unknown commercial chemical into a
// structured, deduplicated Master CANDIDATE (Stage 3 §§B–D, F, J).
//
// Lifecycle (docs/master-chemical-ingestion.md):
//   grower search → same-country approved-master lookup → authoritative
//   discovery (registry-selected adapter) → structured candidate →
//   registration-identity dedupe → candidate enqueue/refresh → admin review.
//
// Non-negotiables enforced here:
//   * Candidates only. `review_status` is the literal type "candidate"; this
//     module cannot mint approved rows (and sql/199's CHECK backs that up).
//   * Registration identity is the ONLY dedupe key; name spelling never
//     creates a second row for the same registration.
//   * AI evidence never overwrites an authoritative candidate.
//   * Source disagreements become structured verification_conflicts and the
//     evidence state "conflict" — never a silent winner.
//   * Facts an authoritative source does not provide stay unresolved.

// deno-lint-ignore-file no-explicit-any

import { normaliseActiveName } from "./activity_groups.ts";
import type {
  AdapterDeps,
  CandidateRowPayload,
  DiscoveryResult,
  MasterOps,
  MasterRow,
  ResolvedRegistration,
  WireConflict,
  WireDataSource,
} from "./contract.ts";
import { identityKey } from "./contract.ts";
import { adapterFor } from "./registry.ts";
import {
  CANDIDATE_EVIDENCE_MAX_AGE_MS,
  materialChanges,
} from "./refresh.ts";

// ---------------------------------------------------------------------------
// Discovery entry point (jurisdiction fail-closed)
// ---------------------------------------------------------------------------

/**
 * Run authoritative discovery for a resolved vineyard country.
 *
 * No country → no ingestion (fail closed, mirrors the apps' jurisdiction
 * gate; the device locale is never consulted). Unsupported country → the
 * lookup continues on the existing AI path, explicitly marked as such.
 * Adapter errors are contained: discovery can say "source_unavailable" but
 * can never break the lookup.
 */
export async function discoverAuthoritative(
  countryCode: string,
  query: string,
  hintRegistrationNumber: string | null,
  deps: AdapterDeps,
): Promise<DiscoveryResult> {
  const code = countryCode.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) {
    return { outcome: "no_country", adapter: null, cache: "none" };
  }
  const adapter = adapterFor(code);
  if (!adapter) {
    return { outcome: "not_supported", adapter: null, cache: "none" };
  }
  try {
    return await adapter.discover(query, hintRegistrationNumber, deps);
  } catch (err) {
    // Adapters contain their own failures; this is belt-and-braces so a bug
    // can never take the Chemical Store down with it.
    console.error(
      "authoritative discovery crashed:",
      err instanceof Error ? err.message : String(err),
    );
    return {
      outcome: "source_unavailable",
      adapter: adapter.id,
      error_category: "unexpected_error",
      cache: "none",
    };
  }
}

// ---------------------------------------------------------------------------
// Merge: register evidence over the AI extraction
// ---------------------------------------------------------------------------

function formatActiveDisplay(a: any): string {
  const conc = a?.concentration != null
    ? ` ${a.concentration}${a?.concentration_unit ? ` ${a.concentration_unit}` : ""}`
    : "";
  return `${String(a?.name ?? "").trim()}${conc}`.trim();
}

function recomputeGroups(actives: any[]): { codes: string[]; scheme: string | null } {
  const codes = Array.from(
    new Set(
      actives
        .map((a) => a?.activity_group?.code)
        .filter((c: string | undefined): c is string => Boolean(c)),
    ),
  );
  const scheme = actives
    .map((a) => a?.activity_group?.scheme)
    .find((s: string | undefined) => s && s !== "not_applicable") ?? null;
  return { codes, scheme };
}

/**
 * Merge a resolved register identity into an AI structured extraction.
 *
 * The register wins on everything it actually asserts (identity, registrant,
 * actives + concentrations, category/form, current label approval). The AI
 * extraction keeps contributing what the register extract cannot provide —
 * registered uses, rates, WHP — with its own honest attribution. Where the
 * two DISAGREE on a register-asserted fact, the register value is served AND
 * a structured conflict is recorded, forcing the evidence state to
 * "conflict" for a human to resolve.
 */
export function mergeDiscoveryIntoStructured(
  structured: any,
  reg: ResolvedRegistration,
): any {
  const merged = { ...structured };
  const conflicts: WireConflict[] = Array.isArray(structured?.verification?.conflicts)
    ? [...structured.verification.conflicts]
    : [];

  // ---- Registration identity (register-authoritative) --------------------
  const aiReg = structured?.registration ?? {};
  const aiNumber = String(aiReg?.registration_number ?? "").trim();
  if (aiNumber && aiNumber.toUpperCase() !== reg.registration_number.toUpperCase()) {
    conflicts.push({
      field: "registration_number",
      extracted_value: aiNumber,
      authoritative_value: reg.registration_number,
      extracted_source: "ai_interpretation",
      authoritative_source: "official_register",
    });
  }

  merged.registration = {
    ...aiReg,
    country_code: reg.country_code,
    scheme: reg.scheme,
    registration_number: reg.registration_number,
    registrant: reg.registrant ?? aiReg?.registrant ?? null,
    registered_product_name: reg.registered_product_name,
    label_reference: aiReg?.label_reference ?? null,
    label_version: reg.label_version ?? aiReg?.label_version ?? null,
  };
  merged.product_name = reg.registered_product_name;
  merged.product_category = reg.product_category ?? structured?.product_category ?? "";
  merged.form_type = reg.form_type ?? structured?.form_type ?? null;

  // ---- Actives (register chemistry wins; disagreements become conflicts) --
  const aiActives: any[] = Array.isArray(structured?.active_ingredients)
    ? structured.active_ingredients
    : [];
  let mergedActives: any[] = aiActives;
  if (reg.active_ingredients.length) {
    const registerNames = new Set(
      reg.active_ingredients.map((a) => normaliseActiveName(a.name)),
    );
    for (const regActive of reg.active_ingredients) {
      const aiMatch = aiActives.find(
        (a) => normaliseActiveName(String(a?.name ?? "")) === normaliseActiveName(regActive.name),
      );
      if (
        aiMatch &&
        aiMatch?.concentration != null &&
        regActive.concentration != null &&
        (Number(aiMatch.concentration) !== Number(regActive.concentration) ||
          (String(aiMatch?.concentration_unit ?? "").toLowerCase() !==
              String(regActive.concentration_unit ?? "").toLowerCase() &&
            Boolean(aiMatch?.concentration_unit)))
      ) {
        conflicts.push({
          field: "concentration",
          active_ingredient_name: regActive.name,
          extracted_value: formatActiveDisplay(aiMatch),
          authoritative_value: formatActiveDisplay(regActive),
          extracted_source: "ai_interpretation",
          authoritative_source: "official_register",
        });
      }
    }
    for (const aiActive of aiActives) {
      const name = String(aiActive?.name ?? "").trim();
      if (name && !registerNames.has(normaliseActiveName(name))) {
        conflicts.push({
          field: "active_ingredients",
          active_ingredient_name: name,
          extracted_value: "extracted as an active ingredient",
          authoritative_value: "not an active constituent of this registration",
          extracted_source: "ai_interpretation",
          authoritative_source: "official_register",
        });
      }
    }
    mergedActives = reg.active_ingredients;
  }
  merged.active_ingredients = mergedActives;

  const { codes, scheme } = recomputeGroups(mergedActives);
  merged.activity_groups = codes;
  merged.activity_group_scheme = scheme;

  // Registered uses stay whatever the extraction honestly produced — the
  // register extract has no directions-for-use table, and inventing rates,
  // WHPs or re-entry to "complete" the record is exactly what must not happen.
  const uses: any[] = Array.isArray(structured?.registered_uses)
    ? structured.registered_uses
    : [];
  merged.registered_uses = uses;
  merged.label_rate_bases = Array.from(
    new Set(uses.flatMap((u: any) => (u?.rates ?? []).map((r: any) => r?.basis).filter(Boolean))),
  );

  // ---- Evidence: sources, unresolved, status ------------------------------
  const sources: WireDataSource[] = Array.isArray(structured?.verification?.sources)
    ? [...structured.verification.sources]
    : [];
  for (const s of reg.sources) {
    if (!sources.some((x) => x?.kind === s.kind && x?.name === s.name)) sources.push(s);
  }

  const unresolved = new Set<string>(
    Array.isArray(structured?.verification?.unresolved_fields)
      ? structured.verification.unresolved_fields
      : [],
  );
  unresolved.delete("registration_number");
  unresolved.delete("registration");
  unresolved.delete("country");
  if (merged.registration.label_version) unresolved.delete("label_version");
  // Per-active gaps are recomputed from the MERGED actives.
  for (const entry of Array.from(unresolved)) {
    if (/^(concentration|activity_group|active_ingredient):/.test(entry)) unresolved.delete(entry);
  }
  unresolved.delete("active_ingredients");
  for (const a of mergedActives) {
    if (a?.concentration == null) unresolved.add(`concentration:${a.name}`);
    if (!a?.activity_group) unresolved.add(`activity_group:${a.name}`);
  }
  if (!mergedActives.length) unresolved.add("active_ingredients");
  for (const f of reg.unresolved_fields) {
    if (f === "registered_uses" && uses.length) continue;
    if (f === "label_reference" && merged.registration.label_reference) continue;
    if (f === "active_ingredients" && mergedActives.length) continue;
    unresolved.add(f);
  }

  merged.verification = {
    ...(structured?.verification ?? {}),
    status: conflicts.length
      ? "conflict"
      : mergedActives.length
      ? "partially_verified"
      : "unverified",
    sources,
    conflicts,
    unresolved_fields: Array.from(unresolved).sort(),
    verified_at: null,
  };
  merged.match_source = "authoritative_candidate";
  return merged;
}

/**
 * A register-resolved product with NO AI extraction available (provider down
 * or skipped): everything the register asserted, nothing more. Registered
 * uses are honestly empty and unresolved.
 */
export function buildRegisterOnlyStructured(
  reg: ResolvedRegistration,
  tableVersion: number,
): any {
  const base = {
    product_name: null,
    product_category: "",
    form_type: null,
    registration: {
      country_code: reg.country_code,
      scheme: reg.scheme,
      registration_number: null,
      registrant: null,
      registered_product_name: null,
      label_reference: null,
      label_version: null,
    },
    active_ingredients: [],
    activity_groups: [],
    activity_group_scheme: null,
    registered_uses: [],
    label_rate_bases: [],
    verification: {
      status: "unverified",
      sources: [],
      conflicts: [],
      unresolved_fields: [],
      verified_at: null,
    },
    activity_group_table_version: tableVersion,
    schema_version: 1,
  };
  return mergeDiscoveryIntoStructured(base, reg);
}

// ---------------------------------------------------------------------------
// Candidate payload + dedupe/enqueue
// ---------------------------------------------------------------------------

/** Lower-cased exact-match search aliases (never identity, never fuzzy). */
function aliasSet(...names: Array<string | null | undefined>): string[] {
  const set = new Set<string>();
  for (const n of names) {
    const v = String(n ?? "").trim().toLowerCase();
    if (v) set.add(v);
  }
  return Array.from(set);
}

/**
 * Map a (possibly register-merged) structured result onto the sql/199
 * candidate columns. `review_status` is structurally pinned to "candidate".
 */
export function buildCandidatePayload(
  structured: any,
  requestedName: string,
  discovery: ResolvedRegistration | null,
  retrievedAtIso: string,
  tableVersion: number,
): CandidateRowPayload | null {
  const regBlock = structured?.registration ?? {};
  const country = String(regBlock?.country_code ?? "").trim().toUpperCase();
  const scheme = String(regBlock?.scheme ?? "").trim().toLowerCase();
  const number = String(regBlock?.registration_number ?? "").trim();
  if (!/^[A-Z]{2}$/.test(country) || !scheme || !number) return null;

  const productName = String(structured?.product_name ?? "").trim() ||
    String(regBlock?.registered_product_name ?? "").trim();
  if (!productName) return null;

  return {
    registration_country: country,
    registration_scheme: scheme,
    registration_number: number,
    registrant: regBlock?.registrant ?? null,
    registered_product_name: productName,
    common_names: aliasSet(productName, requestedName, regBlock?.registered_product_name),
    product_category: structured?.product_category || null,
    form_type: structured?.form_type ?? null,
    active_ingredients: structured?.active_ingredients ?? [],
    activity_groups: structured?.activity_groups ?? [],
    activity_group_scheme: structured?.activity_group_scheme ?? null,
    registered_uses: structured?.registered_uses ?? [],
    label_rate_bases: structured?.label_rate_bases ?? [],
    label_reference: regBlock?.label_reference ?? null,
    label_version: regBlock?.label_version ?? null,
    verification_status: structured?.verification?.status ?? "unverified",
    verification_sources: structured?.verification?.sources ?? [],
    verification_conflicts: structured?.verification?.conflicts ?? [],
    verification_unresolved_fields: structured?.verification?.unresolved_fields ?? [],
    source_kind: discovery ? "official_register" : "ai_interpretation",
    source_reference: discovery?.sources?.[0]?.reference ?? null,
    retrieved_at: retrievedAtIso,
    review_status: "candidate",
    activity_group_table_version: structured?.activity_group_table_version ?? tableVersion,
    intelligence_schema_version: structured?.schema_version ?? 1,
  };
}

export interface CandidateWriteOutcome {
  action:
    | "created"
    | "reused"
    | "refreshed"
    | "approved_exists"
    | "retired_exists"
    | "skipped"
    | "error";
  reason?: string;
  row: MasterRow | null;
}

function mergedAliases(existing: MasterRow, payload: CandidateRowPayload): string[] | null {
  const current = new Set((existing.common_names ?? []).map((n) => n.toLowerCase()));
  const additions = payload.common_names.filter((n) => !current.has(n));
  if (!additions.length) return null;
  return [...(existing.common_names ?? []), ...additions];
}

function contentPatch(payload: CandidateRowPayload, existing: MasterRow): Record<string, any> {
  const patch: Record<string, any> = {
    registrant: payload.registrant,
    registered_product_name: payload.registered_product_name,
    common_names: mergedAliases(existing, payload) ?? existing.common_names,
    product_category: payload.product_category ?? existing.product_category,
    form_type: payload.form_type ?? existing.form_type,
    active_ingredients: payload.active_ingredients,
    activity_groups: payload.activity_groups,
    activity_group_scheme: payload.activity_group_scheme,
    label_version: payload.label_version ?? existing.label_version,
    verification_status: payload.verification_status,
    verification_sources: payload.verification_sources,
    verification_conflicts: payload.verification_conflicts,
    verification_unresolved_fields: payload.verification_unresolved_fields,
    source_kind: payload.source_kind,
    source_reference: payload.source_reference,
    retrieved_at: payload.retrieved_at,
    activity_group_table_version: payload.activity_group_table_version,
    intelligence_schema_version: payload.intelligence_schema_version,
  };
  // Never blank richer data with an emptier lookup.
  if (payload.registered_uses.length) {
    patch.registered_uses = payload.registered_uses;
    patch.label_rate_bases = payload.label_rate_bases;
  }
  if (payload.label_reference) patch.label_reference = payload.label_reference;
  return patch;
}

function evidencePatch(payload: CandidateRowPayload, existing: MasterRow): Record<string, any> {
  return {
    common_names: mergedAliases(existing, payload) ?? existing.common_names,
    verification_sources: payload.verification_sources,
    retrieved_at: payload.retrieved_at,
    source_kind: payload.source_kind,
    source_reference: payload.source_reference,
  };
}

/**
 * Registration-identity dedupe, then enqueue or refresh (Stage 3 §§12–13).
 *
 *   * exact `country:scheme:number` match FIRST, across every review state;
 *   * approved/retired rows are never touched by automation;
 *   * one candidate per canonical registration identity — 20 vineyards
 *     searching the same unresolved product still yield ONE row;
 *   * refresh policy: authoritative evidence may upgrade an AI candidate,
 *     replace materially-changed content, or re-stamp stale evidence
 *     (older than 7 days). AI evidence can only ever add search aliases.
 */
export async function upsertCandidate(
  ops: MasterOps,
  payload: CandidateRowPayload,
  nowMs: number,
): Promise<CandidateWriteOutcome> {
  try {
    const key = identityKey(
      payload.registration_country,
      payload.registration_scheme,
      payload.registration_number,
    );
    let existing = await ops.selectByIdentityKey(key);
    if (!existing) {
      const inserted = await ops.insertCandidate(payload);
      if (inserted) return { action: "created", row: inserted };
      existing = await ops.selectByIdentityKey(key);
      if (!existing) return { action: "error", reason: "insert_failed", row: null };
    }

    if (existing.review_status === "approved") {
      return { action: "approved_exists", row: existing };
    }
    if (existing.review_status === "retired") {
      return { action: "retired_exists", row: existing };
    }

    const isAuthoritative = payload.source_kind === "official_register";
    const existingAuthoritative = existing.source_kind === "official_register" ||
      existing.source_kind === "manufacturer_label";

    if (!isAuthoritative) {
      const aliases = mergedAliases(existing, payload);
      if (aliases) await ops.updateCandidate(existing.id, { common_names: aliases });
      return { action: "reused", reason: "existing_candidate_wins", row: existing };
    }

    if (!existingAuthoritative) {
      const ok = await ops.updateCandidate(existing.id, contentPatch(payload, existing));
      return {
        action: ok ? "refreshed" : "reused",
        reason: "authority_upgrade",
        row: existing,
      };
    }

    const changes = materialChanges(existing, {
      registered_product_name: payload.registered_product_name,
      registrant: payload.registrant,
      product_category: payload.product_category,
      form_type: payload.form_type,
      label_version: payload.label_version,
      active_ingredients: payload.active_ingredients,
    });
    if (changes.length) {
      const ok = await ops.updateCandidate(existing.id, contentPatch(payload, existing));
      return { action: ok ? "refreshed" : "reused", reason: "material_change", row: existing };
    }

    const ageMs = nowMs - (Date.parse(existing.retrieved_at ?? "") || 0);
    if (ageMs > CANDIDATE_EVIDENCE_MAX_AGE_MS) {
      const ok = await ops.updateCandidate(existing.id, evidencePatch(payload, existing));
      return { action: ok ? "refreshed" : "reused", reason: "evidence_refreshed", row: existing };
    }

    const aliases = mergedAliases(existing, payload);
    if (aliases) await ops.updateCandidate(existing.id, { common_names: aliases });
    return { action: "reused", reason: "fresh_evidence", row: existing };
  } catch (err) {
    console.error(
      "candidate upsert skipped:",
      err instanceof Error ? err.message : String(err),
    );
    return { action: "error", reason: "exception", row: null };
  }
}

// ---------------------------------------------------------------------------
// Response envelopes + structured log
// ---------------------------------------------------------------------------

/** Additive envelope describing the candidate row backing this lookup. */
export function candidateEnvelope(row: MasterRow): Record<string, any> {
  return {
    master_chemical_id: row.id,
    candidate_revision: row.catalogue_version ?? 1,
    catalogue_status: row.review_status,
    registration_identity_key: row.registration_identity_key,
  };
}

/** Additive envelope describing what authoritative discovery did. */
export function discoveryEnvelope(discovery: DiscoveryResult): Record<string, any> {
  const out: Record<string, any> = {
    adapter: discovery.adapter,
    outcome: discovery.outcome,
  };
  if (discovery.registration) {
    out.registration_identity_key = discovery.registration.registration_identity_key;
    if (discovery.registration.register_status) {
      out.register_status = discovery.registration.register_status;
    }
  }
  if (discovery.error_category) out.error_category = discovery.error_category;
  return out;
}

/** One structured, secret-free log line per ingestion attempt (§P). */
export function ingestionLog(fields: {
  jurisdiction: string;
  adapter: string | null;
  outcome: string;
  identity: string | null;
  master: "existing_approved" | "existing_retired" | "none";
  candidate: string;
  unresolvedCount: number;
  conflictCount: number;
  durationMs: number;
  cache: string;
  errorCategory?: string;
}): string {
  return JSON.stringify({
    evt: "chemical_ingestion",
    jurisdiction: fields.jurisdiction || "none",
    adapter: fields.adapter,
    outcome: fields.outcome,
    registration_identity: fields.identity,
    master: fields.master,
    candidate: fields.candidate,
    unresolved_count: fields.unresolvedCount,
    conflict_count: fields.conflictCount,
    duration_ms: fields.durationMs,
    cache: fields.cache,
    ...(fields.errorCategory ? { error_category: fields.errorCategory } : {}),
  });
}
