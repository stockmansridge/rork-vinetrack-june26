// Authoritative activity-group classification for common viticultural actives.
//
// MOVED OUT of index.ts in Stage 3 so the authoritative ingestion module and
// its deno tests can consult the SAME table the AI cross-check uses. The
// function is deployed with `supabase functions deploy chemical-info-lookup`
// (scripts/deploy-edge-functions.ps1 / .sh), which bundles the full local
// module graph — the same mechanism that already ships
// `vinetrack-webhook-dispatch/lib.ts` and the `_shared/email` imports.
// Single-file dashboard pastes are NOT supported for this function any more.
//
// This is the server-side twin of the iOS `AuthoritativeActivityGroups` and
// the Android `AuthoritativeActivityGroups` object. All three MUST agree — the
// whole point is that a product's activity group has one answer, not three.
// When you change one, change all three and bump ACTIVITY_GROUP_TABLE_VERSION.
//
// It exists so no extraction is ever the only opinion in the room. Whatever a
// model or a register document says an active's group is, it is checked
// against this table before the response leaves the server, and a
// disagreement is returned as an explicit conflict rather than silently
// overwritten.
//
// Activity group is a property of the ACTIVE, not of a brand, and it does not
// vary by country — which is why this table has no country dimension while
// product identity emphatically does.

// ---------------------------------------------------------------------------
// Herbicide classification is CURRENT-NUMERIC (v2)
// ---------------------------------------------------------------------------
//
// Australia replaced the alphabetical herbicide mode-of-action codes with the
// globally aligned NUMERIC system (CropLife Australia / HRAC). Labels began
// carrying numbers in 2022 and the transition completed in 2024, so the code a
// grower reads on a current Australian herbicide label is "Group 14", not
// "Group E" and not "Group G".
//
// This table held the OLD global HRAC letters, which produced a false conflict
// on every herbicide: the label and the lookup both said the same thing in two
// different alphabets, and the app reported them as sources that disagreed.
//
// Two alphabets is exactly why equivalence must be decided per ACTIVE rather
// than per letter. The old Australian letters and the old global HRAC letters
// are DIFFERENT systems that reuse the same characters for different
// chemistries — "E" was PPO inhibitors globally but carbamates in Australia,
// "G" was glyphosate globally but PPO inhibitors in Australia. A letter alone
// is therefore not decodable; a letter plus the active it was printed for
// always is. `HERBICIDE_LEGACY_CODES` records, per active, every code that
// active was legitimately published under, and `groupsAreEquivalent` treats
// those as the same classification rather than a disagreement.
//
// Fungicides (FRAC) and insecticides (IRAC) are unchanged — those schemes were
// already numeric/alphanumeric and were never realigned — so they carry no
// legacy mapping and none is invented for them.

/**
 * Bump whenever the table changes. Stamped onto every verification.
 *
 * v2 — herbicides migrated from legacy alphabetical codes to the current
 * Australian/global numeric mode-of-action groups, with per-active legacy
 * equivalence. Completed spray snapshots are NOT rewritten: they keep the
 * classification that was current when they were recorded. Saved chemicals
 * pick the current group up through the normal Re-verify path.
 */
export const ACTIVITY_GROUP_TABLE_VERSION = 2;

export type ActivityGroupScheme = "frac" | "hrac" | "irac" | "not_applicable";

export interface ActivityGroup {
  scheme: ActivityGroupScheme;
  code: string;
  common_name?: string | null;
}

const frac = (code: string, name: string): ActivityGroup => ({
  scheme: "frac",
  code,
  common_name: name,
});
/**
 * Every legacy code a herbicide active was published under, keyed by the
 * normalised active name.
 *
 * Populated by `hrac()` as the table is declared, so a classification and its
 * legacy equivalents can never drift apart. Equivalence data only: it is never
 * served, never displayed, and never overrides the current group.
 */
const HERBICIDE_LEGACY_CODES: Record<string, string[]> = {};

/**
 * Declare a herbicide's CURRENT numeric group.
 *
 * @param code    the current Australian/global numeric MoA group
 * @param name    the mode of action, in the current wording
 * @param legacy  codes this active was previously published under — the old
 *                GLOBAL HRAC letter and the old AUSTRALIAN letter, which are
 *                frequently different characters for the same chemistry
 * @param key     the table key being declared, so legacy codes register
 *                against the same normalised name the lookup uses
 */
const hrac = (
  code: string,
  name: string,
  legacy: string[] = [],
  key?: string,
): ActivityGroup => {
  if (key && legacy.length) {
    HERBICIDE_LEGACY_CODES[normaliseActiveName(key)] = legacy;
  }
  return { scheme: "hrac", code, common_name: name };
};
const irac = (code: string, name: string): ActivityGroup => ({
  scheme: "irac",
  code,
  common_name: name,
});

export const ACTIVITY_GROUP_TABLE: Record<string, ActivityGroup> = {
  // ---- Fungicides (FRAC) ----
  "tebuconazole": frac("3", "DMI / Triazole"),
  "myclobutanil": frac("3", "DMI / Triazole"),
  "penconazole": frac("3", "DMI / Triazole"),
  "triadimenol": frac("3", "DMI / Triazole"),
  "tetraconazole": frac("3", "DMI / Triazole"),
  "difenoconazole": frac("3", "DMI / Triazole"),
  "propiconazole": frac("3", "DMI / Triazole"),
  "flutriafol": frac("3", "DMI / Triazole"),
  "triflumizole": frac("3", "DMI / Imidazole"),
  "prochloraz": frac("3", "DMI / Imidazole"),
  "fenarimol": frac("3", "DMI / Pyrimidine"),
  "metalaxyl": frac("4", "Phenylamide"),
  "metalaxyl m": frac("4", "Phenylamide"),
  "mefenoxam": frac("4", "Phenylamide"),
  "benalaxyl": frac("4", "Phenylamide"),
  "spiroxamine": frac("5", "Amine / Morpholine"),
  "dimethomorph": frac("40", "CAA"),
  "mandipropamid": frac("40", "CAA"),
  "benthiavalicarb": frac("40", "CAA"),
  "iprovalicarb": frac("40", "CAA"),
  "carbendazim": frac("1", "MBC / Benzimidazole"),
  "thiophanate methyl": frac("1", "MBC / Thiophanate"),
  "iprodione": frac("2", "Dicarboximide"),
  "procymidone": frac("2", "Dicarboximide"),
  "cyprodinil": frac("9", "Anilinopyrimidine"),
  "pyrimethanil": frac("9", "Anilinopyrimidine"),
  "mepanipyrim": frac("9", "Anilinopyrimidine"),
  "azoxystrobin": frac("11", "QoI / Strobilurin"),
  "trifloxystrobin": frac("11", "QoI / Strobilurin"),
  "pyraclostrobin": frac("11", "QoI / Strobilurin"),
  "kresoxim methyl": frac("11", "QoI / Strobilurin"),
  "famoxadone": frac("11", "QoI"),
  "fenamidone": frac("11", "QoI"),
  "fludioxonil": frac("12", "Phenylpyrrole"),
  "quinoxyfen": frac("13", "Aza-naphthalene"),
  "boscalid": frac("7", "SDHI"),
  "fluopyram": frac("7", "SDHI"),
  "fluxapyroxad": frac("7", "SDHI"),
  "penthiopyrad": frac("7", "SDHI"),
  "isopyrazam": frac("7", "SDHI"),
  "benzovindiflupyr": frac("7", "SDHI"),
  "pydiflumetofen": frac("7", "SDHI"),
  "fenhexamid": frac("17", "Hydroxyanilide"),
  "cyazofamid": frac("21", "QiI"),
  "amisulbrom": frac("21", "QiI"),
  "metrafenone": frac("U8", "Aryl-phenyl-ketone"),
  "pyriofenone": frac("U8", "Aryl-phenyl-ketone"),
  "cyflufenamid": frac("U6", "Phenyl-acetamide"),
  "proquinazid": frac("13", "Quinazolinone"),
  "fluazinam": frac("29", "Uncoupler"),
  "ametoctradin": frac("45", "QoSI"),
  "oxathiapiprolin": frac("49", "OSBPI"),
  "fluopicolide": frac("43", "Benzamide"),
  "zoxamide": frac("22", "Benzamide"),
  "phosphorous acid": frac("P07", "Host defence induction"),
  "phosphonic acid": frac("P07", "Host defence induction"),
  "potassium phosphonate": frac("P07", "Host defence induction"),
  "fosetyl aluminium": frac("P07", "Host defence induction"),
  "fosetyl al": frac("P07", "Host defence induction"),
  "sulfur": frac("M2", "Multi-site / Inorganic"),
  "sulphur": frac("M2", "Multi-site / Inorganic"),
  "copper hydroxide": frac("M1", "Multi-site / Copper"),
  "copper oxychloride": frac("M1", "Multi-site / Copper"),
  "cuprous oxide": frac("M1", "Multi-site / Copper"),
  "tribasic copper sulfate": frac("M1", "Multi-site / Copper"),
  "mancozeb": frac("M3", "Multi-site / Dithiocarbamate"),
  "metiram": frac("M3", "Multi-site / Dithiocarbamate"),
  "propineb": frac("M3", "Multi-site / Dithiocarbamate"),
  "ziram": frac("M3", "Multi-site / Dithiocarbamate"),
  "thiram": frac("M3", "Multi-site / Dithiocarbamate"),
  "captan": frac("M4", "Multi-site / Phthalimide"),
  "folpet": frac("M4", "Multi-site / Phthalimide"),
  "chlorothalonil": frac("M5", "Multi-site / Chloronitrile"),
  "dithianon": frac("M9", "Multi-site / Quinone"),

  // ---- Herbicides (current Australian/global numeric MoA groups) ----
  // legacy = [old GLOBAL HRAC letter, old AUSTRALIAN letter] where they differ.
  "glyphosate": hrac("9", "EPSP synthase inhibitor", ["G", "M"], "glyphosate"),
  "glufosinate": hrac("10", "Glutamine synthetase inhibitor", ["H", "N"], "glufosinate"),
  "glufosinate ammonium": hrac(
    "10",
    "Glutamine synthetase inhibitor",
    ["H", "N"],
    "glufosinate ammonium",
  ),
  "paraquat": hrac("22", "PSI electron diverter", ["D", "L"], "paraquat"),
  "diquat": hrac("22", "PSI electron diverter", ["D", "L"], "diquat"),
  "simazine": hrac("5", "PSII inhibitor (serine 264 binder)", ["C1", "C"], "simazine"),
  "diuron": hrac("5", "PSII inhibitor (serine 264 binder)", ["C2", "C"], "diuron"),
  "amitrole": hrac("34", "Lycopene cyclase inhibitor", ["F3", "Q"], "amitrole"),
  "oxyfluorfen": hrac("14", "PPO inhibitor", ["E", "G"], "oxyfluorfen"),
  "carfentrazone": hrac("14", "PPO inhibitor", ["E", "G"], "carfentrazone"),
  "flumioxazin": hrac("14", "PPO inhibitor", ["E", "G"], "flumioxazin"),
  "haloxyfop": hrac("1", "ACCase inhibitor", ["A"], "haloxyfop"),
  "clethodim": hrac("1", "ACCase inhibitor", ["A"], "clethodim"),
  "fluazifop": hrac("1", "ACCase inhibitor", ["A"], "fluazifop"),
  "sethoxydim": hrac("1", "ACCase inhibitor", ["A"], "sethoxydim"),
  "propyzamide": hrac("3", "Microtubule assembly inhibitor", ["K1", "D"], "propyzamide"),
  "pendimethalin": hrac("3", "Microtubule assembly inhibitor", ["K1", "D"], "pendimethalin"),
  "trifluralin": hrac("3", "Microtubule assembly inhibitor", ["K1", "D"], "trifluralin"),
  "isoxaben": hrac("29", "Cellulose synthesis inhibitor", ["L", "O"], "isoxaben"),
  "indaziflam": hrac("29", "Cellulose synthesis inhibitor", ["L", "O"], "indaziflam"),
  "metsulfuron methyl": hrac("2", "ALS inhibitor", ["B"], "metsulfuron methyl"),
  "chlorsulfuron": hrac("2", "ALS inhibitor", ["B"], "chlorsulfuron"),
  "imazapyr": hrac("2", "ALS inhibitor", ["B"], "imazapyr"),
  "2,4 d": hrac("4", "Auxin mimic", ["O", "I"], "2,4 d"),
  "mcpa": hrac("4", "Auxin mimic", ["O", "I"], "mcpa"),
  "triclopyr": hrac("4", "Auxin mimic", ["O", "I"], "triclopyr"),
  "clopyralid": hrac("4", "Auxin mimic", ["O", "I"], "clopyralid"),
  "pelargonic acid": hrac("0", "Unknown / non-selective contact", ["Z"], "pelargonic acid"),

  // ---- Insecticides & miticides (IRAC) ----
  "chlorpyrifos": irac("1B", "Organophosphate"),
  "methomyl": irac("1A", "Carbamate"),
  "alpha cypermethrin": irac("3A", "Pyrethroid"),
  "bifenthrin": irac("3A", "Pyrethroid"),
  "lambda cyhalothrin": irac("3A", "Pyrethroid"),
  "deltamethrin": irac("3A", "Pyrethroid"),
  "esfenvalerate": irac("3A", "Pyrethroid"),
  "imidacloprid": irac("4A", "Neonicotinoid"),
  "thiamethoxam": irac("4A", "Neonicotinoid"),
  "acetamiprid": irac("4A", "Neonicotinoid"),
  "clothianidin": irac("4A", "Neonicotinoid"),
  "spinetoram": irac("5", "Spinosyn"),
  "spinosad": irac("5", "Spinosyn"),
  "abamectin": irac("6", "Avermectin"),
  "emamectin benzoate": irac("6", "Avermectin"),
  "buprofezin": irac("16", "Chitin biosynthesis inhibitor"),
  "methoxyfenozide": irac("18", "Diacylhydrazine"),
  "tebufenozide": irac("18", "Diacylhydrazine"),
  "etoxazole": irac("10B", "Mite growth inhibitor"),
  "clofentezine": irac("10A", "Mite growth inhibitor"),
  "hexythiazox": irac("10A", "Mite growth inhibitor"),
  "propargite": irac("12C", "METI / Sulfite ester"),
  "fenbutatin oxide": irac("12B", "Organotin miticide"),
  "bifenazate": irac("20D", "Mitochondrial complex III inhibitor"),
  "chlorantraniliprole": irac("28", "Diamide"),
  "cyantraniliprole": irac("28", "Diamide"),
  "flubendiamide": irac("28", "Diamide"),
  "sulfoxaflor": irac("4C", "Sulfoximine"),
  "spirotetramat": irac("23", "Tetramic acid"),
  "spirodiclofen": irac("23", "Tetronic acid"),
  "pyriproxyfen": irac("7C", "Juvenile hormone mimic"),
  "indoxacarb": irac("22A", "Oxadiazine"),
  "bacillus thuringiensis": irac("11A", "Bt / Microbial disruptor"),
};

export function normaliseActiveName(raw: string): string {
  return raw.trim().toLowerCase().replace(/-/g, " ").replace(/\s+/g, " ");
}

/**
 * Strips the noise humans, AI, and register documents put around a code so
 * "Group 3", "group3" and "11 (QoI / Strobilurin)" all reduce to a bare code.
 */
export function normaliseCode(raw: string): string {
  let value = String(raw ?? "").trim().toUpperCase();
  for (const prefix of ["GROUP ", "GROUP", "FRAC ", "HRAC ", "IRAC ", "MOA ", "CODE "]) {
    if (value.startsWith(prefix)) value = value.slice(prefix.length).trim();
  }
  const paren = value.indexOf("(");
  if (paren >= 0) value = value.slice(0, paren).trim();
  return value.replace(/\s+/g, "");
}

/**
 * Look up an active's authoritative group.
 *
 * Returns null when the active is not in the table — which means UNKNOWN,
 * never "the extraction must be right". Callers must not read null as
 * permission to trust an unverified extraction.
 */
export function authoritativeGroup(activeName: string): ActivityGroup | null {
  const key = normaliseActiveName(activeName);
  if (!key) return null;
  if (ACTIVITY_GROUP_TABLE[key]) return ACTIVITY_GROUP_TABLE[key];
  // Salt/ester forms are written many ways ("glyphosate isopropylamine").
  // Match the longest known active contained in the string so a formulation
  // suffix does not lose the classification.
  const candidates = Object.keys(ACTIVITY_GROUP_TABLE)
    .filter((k) => k.length >= 5 && key.includes(k))
    .sort((a, b) => b.length - a.length);
  return candidates.length ? ACTIVITY_GROUP_TABLE[candidates[0]] : null;
}

/**
 * Every code this active was legitimately published under BEFORE the current
 * classification, normalised. Empty for actives with no legacy alphabet
 * (fungicides and insecticides) and for actives the table does not know.
 */
export function legacyGroupCodes(activeName: string): string[] {
  const key = normaliseActiveName(activeName);
  if (!key) return [];
  const direct = HERBICIDE_LEGACY_CODES[key];
  if (direct) return direct.map(normaliseCode);
  // Same longest-contained-active rule the classification lookup uses, so a
  // salt or ester form inherits its parent's legacy codes too.
  const candidates = Object.keys(HERBICIDE_LEGACY_CODES)
    .filter((k) => k.length >= 5 && key.includes(k))
    .sort((a, b) => b.length - a.length);
  return candidates.length ? HERBICIDE_LEGACY_CODES[candidates[0]].map(normaliseCode) : [];
}

/**
 * Whether two classifications of the SAME active mean the same thing.
 *
 * This is the canonical-identity comparison the whole v2 migration turns on.
 * A label printed before the numeric realignment says "Group E" (or "Group
 * G", in the old Australian alphabet) for exactly the chemistry a current
 * label calls "Group 14". Those are one classification expressed in two
 * vocabularies, and reporting them to a grower as sources that disagree is a
 * false alarm about a resistance group — the one place in the app where a
 * false alarm costs the most trust.
 *
 * Equivalence is decided PER ACTIVE, never per letter, because the two legacy
 * alphabets reuse characters for unrelated chemistries. A genuine
 * disagreement — a source calling flumioxazin a Group 2 — still conflicts,
 * which is the entire point of keeping the check.
 */
export function groupsAreEquivalent(
  activeName: string,
  a: ActivityGroup | null | undefined,
  b: ActivityGroup | null | undefined,
): boolean {
  if (!a || !b) return false;
  if (a.scheme !== b.scheme) return false;
  const codeA = normaliseCode(a.code);
  const codeB = normaliseCode(b.code);
  if (!codeA || !codeB) return false;
  if (codeA === codeB) return true;
  if (a.scheme !== "hrac") return false;
  // One side current, the other a code this active was published under before.
  const legacy = legacyGroupCodes(activeName);
  if (!legacy.length) return false;
  const current = normaliseCode(authoritativeGroup(activeName)?.code ?? "");
  if (!current) return false;
  const isCurrentOrLegacy = (code: string): boolean =>
    code === current || legacy.includes(code);
  return isCurrentOrLegacy(codeA) && isCurrentOrLegacy(codeB);
}

export interface GroupConflict {
  field: string;
  active_ingredient_name: string;
  extracted_value: string;
  authoritative_value: string;
  extracted_source: string;
  authoritative_source: string;
}

export interface Reconciliation {
  group: ActivityGroup | null;
  /** Which source the returned group may be attributed to. */
  source: string | null;
  conflict: GroupConflict | null;
}

export function displayLabel(g: ActivityGroup): string {
  const scheme = g.scheme === "frac"
    ? "FRAC"
    : g.scheme === "hrac"
    ? "HRAC"
    : g.scheme === "irac"
    ? "IRAC"
    : "Not applicable";
  return g.common_name ? `${scheme} ${g.code} (${g.common_name})` : `${scheme} ${g.code}`;
}

/**
 * Cross-check an extracted group against the authoritative table.
 *
 * This is the source-disagreement gate:
 *  - No authoritative opinion  -> keep the extraction, but it stays attributed
 *                                 to the AI, so it can never read as verified.
 *  - Agreement                 -> the authoritative group wins (same code,
 *                                 better source).
 *  - Disagreement              -> return the AUTHORITATIVE group PLUS a
 *                                 conflict. The extracted value never silently
 *                                 survives, and the product cannot be Verified
 *                                 until a human resolves it.
 */
export function reconcileGroup(
  activeName: string,
  extracted: ActivityGroup | null,
): Reconciliation {
  const authoritative = authoritativeGroup(activeName);
  if (!authoritative) {
    return {
      group: extracted,
      source: extracted ? "ai_interpretation" : null,
      conflict: null,
    };
  }
  if (!extracted || !extracted.code) {
    return { group: authoritative, source: "authoritative_classification", conflict: null };
  }
  // Canonical identity, not string identity: a legacy code for this active is
  // the SAME classification, so it agrees rather than conflicts. The current
  // group is what gets served either way — growers see today's number.
  if (groupsAreEquivalent(activeName, extracted, authoritative)) {
    return { group: authoritative, source: "authoritative_classification", conflict: null };
  }
  return {
    group: authoritative,
    source: "authoritative_classification",
    conflict: {
      field: "activity_group",
      active_ingredient_name: activeName,
      extracted_value: displayLabel(extracted),
      authoritative_value: displayLabel(authoritative),
      extracted_source: "ai_interpretation",
      authoritative_source: "authoritative_classification",
    },
  };
}
