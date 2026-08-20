// Lookup jurisdiction resolution — the server side of
// docs/vineyard-country-contract.md.
//
// `vineyards.country` stores the canonical DISPLAY NAME ("Australia") and is
// the ONLY country source for chemical lookups: the apps send it verbatim,
// and this module resolves it to the ISO-2 code that scopes every
// jurisdiction decision (master catalogue scope, register adapter selection,
// registration identity keys). Resolution is a fixed table — canonical
// display names case-insensitively, the contract's approved aliases, and
// bare ISO-2 codes passed through uppercased.
//
// FAIL CLOSED, NEVER GUESS:
//   * An unrecognised value resolves to NO jurisdiction (code null) — it is
//     surfaced as "unrecognised", never coerced to a default.
//   * A missing value resolves to NO jurisdiction ("missing").
//   * There is no locale, browser, or default-country fallback anywhere.
//
// Every structured/search response carries the `jurisdiction` envelope built
// here, so clients (portal included) render lookup jurisdiction and
// registration country from ONE resolved value instead of deriving them
// independently — the contract/data-flow gap that let a lookup display
// "jurisdiction AU" beside "registration country unknown".

import { registryEntryFor } from "./registry.ts";

/** Contract v1 vineyard countries (ISO-2 → canonical display name). */
export const VINEYARD_COUNTRIES: Readonly<Record<string, string>> = {
  AR: "Argentina",
  AU: "Australia",
  AT: "Austria",
  BR: "Brazil",
  BG: "Bulgaria",
  CA: "Canada",
  CL: "Chile",
  CN: "China",
  HR: "Croatia",
  FR: "France",
  GE: "Georgia",
  DE: "Germany",
  GR: "Greece",
  HU: "Hungary",
  IN: "India",
  IE: "Ireland",
  IL: "Israel",
  IT: "Italy",
  JP: "Japan",
  MX: "Mexico",
  NZ: "New Zealand",
  PT: "Portugal",
  RO: "Romania",
  SI: "Slovenia",
  ZA: "South Africa",
  ES: "Spain",
  CH: "Switzerland",
  GB: "United Kingdom",
  US: "United States",
  UY: "Uruguay",
};

/** Contract v1 approved aliases (normalised form → ISO-2). Checked BEFORE the bare ISO-2 passthrough so "uk" resolves to GB, never to a bogus "UK" code. */
const COUNTRY_ALIASES: Readonly<Record<string, string>> = {
  "uk": "GB",
  "great britain": "GB",
  "usa": "US",
  "united states of america": "US",
  "aotearoa": "NZ",
  "newzealand": "NZ",
};

function normaliseCountryInput(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

const NAME_TO_CODE: Readonly<Record<string, string>> = Object.fromEntries(
  Object.entries(VINEYARD_COUNTRIES).map(([code, name]) => [
    normaliseCountryInput(name),
    code,
  ]),
);

export interface ResolvedLookupCountry {
  /** What the request carried, verbatim (trimmed). Empty when absent. */
  raw: string;
  /** ISO-2 jurisdiction code, or null when nothing resolved. */
  code: string | null;
  /** Canonical display name when the code is a contract country. */
  displayName: string | null;
  /** True when the value resolved through the contract table/aliases. */
  recognised: boolean;
}

/**
 * Resolve a request's country value (canonical display name, approved alias,
 * or bare ISO-2 code) to the lookup jurisdiction. Deterministic table only —
 * unknown values resolve to null, never to a guess.
 */
export function resolveLookupCountry(raw: string | null | undefined): ResolvedLookupCountry {
  const trimmed = String(raw ?? "").trim();
  if (!trimmed) return { raw: "", code: null, displayName: null, recognised: false };

  const norm = normaliseCountryInput(trimmed);

  const alias = COUNTRY_ALIASES[norm];
  if (alias) {
    return { raw: trimmed, code: alias, displayName: VINEYARD_COUNTRIES[alias] ?? null, recognised: true };
  }

  const byName = NAME_TO_CODE[norm];
  if (byName) {
    return { raw: trimmed, code: byName, displayName: VINEYARD_COUNTRIES[byName], recognised: true };
  }

  // Bare ISO-2 codes pass through uppercased (contract §2). A code outside
  // the contract table is still a valid jurisdiction shape — it simply has
  // no display name and no register support.
  if (/^[A-Za-z]{2}$/.test(trimmed)) {
    const code = trimmed.toUpperCase();
    const display = VINEYARD_COUNTRIES[code] ?? null;
    return { raw: trimmed, code, displayName: display, recognised: display !== null };
  }

  return { raw: trimmed, code: null, displayName: null, recognised: false };
}

/** sql/194 registration scheme for a resolved jurisdiction code. */
export function registrationSchemeForCode(code: string | null): string | null {
  if (code === "AU") return "apvma";
  if (code === "NZ") return "acvm";
  return null;
}

export type RegisterSupport =
  | "supported" // jurisdiction has a wired register adapter (AU)
  | "declared" // jurisdiction is in the source registry, adapter not implemented (NZ/GB/US)
  | "none" // resolved jurisdiction with no register source declared
  | "unrecognised" // request carried a country the contract cannot resolve
  | "missing"; // request carried no country at all

export interface JurisdictionEnvelope {
  /** The request's country value, verbatim. Null when absent. */
  requested_country: string | null;
  /** The resolved ISO-2 lookup jurisdiction. Null = no jurisdiction. */
  resolved_country_code: string | null;
  /** Canonical display name for the resolved jurisdiction, when known. */
  resolved_country_name: string | null;
  /** The register adapter that serves this jurisdiction, or null. */
  register_adapter: string | null;
  register_support: RegisterSupport;
}

/**
 * The single authoritative statement of what jurisdiction a lookup ran under.
 * Clients must render lookup jurisdiction AND registration country from this
 * envelope — never derive either independently.
 */
export function jurisdictionEnvelope(resolved: ResolvedLookupCountry): JurisdictionEnvelope {
  const entry = resolved.code ? registryEntryFor(resolved.code) : null;
  let support: RegisterSupport;
  if (!resolved.raw) support = "missing";
  else if (!resolved.code) support = "unrecognised";
  else if (entry?.adapter) support = "supported";
  else if (entry) support = "declared";
  else support = "none";
  return {
    requested_country: resolved.raw || null,
    resolved_country_code: resolved.code,
    resolved_country_name: resolved.displayName,
    register_adapter: entry?.adapter?.id ?? null,
    register_support: support,
  };
}
