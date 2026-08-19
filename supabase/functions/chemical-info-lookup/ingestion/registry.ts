// Country source registry — WHICH chemical-registration sources VineTrack
// trusts, by jurisdiction (Master Chemical Catalogue Stage 3 §A).
//
// The resolved vineyard country selects the adapter. Source selection is a
// REGISTRY decision, never an AI decision: the model can help read documents,
// but it does not get to choose which nation's register is the authority.
//
// A country with `adapter: null` is DECLARED (its schemes and intended
// sources are on record) but not implemented — authoritative ingestion for
// it simply does not run, and lookups fall through to the existing AI-and-
// manual behaviour. Adding a jurisdiction later means implementing a
// SourceAdapter and filling the slot; the master_chemicals schema needs no
// change (identity is already country-scoped).
//
// Countries listed in docs/vineyard-country-contract.md but absent here have
// no wired register at all — vineyard-country support does NOT imply a
// chemical-register adapter (contract §12.3 note).

import type { SourceAdapter } from "./contract.ts";
import { apvmaAdapter } from "./apvma.ts";

export interface CountrySourceEntry {
  country: string;
  /** sql/194 registration_scheme values used by this jurisdiction. */
  schemes: string[];
  /** Highest authority: the government register. */
  register_authority: string;
  /** Label authority: the current approved/authorised label source. */
  label_authority: string;
  /** Supporting evidence sources (never authoritative on their own). */
  supporting_sources: string[];
  /** Discovery only — may locate/extract, never counts as evidence. */
  discovery_only: string[];
  /** null = declared for the future, no authoritative ingestion yet. */
  adapter: SourceAdapter | null;
}

export const COUNTRY_SOURCE_REGISTRY: Record<string, CountrySourceEntry> = {
  AU: {
    country: "AU",
    schemes: ["apvma"],
    register_authority:
      "APVMA PubCRIS register extract (data.gov.au dataset published weekly by the APVMA)",
    label_authority:
      "APVMA-approved product label (PubCRIS label registration record; document confirmed at admin review)",
    supporting_sources: [
      "Registrant/manufacturer label mirror (manufacturer_label)",
      "AWRI 'Agrochemicals registered for use in Australian viticulture' (viticulture_reference)",
    ],
    discovery_only: ["AI extraction / web search (ai_interpretation)"],
    adapter: apvmaAdapter,
  },
  NZ: {
    country: "NZ",
    schemes: ["acvm", "nz_epa"],
    register_authority: "MPI ACVM register (future adapter)",
    label_authority: "ACVM-registered label / EPA HSNO approval (future adapter)",
    supporting_sources: ["Registrant label mirror", "NZ Winegrowers spray schedule (viticulture_reference)"],
    discovery_only: ["AI extraction / web search (ai_interpretation)"],
    adapter: null,
  },
  GB: {
    country: "GB",
    schemes: ["other"],
    register_authority: "HSE plant protection products register (future adapter)",
    label_authority: "HSE-authorised label (future adapter)",
    supporting_sources: ["Registrant label mirror"],
    discovery_only: ["AI extraction / web search (ai_interpretation)"],
    adapter: null,
  },
  US: {
    country: "US",
    schemes: ["other"],
    register_authority: "US EPA pesticide product label system (future adapter)",
    label_authority: "EPA-stamped label (future adapter)",
    supporting_sources: ["Registrant label mirror", "State registration lists"],
    discovery_only: ["AI extraction / web search (ai_interpretation)"],
    adapter: null,
  },
};

export function registryEntryFor(countryCode: string): CountrySourceEntry | null {
  const code = countryCode.trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) return null;
  return COUNTRY_SOURCE_REGISTRY[code] ?? null;
}

/**
 * The adapter for a resolved vineyard country, or null when the jurisdiction
 * has none. A missing/blank country yields null — authoritative ingestion
 * fails closed, mirroring the apps' jurisdiction gate. No locale fallback.
 */
export function adapterFor(countryCode: string): SourceAdapter | null {
  return registryEntryFor(countryCode)?.adapter ?? null;
}
