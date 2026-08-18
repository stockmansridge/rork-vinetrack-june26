// Supabase Edge Function: chemical-info-lookup
//
// Server-side AI proxy for chemical search and product info lookup.
// Keeps the OpenAI API key off the device.
//
// Request (POST JSON):
//   { "action": "search", "query": string, "country"?: string }
//   { "action": "info",   "productName": string, "country"?: string }
//   { "action": "structured", "productName": string, "country"?: string,
//     "registrationNumber"?: string }   // optional identity hint (sql/199)
//
// Response 200 JSON shapes:
//   action=search -> { results: ChemicalSearchResult[] }  (approved master
//                     catalogue hits are listed FIRST, tagged source:"master")
//   action=info   -> ChemicalInfoResponse
//   action=structured -> the sql/194 structured contract, plus (sql/199):
//       match_source: "master" | "ai_candidate" | "unresolved"
//       master?: { master_chemical_id, master_revision, catalogue_status,
//                  registration_identity_key }        (master matches only)
//
// Errors return { error: string } with appropriate HTTP status.

// deno-lint-ignore-file no-explicit-any

// ---------------------------------------------------------------------------
// Authoritative activity-group classification for common viticultural actives.
//
// INLINED DELIBERATELY. Edge function deployment uploads only this entrypoint,
// so a sibling module cannot be resolved by the bundler. Keep this block inside
// index.ts — splitting it back out into its own file will break deployment.
//
// This is the server-side twin of the iOS `AuthoritativeActivityGroups` and the
// Android `AuthoritativeActivityGroups` object. All three MUST agree — the whole
// point is that a product's activity group has one answer, not three. When you
// change one, change all three and bump ACTIVITY_GROUP_TABLE_VERSION.
//
// It exists so the AI extraction is never the only opinion in the room. Whatever
// the model says an active's group is, it is checked against this table before
// the response leaves the server, and a disagreement is returned as an explicit
// conflict rather than silently overwritten.
//
// Activity group is a property of the ACTIVE, not of a brand, and it does not
// vary by country — which is why this table has no country dimension while
// product identity emphatically does.
// ---------------------------------------------------------------------------

/** Bump whenever the table changes. Stamped onto every verification. */
const ACTIVITY_GROUP_TABLE_VERSION = 1;

type ActivityGroupScheme = "frac" | "hrac" | "irac" | "not_applicable";

interface ActivityGroup {
  scheme: ActivityGroupScheme;
  code: string;
  common_name?: string | null;
}

const frac = (code: string, name: string): ActivityGroup => ({
  scheme: "frac",
  code,
  common_name: name,
});
const hrac = (code: string, name: string): ActivityGroup => ({
  scheme: "hrac",
  code,
  common_name: name,
});
const irac = (code: string, name: string): ActivityGroup => ({
  scheme: "irac",
  code,
  common_name: name,
});

const ACTIVITY_GROUP_TABLE: Record<string, ActivityGroup> = {
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

  // ---- Herbicides (HRAC) ----
  "glyphosate": hrac("G", "EPSP synthase inhibitor"),
  "glufosinate": hrac("H", "Glutamine synthetase inhibitor"),
  "glufosinate ammonium": hrac("H", "Glutamine synthetase inhibitor"),
  "paraquat": hrac("D", "PSI electron diverter"),
  "diquat": hrac("D", "PSI electron diverter"),
  "simazine": hrac("C1", "PSII inhibitor"),
  "diuron": hrac("C2", "PSII inhibitor"),
  "amitrole": hrac("F3", "Carotenoid biosynthesis inhibitor"),
  "oxyfluorfen": hrac("E", "PPO inhibitor"),
  "carfentrazone": hrac("E", "PPO inhibitor"),
  "flumioxazin": hrac("E", "PPO inhibitor"),
  "haloxyfop": hrac("A", "ACCase inhibitor"),
  "clethodim": hrac("A", "ACCase inhibitor"),
  "fluazifop": hrac("A", "ACCase inhibitor"),
  "sethoxydim": hrac("A", "ACCase inhibitor"),
  "propyzamide": hrac("K1", "Microtubule assembly inhibitor"),
  "pendimethalin": hrac("K1", "Microtubule assembly inhibitor"),
  "trifluralin": hrac("K1", "Microtubule assembly inhibitor"),
  "isoxaben": hrac("L", "Cellulose synthesis inhibitor"),
  "indaziflam": hrac("L", "Cellulose synthesis inhibitor"),
  "metsulfuron methyl": hrac("B", "ALS inhibitor"),
  "chlorsulfuron": hrac("B", "ALS inhibitor"),
  "imazapyr": hrac("B", "ALS inhibitor"),
  "2,4 d": hrac("O", "Synthetic auxin"),
  "mcpa": hrac("O", "Synthetic auxin"),
  "triclopyr": hrac("O", "Synthetic auxin"),
  "clopyralid": hrac("O", "Synthetic auxin"),
  "pelargonic acid": hrac("Z", "Unknown / non-selective contact"),

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

function normaliseActiveName(raw: string): string {
  return raw.trim().toLowerCase().replace(/-/g, " ").replace(/\s+/g, " ");
}

/**
 * Strips the noise humans and AI put around a code so "Group 3", "group3" and
 * "11 (QoI / Strobilurin)" all reduce to a bare code.
 */
function normaliseCode(raw: string): string {
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
 * Returns null when the active is not in the table — which means UNKNOWN, never
 * "the extraction must be right". Callers must not read null as permission to
 * trust an unverified extraction.
 */
function authoritativeGroup(activeName: string): ActivityGroup | null {
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

interface GroupConflict {
  field: string;
  active_ingredient_name: string;
  extracted_value: string;
  authoritative_value: string;
  extracted_source: string;
  authoritative_source: string;
}

interface Reconciliation {
  group: ActivityGroup | null;
  /** Which source the returned group may be attributed to. */
  source: string | null;
  conflict: GroupConflict | null;
}

function displayLabel(g: ActivityGroup): string {
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
function reconcileGroup(
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
  if (extracted.scheme === authoritative.scheme && extracted.code === authoritative.code) {
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

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") ?? "gpt-4o";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function callOpenAI(
  systemPrompt: string,
  userPrompt: string,
  apiKey: string,
): Promise<string> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      response_format: { type: "json_object" },
      temperature: 0.2,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
    }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OpenAI HTTP ${res.status}: ${text.slice(0, 200)}`);
  }
  const data: any = await res.json();
  const content: string | undefined = data?.choices?.[0]?.message?.content;
  if (!content) throw new Error("Empty response from AI provider");
  return content;
}

function buildSearchPrompt(query: string, country: string): {
  system: string;
  user: string;
} {
  const system =
    "You are an agricultural and viticultural input database expert covering ALL types of vineyard inputs across global and regional markets, including small specialty manufacturers (e.g. Switch AG, Stoller, Omnia, Campbells, AgNova, Grochem, Sipcam, ADAMA, Nufarm, Syngenta, Bayer, Corteva, BASF, UPL, FMC). You know niche Australian, New Zealand, US, EU, South African, and South American brands — not just the top mainstream products. You respond ONLY with valid JSON, no markdown, no explanation, no code fences.";
  const countryContext = country
    ? ` IMPORTANT: The vineyard is located in ${country}. You MUST prioritize products that are registered, sold, and commonly used in ${country}, including small specialty/regional brands. List ${country}-registered brand names first. Use ${country}-based manufacturers and distributors. Only include international/generic products if fewer than 8 local ${country} products match the query.`
    : "";
  const user =
    `Search for agricultural/viticultural inputs matching "${query}".${countryContext}\n\nConsider ALL of the following input categories — do NOT restrict to mainstream crop protection only:\n- Fungicides, herbicides, insecticides, miticides, nematicides, bactericides\n- Plant growth regulators (PGRs)\n- Surfactants, adjuvants, wetters, stickers, penetrants\n- Fertilisers (granular, liquid, foliar, fertigation)\n- Biostimulants (amino acids, seaweed/kelp, humic/fulvic acid, fish hydrolysate, microbial)\n- Foliar nutrients and trace elements (Ca, Mg, Zn, B, Mn, Fe, Mo, Cu)\n- Soil conditioners, gypsum, lime, compost teas\n- Biological controls (Trichoderma, Bacillus, mycorrhizae)\n- Specialty/niche regional products from small manufacturers (e.g. Switch AG amino acid range, Stoller, Omnia Nutriology, Campbells Liquifert, AgNova, Grochem)\n\nMatch broadly: brand names, product line names, active ingredients, manufacturer names, partial matches, fuzzy matches, and common misspellings. If the query mentions a manufacturer (e.g. "Switch AG"), list THAT manufacturer's products even if niche. Include products even if they are less common — do not filter out specialty/biostimulant/nutrition products. Return up to 8 products as JSON:\n{"results":[{"name":"Product name","activeIngredient":"active ingredient(s) or key components for biostimulants/fertilisers","chemicalGroup":"group e.g. Strobilurin, Triazole, Biostimulant - Amino Acid, Foliar Fertiliser - N","brand":"manufacturer","primaryUse":"primary use in vineyard e.g. Downy Mildew control, Foliar nitrogen, Stress recovery, Flowering biostimulant","modeOfAction":"MOA classification - REQUIRED for all crop protection products. Use the official resistance management code with a short name, e.g. \"11 (QoI / Strobilurin)\", \"3 (DMI / Triazole)\", \"M5 (Multi-site / Chlorothalonil)\", \"4A (Neonicotinoid)\", \"G (Glycine)\". Use FRAC codes for fungicides, HRAC for herbicides, IRAC for insecticides/miticides. Always look up and provide MOA — do NOT leave blank for crop protection products. Only return empty string for pure biostimulants, fertilisers, adjuvants, or surfactants where MOA does not apply."}]}`;
  return { system, user };
}

function buildInfoPrompt(productName: string, country: string): {
  system: string;
  user: string;
} {
  const system =
    "You are an agricultural and viticultural input database expert covering crop protection, fertilisers, foliar nutrients, biostimulants (amino acid, seaweed, humic), adjuvants, and biological controls from both major and small specialty manufacturers globally (including niche Australian/NZ brands like Switch AG, AgNova, Grochem, Campbells, Omnia, Stoller). You respond ONLY with valid JSON, no markdown, no explanation, no code fences. CRITICAL: You must NEVER fabricate, guess, or construct URLs. URLs are validated against the live web after you respond and hallucinated URLs are dropped — but they also waste user trust. Default to empty strings for any URL you are not 100% certain exists.";
  const countryContext = country
    ? ` IMPORTANT: The vineyard is located in ${country}. You MUST use the ${country}-registered version of this product. Provide ${country}-specific brand name and label rates. If the product has a different brand name in ${country}, use the ${country} brand name.`
    : "";
  const user = `Provide details for the agricultural product "${productName}".${countryContext} Find the closest match if exact name not found. Include recommended application rates for vineyard/viticultural use where available. Return as JSON:
{"activeIngredient":"active ingredient(s)","brand":"manufacturer","chemicalGroup":"group classification","labelURL":"STRICT: Direct https URL to the OFFICIAL product LABEL document (PDF strongly preferred) hosted by the manufacturer, registrant, or a national regulator (APVMA, EPA, ACVM, EU register). MUST point directly at the label/SDS file, NOT a product marketing page, NOT a brand homepage, NOT a category/search page. If you cannot recall the exact label file URL with certainty, return an empty string. NEVER construct URLs from product names. NEVER guess paths like /products/<slug>. NEVER use example.com, placeholder.com, manufacturer.com, etc. When in doubt: empty string.","productURL":"Optional. The manufacturer's product information page (marketing/landing page) if you are confident the URL exists. Empty string if unsure. This is separate from labelURL and must NEVER be returned as labelURL.","sdsURL":"Optional. Direct https URL to the official Safety Data Sheet PDF if you are certain it exists. Empty string if unsure.","primaryUse":"primary use in vineyard e.g. Downy Mildew control, Nitrogen fertiliser, Botrytis prevention","formType":"liquid or solid","modeOfAction":"MOA classification - REQUIRED for all crop protection products. Use the official resistance management code with a short name, e.g. \"11 (QoI / Strobilurin)\", \"3 (DMI / Triazole)\", \"M5 (Multi-site / Chlorothalonil)\", \"4A (Neonicotinoid)\". Use FRAC for fungicides, HRAC for herbicides, IRAC for insecticides/miticides. Always look up and provide MOA — do NOT leave blank for crop protection products. Only return empty string for pure biostimulants, fertilisers, adjuvants, or surfactants where MOA does not apply.","ratesPerHectare":[{"label":"Standard rate","value":1.5}],"ratesPer100L":[{"label":"Standard rate","value":0.15}]}
IMPORTANT: The "formType" field must be either "liquid" or "solid". Determine this from the product's physical form. Liquid products (EC, SC, SL, SE, EW, flowables, suspension concentrates, emulsifiable concentrates, soluble liquids) should be "liquid". Solid products (WG, WDG, WP, DF, granules, wettable powders, dry flowables, water dispersible granules) should be "solid".
The ratesPerHectare array should contain recommended rates per hectare. For liquid products, values must be in Litres (L). For solid products, values must be in Kilograms (Kg). The ratesPer100L array should contain recommended rates per 100 litres of water, using the same unit convention. Include multiple rates if the label specifies different rates for different conditions (e.g. low/medium/high disease pressure). If rates are not available for a basis, return an empty array.`;
  return { system, user };
}

// ===========================================================================
// Structured chemical intelligence (action="structured")
// ===========================================================================
//
// The AI is an EXTRACTION AND MATCHING ASSISTANT here, not the authority. The
// intended source hierarchy is:
//
//   official registered product/label source
//     -> structured active ingredient information
//       -> authoritative activity-group classification
//         -> viticulture-specific cross-check
//           -> AI/search interpretation          <- what we actually have today
//
// Be honest about what this deployment can reach: there is no live APVMA or
// ACVM API wired up, so the model's reading of public label/register material
// is the only extraction source. Everything it produces is therefore attributed
// to `ai_interpretation` and can NEVER, on its own, make a product Verified.
// The one genuinely authoritative thing running server-side is the FRAC/HRAC/
// IRAC classification table, which is applied to every active AFTER extraction.

const REGISTER_BY_COUNTRY: Record<string, string> = {
  AU: "the APVMA public register (PUBCRIS) product number",
  AUSTRALIA: "the APVMA public register (PUBCRIS) product number",
  NZ: "the NZ ACVM register number (and the EPA/HSNO approval number if that is what the label quotes)",
  "NEW ZEALAND":
    "the NZ ACVM register number (and the EPA/HSNO approval number if that is what the label quotes)",
};

function registrationSchemeFor(country: string): string | null {
  const c = country.trim().toUpperCase();
  if (c === "AU" || c === "AUSTRALIA") return "apvma";
  if (c === "NZ" || c === "NEW ZEALAND") return "acvm";
  return null;
}

function countryCodeFor(country: string): string {
  const c = country.trim().toUpperCase();
  if (c === "AU" || c === "AUSTRALIA") return "AU";
  if (c === "NZ" || c === "NEW ZEALAND") return "NZ";
  return c.length === 2 ? c : "";
}

function buildStructuredPrompt(productName: string, country: string): {
  system: string;
  user: string;
} {
  const system =
    "You extract structured agricultural product registration data. You respond ONLY with valid JSON " +
    "— no markdown, no explanation, no code fences.\n\n" +
    "CRITICAL RULES:\n" +
    "1. NEVER invent a registration number, a concentration, or a URL. If you are not certain, return null.\n" +
    "2. A field you cannot establish MUST be null AND its name MUST appear in `unresolved`. " +
    "Returning null with an honest `unresolved` entry is ALWAYS better than a plausible guess — " +
    "a wrong active ingredient concentration causes a real mis-dose in a real vineyard.\n" +
    "3. Product identity is COUNTRY-SPECIFIC. A product name used in Australia is NOT automatically " +
    "the same registered product in New Zealand. Never carry rates, actives or registration numbers " +
    "across countries.\n" +
    "4. List EVERY active ingredient separately. A mixture has multiple actives, each with its own " +
    "concentration and its own resistance group.";

  const register = REGISTER_BY_COUNTRY[country.trim().toUpperCase()] ??
    "the national pesticide register that applies in that country";
  const countryContext = country
    ? `The vineyard is in ${country}. Use ONLY the ${country}-registered version of this product. ` +
      `For the registration identifier use ${register}. If this product is not registered in ${country}, ` +
      `say so by returning null for registration and adding "registration" to unresolved — do NOT ` +
      `substitute the registration from another country.`
    : "No country was supplied, so return null for registration and add \"country\" to unresolved.";

  const user = `Provide structured registration data for the agricultural product "${productName}".
${countryContext}

Return EXACTLY this JSON shape:
{
  "product_name": "exact registered product name, or null",
  "registrant": "registrant/manufacturer of record, or null",
  "registration_number": "register product number as printed, or null",
  "label_reference": "direct https URL to the official label PDF if you are certain it exists, else null",
  "label_version": "label approval date or version if known, else null",
  "product_category": "one of: fungicide, herbicide, insecticide, miticide, adjuvant, growthRegulator, foliarNutrient, granularFertiliser, liquidFertiliser, biostimulant, other",
  "form_type": "liquid or solid",
  "active_ingredients": [
    {
      "name": "ISO common name of the active, e.g. Tebuconazole",
      "concentration": 200,
      "concentration_unit": "g/L | g/kg | % w/w | % w/v | CFU/g",
      "activity_group_code": "resistance code only, e.g. 3, 11, M5, 4A, G — no words",
      "activity_group_scheme": "frac | hrac | irac | not_applicable"
    }
  ],
  "registered_uses": [
    {
      "crop": "e.g. Grapes (winegrapes)",
      "target": "target pest/disease exactly as the label words it, e.g. Powdery mildew",
      "rates": [
        {
          "label": "e.g. Standard rate, or Low disease pressure",
          "basis": "per_100_litres | per_hectare | range_per_100_litres | range_per_hectare | other",
          "value": 1.5,
          "min_value": null,
          "max_value": null,
          "unit": "L | mL | kg | g",
          "raw_text": "verbatim label wording when basis is other, else null"
        }
      ],
      "withholding_period_days": 14,
      "re_entry_period_hours": null,
      "restrictions": "short label restriction text, or null"
    }
  ],
  "unresolved": ["names of any fields above you could not establish"]
}

NOTES ON RATE BASIS — this matters and is frequently confused:
- The rate basis is what the LABEL quotes the product rate against. It is NOT how the sprayer
  measures water volume. A vineyard that measures carrier in L/100 m still applies a product whose
  label says 1.5 L/ha. Never convert a label rate into L/100 m.
- Use "range_per_hectare" / "range_per_100_litres" (with min_value and max_value) when the label
  gives a band rather than a single figure. Do not collapse a range to its midpoint.
- Only include registered_uses you are confident are on the label. Do NOT infer a registered use
  from the chemistry — "it is a Group 11 so it must control powdery mildew" is exactly the kind of
  inference that must not appear here. An empty registered_uses array is a valid, honest answer.`;
  return { system, user };
}

function parseNumber(value: any): number | null {
  if (typeof value === "number" && isFinite(value)) return value;
  if (typeof value === "string") {
    const n = Number(value.trim());
    if (isFinite(n)) return n;
  }
  return null;
}

function parseString(value: any): string | null {
  if (typeof value !== "string") return null;
  const t = value.trim();
  if (!t || t.toLowerCase() === "null" || t.toLowerCase() === "unknown") return null;
  return t;
}

const RATE_BASES = new Set([
  "per_100_litres",
  "per_hectare",
  "range_per_100_litres",
  "range_per_hectare",
  "other",
]);

function normaliseRegisteredUses(raw: any): any[] {
  if (!Array.isArray(raw)) return [];
  const out: any[] = [];
  for (const use of raw) {
    const crop = parseString(use?.crop);
    const target = parseString(use?.target) ?? parseString(use?.target_raw);
    if (!crop && !target) continue;
    const rates: any[] = [];
    if (Array.isArray(use?.rates)) {
      for (const r of use.rates) {
        let basis = parseString(r?.basis)?.toLowerCase() ?? "other";
        if (!RATE_BASES.has(basis)) basis = "other";
        const value = parseNumber(r?.value);
        const minValue = parseNumber(r?.min_value);
        const maxValue = parseNumber(r?.max_value);
        // A rate with no number at all is only meaningful if the label text was
        // captured verbatim; otherwise it says nothing and is dropped.
        const rawText = parseString(r?.raw_text);
        if (value === null && minValue === null && !rawText) continue;
        rates.push({
          label: parseString(r?.label) ?? "",
          basis,
          value,
          min_value: minValue,
          max_value: maxValue,
          unit: parseString(r?.unit) ?? "",
          raw_text: rawText,
        });
      }
    }
    out.push({
      crop: crop ?? "",
      target_raw: target ?? "",
      rates,
      withholding_period_days: parseNumber(use?.withholding_period_days),
      re_entry_period_hours: parseNumber(use?.re_entry_period_hours),
      restrictions: parseString(use?.restrictions),
    });
  }
  return out;
}

const SCHEMES: ActivityGroupScheme[] = ["frac", "hrac", "irac", "not_applicable"];

function schemeFromCategory(category: string | null): ActivityGroupScheme | null {
  switch ((category ?? "").toLowerCase()) {
    case "fungicide":
      return "frac";
    case "herbicide":
      return "hrac";
    case "insecticide":
    case "miticide":
      return "irac";
    case "adjuvant":
    case "foliarnutrient":
    case "granularfertiliser":
    case "liquidfertiliser":
    case "biostimulant":
      return "not_applicable";
    default:
      return null;
  }
}

/**
 * Turns the model's raw extraction into the structured contract, then applies
 * the authoritative activity-group cross-check to every active.
 *
 * The verification status returned here is computed from EVIDENCE, never from
 * how confident the model sounded:
 *   - any group disagreement                       -> "conflict"
 *   - no actives established                       -> "unverified"
 *   - actives + registration + every group backed
 *     by the authoritative table                   -> "partially_verified"
 *
 * Note what is deliberately absent: this function NEVER returns "verified".
 * With no live official register available to this deployment, product identity
 * cannot be authoritatively confirmed server-side, so the highest honest state
 * is partially verified. Promotion to Verified is a human decision made in the
 * app's verify step. That ceiling is the entire point of Phase 4.
 */
function buildStructuredResponse(parsed: any, country: string): any {
  const unresolved = new Set<string>(
    Array.isArray(parsed?.unresolved)
      ? parsed.unresolved.filter((x: any) => typeof x === "string")
      : [],
  );

  const productCategory = parseString(parsed?.product_category);
  const categoryScheme = schemeFromCategory(productCategory);
  const conflicts: GroupConflict[] = [];
  const actives: any[] = [];

  const rawActives = Array.isArray(parsed?.active_ingredients)
    ? parsed.active_ingredients
    : [];

  for (const a of rawActives) {
    const name = parseString(a?.name);
    if (!name) continue;

    const code = normaliseCode(String(a?.activity_group_code ?? ""));
    let scheme = parseString(a?.activity_group_scheme)?.toLowerCase() as
      | ActivityGroupScheme
      | undefined;
    if (!scheme || !SCHEMES.includes(scheme)) {
      scheme = categoryScheme ?? undefined;
    }
    const extracted: ActivityGroup | null = code && scheme && scheme !== "not_applicable"
      ? { scheme, code, common_name: null }
      : null;

    // THE cross-check. Whatever the model said, the authoritative table gets
    // the last word, and any disagreement is surfaced rather than resolved.
    const { group, source, conflict } = reconcileGroup(name, extracted);
    if (conflict) conflicts.push(conflict);
    if (!group) unresolved.add(`activity_group:${name}`);

    const concentration = parseNumber(a?.concentration);
    if (concentration === null) unresolved.add(`concentration:${name}`);

    actives.push({
      name,
      concentration,
      concentration_unit: parseString(a?.concentration_unit),
      activity_group: group,
      group_source: source,
      identity_source: "ai_interpretation",
    });
  }

  if (!actives.length) unresolved.add("active_ingredients");

  const registrationNumber = parseString(parsed?.registration_number);
  const countryCode = countryCodeFor(country);
  if (!registrationNumber) unresolved.add("registration_number");
  if (!countryCode) unresolved.add("country");

  const registration = registrationNumber || countryCode
    ? {
      country_code: countryCode,
      scheme: registrationNumber ? registrationSchemeFor(country) : null,
      registration_number: registrationNumber,
      registrant: parseString(parsed?.registrant),
      registered_product_name: parseString(parsed?.product_name),
      label_reference: parseString(parsed?.label_reference),
      label_version: parseString(parsed?.label_version),
    }
    : null;

  const registeredUses = normaliseRegisteredUses(parsed?.registered_uses);
  if (!registeredUses.length) unresolved.add("registered_uses");

  const sources: any[] = [
    {
      kind: "ai_interpretation",
      name: `Model extraction (${OPENAI_MODEL})`,
      reference: null,
      retrieved_at: new Date().toISOString(),
    },
  ];
  // Only cite the authoritative table when it actually contributed something.
  if (actives.some((a) => a.group_source === "authoritative_classification")) {
    sources.push({
      kind: "authoritative_classification",
      name: `VineTrack activity group reference v${ACTIVITY_GROUP_TABLE_VERSION} (FRAC/HRAC/IRAC)`,
      reference: null,
      retrieved_at: new Date().toISOString(),
    });
  }

  let status: string;
  if (conflicts.length) {
    status = "conflict";
  } else if (!actives.length) {
    status = "unverified";
  } else {
    status = "partially_verified";
  }

  const schemeUsed = actives
    .map((a) => a.activity_group?.scheme)
    .find((s: string | undefined) => s && s !== "not_applicable") ?? null;

  return {
    product_name: parseString(parsed?.product_name),
    product_category: productCategory ?? "",
    form_type: parseString(parsed?.form_type),
    registration,
    active_ingredients: actives,
    // Bare codes for the queryable column: ["3", "11"] — never ["3 + 11"].
    activity_groups: Array.from(
      new Set(
        actives
          .map((a) => a.activity_group?.code)
          .filter((c: string | undefined): c is string => Boolean(c)),
      ),
    ),
    activity_group_scheme: schemeUsed,
    registered_uses: registeredUses,
    label_rate_bases: Array.from(
      new Set(
        registeredUses.flatMap((u) => u.rates.map((r: any) => r.basis)),
      ),
    ),
    verification: {
      status,
      sources,
      conflicts,
      unresolved_fields: Array.from(unresolved).sort(),
      verified_at: null,
    },
    activity_group_table_version: ACTIVITY_GROUP_TABLE_VERSION,
    schema_version: 1,
  };
}

// ===========================================================================
// Master Chemical Catalogue (sql/199) — approved-master-first lookup
// ===========================================================================
//
// Lookup priority (Stage 1):
//   1. APPROVED master catalogue row — by exact registration identity when a
//      hint is supplied, else exact (case-insensitive) registered name or
//      exact lower-cased alias, always country-scoped. A known approved
//      product NEVER goes back through the AI.
//   2. AI extraction (unchanged honesty rules) — tagged "ai_candidate", or
//      "unresolved" when it established neither actives nor a registration.
//   3. Manual structured entry (client-side, unchanged).
//
// Identity discipline mirrors the apps: only review_status='approved' rows are
// served; a name/alias must match EXACTLY ONE row or the match is abandoned
// ("custodia" can never reach "Custodia Forte"); aliases are exact whole-string
// equality, never substrings.
//
// On an AI-path result carrying a complete registration identity, a CANDIDATE
// master row is enqueued (service-role write, deduplicated on the identity
// key, existing rows always win). Candidates are never served to lookups —
// they exist so the catalogue grows from real demand and a human admin can
// approve them against the register (sql/199 blocks approving AI provenance).
//
// EVERY catalogue call here is fail-open: any error (including sql/199 not yet
// applied) falls through to the AI path, so "not in Master" can never become
// "cannot look up".

const MASTER_TABLE_URL = (() => {
  const base = Deno.env.get("SUPABASE_URL") ?? "";
  return base ? `${base.replace(/\/+$/, "")}/rest/v1/master_chemicals` : "";
})();
const MASTER_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function masterConfigured(): boolean {
  return Boolean(MASTER_TABLE_URL && MASTER_SERVICE_KEY);
}

function masterHeaders(): Record<string, string> {
  return {
    "apikey": MASTER_SERVICE_KEY,
    "Authorization": `Bearer ${MASTER_SERVICE_KEY}`,
    "Accept": "application/json",
  };
}

/** PostgREST double-quoted value (for or=() expressions). */
function pgQuote(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** Escape LIKE/ILIKE wildcards so a product name is matched literally. */
function escapeLike(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
}

async function masterSelect(query: string): Promise<any[] | null> {
  if (!masterConfigured()) return null;
  const res = await fetch(`${MASTER_TABLE_URL}?${query}`, { headers: masterHeaders() });
  if (!res.ok) {
    // Table absent (sql/199 not applied yet) or transient failure — the
    // caller falls through to the AI path.
    try { await res.body?.cancel(); } catch { /* ignore */ }
    return null;
  }
  const rows = await res.json();
  return Array.isArray(rows) ? rows : null;
}

/**
 * Resolve the single approved master row for this request, or null.
 *
 * Identity hint first (deterministic), then exact name/alias — which must be
 * UNIQUE among approved rows for that country or nothing is returned. Never
 * fuzzy, never substring, never cross-country.
 */
async function fetchApprovedMaster(
  productName: string,
  countryCode: string,
  registrationNumber: string,
  scheme: string | null,
): Promise<any | null> {
  if (!masterConfigured() || !countryCode) return null;

  // Belt-and-braces jurisdiction assertion: whatever the query matched, the
  // row itself must belong to the requested country. Both query paths already
  // scope by country (the identity key embeds it; the name path filters on
  // registration_country), but a master row from another country must never
  // be served even if a future query edit loosens one of them.
  const inCountry = (row: any): boolean =>
    String(row?.registration_country ?? "").trim().toUpperCase() === countryCode;

  if (registrationNumber && scheme) {
    const key = `${countryCode}:${scheme}:${registrationNumber.trim().toUpperCase()}`;
    const rows = await masterSelect(
      `select=*&review_status=eq.approved` +
        `&registration_identity_key=eq.${encodeURIComponent(key)}&limit=1`,
    );
    if (rows && rows.length === 1 && inCountry(rows[0])) return rows[0];
  }

  const name = productName.trim();
  if (!name) return null;
  const nameExpr = `registered_product_name.ilike.${pgQuote(escapeLike(name))}`;
  const aliasExpr = `common_names.cs.{${pgQuote(name.toLowerCase())}}`;
  const rows = await masterSelect(
    `select=*&review_status=eq.approved` +
      `&registration_country=eq.${encodeURIComponent(countryCode)}` +
      `&or=${encodeURIComponent(`(${nameExpr},${aliasExpr})`)}&limit=2`,
  );
  if (!rows || rows.length !== 1 || !inCountry(rows[0])) return null;
  return rows[0];
}

/**
 * Serve a master row in EXACTLY the structured contract every client already
 * decodes, plus the additive master envelope. The row's own sql/194
 * verification evidence (register/label provenance recorded at review time)
 * travels with it — no AI source, no AI confidence.
 */
function buildMasterStructuredResponse(row: any): any {
  return {
    product_name: row.registered_product_name ?? null,
    product_category: row.product_category ?? "",
    form_type: row.form_type ?? null,
    registration: {
      country_code: row.registration_country ?? "",
      scheme: row.registration_scheme ?? null,
      registration_number: row.registration_number ?? null,
      registrant: row.registrant ?? null,
      registered_product_name: row.registered_product_name ?? null,
      label_reference: row.label_reference ?? null,
      label_version: row.label_version ?? null,
    },
    active_ingredients: Array.isArray(row.active_ingredients) ? row.active_ingredients : [],
    activity_groups: Array.isArray(row.activity_groups) ? row.activity_groups : [],
    activity_group_scheme: row.activity_group_scheme ?? null,
    registered_uses: Array.isArray(row.registered_uses) ? row.registered_uses : [],
    label_rate_bases: Array.isArray(row.label_rate_bases) ? row.label_rate_bases : [],
    verification: {
      status: row.verification_status ?? "unverified",
      sources: Array.isArray(row.verification_sources) ? row.verification_sources : [],
      conflicts: Array.isArray(row.verification_conflicts) ? row.verification_conflicts : [],
      unresolved_fields: Array.isArray(row.verification_unresolved_fields)
        ? row.verification_unresolved_fields
        : [],
      verified_at: row.verified_at ?? null,
    },
    activity_group_table_version: row.activity_group_table_version ?? ACTIVITY_GROUP_TABLE_VERSION,
    schema_version: row.intelligence_schema_version ?? 1,
    match_source: "master",
    master: {
      master_chemical_id: row.id,
      master_revision: row.catalogue_version ?? 1,
      catalogue_status: row.review_status ?? null,
      registration_identity_key: row.registration_identity_key ?? null,
    },
  };
}

/**
 * Enqueue an AI extraction as a CANDIDATE master row.
 *
 * Only a COMPLETE registration identity may enter the catalogue — an
 * unregistered product has no provable identity to deduplicate on and stays a
 * per-vineyard record. `resolution=ignore-duplicates` means an existing row
 * (possibly approved) always wins; this write can never update or downgrade
 * anything. Failures are logged and swallowed: enqueueing is a side effect,
 * never part of the lookup's success.
 */
async function enqueueMasterCandidate(structured: any, requestedName: string): Promise<void> {
  try {
    if (!masterConfigured()) return;
    const reg = structured?.registration;
    const country = String(reg?.country_code ?? "").trim().toUpperCase();
    const scheme = String(reg?.scheme ?? "").trim().toLowerCase();
    const number = String(reg?.registration_number ?? "").trim();
    if (!/^[A-Z]{2}$/.test(country) || !scheme || !number) return;

    const productName = String(structured?.product_name ?? "").trim();
    const names = new Set<string>();
    if (productName) names.add(productName.toLowerCase());
    const requested = requestedName.trim().toLowerCase();
    if (requested) names.add(requested);

    const res = await fetch(`${MASTER_TABLE_URL}?on_conflict=registration_identity_key`, {
      method: "POST",
      headers: {
        ...masterHeaders(),
        "Content-Type": "application/json",
        "Prefer": "resolution=ignore-duplicates,return=minimal",
      },
      body: JSON.stringify({
        registration_country: country,
        registration_scheme: scheme,
        registration_number: number,
        registrant: reg?.registrant ?? null,
        registered_product_name: productName || requestedName.trim(),
        common_names: Array.from(names),
        product_category: structured?.product_category || null,
        form_type: structured?.form_type ?? null,
        active_ingredients: structured?.active_ingredients ?? [],
        activity_groups: structured?.activity_groups ?? [],
        activity_group_scheme: structured?.activity_group_scheme ?? null,
        registered_uses: structured?.registered_uses ?? [],
        label_rate_bases: structured?.label_rate_bases ?? [],
        label_reference: reg?.label_reference ?? null,
        label_version: reg?.label_version ?? null,
        verification_status: structured?.verification?.status ?? "unverified",
        verification_sources: structured?.verification?.sources ?? [],
        verification_conflicts: structured?.verification?.conflicts ?? [],
        verification_unresolved_fields: structured?.verification?.unresolved_fields ?? [],
        source_kind: "ai_interpretation",
        retrieved_at: new Date().toISOString(),
        review_status: "candidate",
        activity_group_table_version: structured?.activity_group_table_version ??
          ACTIVITY_GROUP_TABLE_VERSION,
        intelligence_schema_version: structured?.schema_version ?? 1,
      }),
    });
    try { await res.body?.cancel(); } catch { /* ignore */ }
  } catch (err) {
    console.error(
      "master candidate enqueue skipped:",
      err instanceof Error ? err.message : String(err),
    );
  }
}

/**
 * Approved master rows matching a human search, mapped to the search-result
 * shape (additive `source`/`master_chemical_id` fields). Substring matching is
 * fine HERE — this is a discovery listing a human picks from; identity is only
 * ever established by the structured lookup's exact rules.
 */
async function searchMaster(query: string, countryCode: string): Promise<any[]> {
  try {
    if (!masterConfigured() || !countryCode) return [];
    const trimmed = query.trim();
    if (!trimmed) return [];
    const nameExpr = `registered_product_name.ilike.${pgQuote(`%${escapeLike(trimmed)}%`)}`;
    const aliasExpr = `common_names.cs.{${pgQuote(trimmed.toLowerCase())}}`;
    const rows = await masterSelect(
      `select=*&review_status=eq.approved` +
        `&registration_country=eq.${encodeURIComponent(countryCode)}` +
        `&or=${encodeURIComponent(`(${nameExpr},${aliasExpr})`)}` +
        `&order=registered_product_name.asc&limit=3`,
    );
    if (!rows) return [];
    return rows.map((row: any) => {
      const actives = Array.isArray(row.active_ingredients) ? row.active_ingredients : [];
      const groups = Array.isArray(row.activity_groups) ? row.activity_groups : [];
      const uses = Array.isArray(row.registered_uses) ? row.registered_uses : [];
      const firstUse = uses[0] ?? null;
      return {
        name: String(row.registered_product_name ?? ""),
        activeIngredient: actives
          .map((a: any) => {
            const conc = a?.concentration != null
              ? ` ${a.concentration}${a?.concentration_unit ? ` ${a.concentration_unit}` : ""}`
              : "";
            return `${String(a?.name ?? "").trim()}${conc}`.trim();
          })
          .filter((s: string) => s)
          .join(" + "),
        chemicalGroup: groups.join(" + "),
        brand: String(row.registrant ?? ""),
        primaryUse: firstUse
          ? [firstUse.target_raw, firstUse.crop ? `(${firstUse.crop})` : ""]
            .filter(Boolean).join(" ")
          : "",
        modeOfAction: groups.join(" + "),
        source: "master",
        master_chemical_id: row.id,
      };
    }).filter((r: any) => r.name);
  } catch (err) {
    console.error("master search skipped:", err instanceof Error ? err.message : String(err));
    return [];
  }
}

function extractJSON(text: string): any {
  let cleaned = text
    .replace(/```json/gi, "")
    .replace(/```/g, "")
    .trim();
  const firstBrace = cleaned.indexOf("{");
  const lastBrace = cleaned.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    cleaned = cleaned.slice(firstBrace, lastBrace + 1);
  }
  return JSON.parse(cleaned);
}

function normalizeSearchResults(parsed: any): any {
  const arr = Array.isArray(parsed?.results)
    ? parsed.results
    : Array.isArray(parsed)
    ? parsed
    : [];
  const results = arr
    .map((item: any) => {
      const name = String(item?.name ?? "").trim();
      if (!name) return null;
      return {
        name,
        activeIngredient: String(
          item?.activeIngredient ?? item?.active_ingredient ?? "",
        ),
        chemicalGroup: String(
          item?.chemicalGroup ?? item?.chemical_group ?? "",
        ),
        brand: String(item?.brand ?? item?.manufacturer ?? ""),
        primaryUse: String(item?.primaryUse ?? item?.primary_use ?? ""),
        modeOfAction: String(item?.modeOfAction ?? item?.mode_of_action ?? ""),
      };
    })
    .filter((x: any) => x);
  return { results };
}

function parseRateInfoArray(value: any): { label: string; value: number }[] {
  if (!Array.isArray(value)) return [];
  const out: { label: string; value: number }[] = [];
  for (const item of value) {
    const label = item?.label;
    if (typeof label !== "string") continue;
    let v: number | null = null;
    if (typeof item?.value === "number" && isFinite(item.value)) v = item.value;
    else if (typeof item?.value === "string") {
      const n = Number(item.value);
      if (isFinite(n)) v = n;
    }
    if (v == null) continue;
    out.push({ label, value: v });
  }
  return out;
}

function isPlaceholderURL(url: string): boolean {
  if (!url) return true;
  let host = "";
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return true;
  }
  const bad = [
    "example.com",
    "example.org",
    "example.net",
    "placeholder.com",
    "yourdomain.com",
    "domain.com",
    "manufacturer.com",
    "website.com",
    "company.com",
    "test.com",
    "localhost",
  ];
  return bad.some((b) => host === b || host.endsWith("." + b));
}

/**
 * Probe a URL with a short timeout. Returns true only when the server responds
 * with a successful (2xx) status. Tries HEAD first, falls back to a ranged GET
 * (some CDNs / WordPress hosts return 405 for HEAD on PDF uploads).
 */
async function isURLReachable(rawURL: string): Promise<boolean> {
  let target: URL;
  try {
    target = new URL(rawURL);
  } catch {
    return false;
  }
  if (target.protocol !== "https:" && target.protocol !== "http:") return false;

  const attempt = async (method: "HEAD" | "GET"): Promise<number | null> => {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 6000);
    try {
      const headers: Record<string, string> = {
        "User-Agent":
          "Mozilla/5.0 (compatible; VineTrack-ChemicalLookup/1.0; +https://rork.app)",
        "Accept": "*/*",
      };
      if (method === "GET") headers["Range"] = "bytes=0-0";
      const res = await fetch(target.toString(), {
        method,
        redirect: "follow",
        headers,
        signal: ctrl.signal,
      });
      // Drain body if any so the connection can be reused/closed.
      try { await res.body?.cancel(); } catch { /* ignore */ }
      return res.status;
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  };

  const headStatus = await attempt("HEAD");
  if (headStatus !== null && headStatus >= 200 && headStatus < 300) return true;
  // Some servers reject HEAD with 4xx but serve GET correctly.
  if (headStatus === null || headStatus === 403 || headStatus === 404 || headStatus === 405 || headStatus === 501) {
    const getStatus = await attempt("GET");
    if (getStatus !== null && getStatus >= 200 && getStatus < 300) return true;
  }
  return false;
}

/**
 * Reject obvious non-label URLs even when they're reachable, e.g. brand
 * homepages or generic product search pages that the AI sometimes substitutes
 * when it doesn't know the real PDF.
 */
function looksLikeLabelURL(rawURL: string): boolean {
  let u: URL;
  try {
    u = new URL(rawURL);
  } catch {
    return false;
  }
  const path = u.pathname.toLowerCase();
  // Bare homepage / brand root is never a label.
  if (path === "" || path === "/") return false;
  // Generic search/category pages.
  if (/\/(search|category|categories|tag|tags)\b/.test(path)) return false;
  return true;
}

async function normalizeInfo(parsed: any): Promise<any> {
  const activeIngredient = String(
    parsed?.activeIngredient ?? parsed?.active_ingredient ?? "",
  );
  const brand = String(parsed?.brand ?? parsed?.manufacturer ?? "");
  const chemicalGroup = String(
    parsed?.chemicalGroup ?? parsed?.chemical_group ?? "",
  );
  const rawLabelURL = String(
    parsed?.labelURL ?? parsed?.label_url ?? parsed?.labelUrl ?? "",
  ).trim();
  const rawProductURL = String(
    parsed?.productURL ?? parsed?.product_url ?? parsed?.productUrl ?? "",
  ).trim();
  const rawSDSURL = String(
    parsed?.sdsURL ?? parsed?.sds_url ?? parsed?.sdsUrl ?? "",
  ).trim();

  /**
   * Validate a candidate URL: reject placeholders, reject brand homepages,
   * then verify the URL is actually reachable. Hallucinated URLs are dropped.
   */
  const validate = async (raw: string, requireLabelShape: boolean): Promise<string> => {
    if (!raw) return "";
    if (isPlaceholderURL(raw)) return "";
    if (requireLabelShape && !looksLikeLabelURL(raw)) return "";
    const ok = await isURLReachable(raw);
    return ok ? raw : "";
  };

  // Validate in parallel.
  const [labelURL, productURL, sdsURL] = await Promise.all([
    validate(rawLabelURL, true),
    validate(rawProductURL, false),
    validate(rawSDSURL, true),
  ]);

  const primaryUse = String(parsed?.primaryUse ?? parsed?.primary_use ?? "");
  const formType = parsed?.formType ?? parsed?.form_type ?? null;
  const modeOfAction = parsed?.modeOfAction ?? parsed?.mode_of_action ?? null;
  const ratesPerHectare = parseRateInfoArray(
    parsed?.ratesPerHectare ?? parsed?.rates_per_hectare,
  );
  const ratesPer100L = parseRateInfoArray(
    parsed?.ratesPer100L ?? parsed?.rates_per_100l ?? parsed?.ratesPer100l,
  );
  return {
    activeIngredient,
    brand,
    chemicalGroup,
    labelURL,
    productURL,
    sdsURL,
    primaryUse,
    formType: typeof formType === "string" ? formType : null,
    modeOfAction: typeof modeOfAction === "string" ? modeOfAction : null,
    ratesPerHectare,
    ratesPer100L,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
  if (!apiKey) {
    return json(
      { error: "Server is missing OPENAI_API_KEY secret" },
      500,
    );
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const action = String(body?.action ?? "").toLowerCase();
  const country = typeof body?.country === "string"
    ? body.country.trim()
    : "";

  try {
    if (action === "search") {
      const query = typeof body?.query === "string" ? body.query.trim() : "";
      if (!query) return json({ error: "Missing query" }, 400);
      if (query.length > 200) {
        return json({ error: "Query too long" }, 400);
      }
      // Master catalogue first (sql/199): approved, country-scoped rows lead
      // the list. The AI still runs so unknown products keep surfacing — and
      // if the AI provider fails, master hits alone are a valid answer.
      const masterHits = await searchMaster(query, countryCodeFor(country));
      try {
        const { system, user } = buildSearchPrompt(query, country);
        const raw = await callOpenAI(system, user, apiKey);
        const parsed = extractJSON(raw);
        const normalized = normalizeSearchResults(parsed);
        if (masterHits.length) {
          const seen = new Set(masterHits.map((m: any) => m.name.toLowerCase()));
          normalized.results = [
            ...masterHits,
            ...normalized.results.filter(
              (r: any) => !seen.has(String(r?.name ?? "").toLowerCase()),
            ),
          ];
        }
        return json(normalized);
      } catch (err) {
        if (masterHits.length) return json({ results: masterHits });
        throw err;
      }
    }

    if (action === "structured") {
      const productName = typeof body?.productName === "string"
        ? body.productName.trim()
        : "";
      if (!productName) return json({ error: "Missing productName" }, 400);
      if (productName.length > 200) {
        return json({ error: "productName too long" }, 400);
      }

      // 1) Approved master catalogue (sql/199). A hit short-circuits the AI
      //    entirely; any catalogue failure falls through to the AI unchanged.
      const registrationNumber = typeof body?.registrationNumber === "string"
        ? body.registrationNumber.trim()
        : "";
      try {
        const masterRow = await fetchApprovedMaster(
          productName,
          countryCodeFor(country),
          registrationNumber,
          registrationSchemeFor(country),
        );
        if (masterRow) return json(buildMasterStructuredResponse(masterRow));
      } catch (err) {
        console.error(
          "master lookup fell through:",
          err instanceof Error ? err.message : String(err),
        );
      }

      // 2) AI extraction, exactly as before.
      const { system, user } = buildStructuredPrompt(productName, country);
      const raw = await callOpenAI(system, user, apiKey);
      const parsed = extractJSON(raw);
      const structured = buildStructuredResponse(parsed, country);
      // Validate the label URL exactly as `info` does; a hallucinated label
      // link is worse than none, because it looks like evidence.
      const labelRef = structured.registration?.label_reference;
      if (labelRef) {
        const ok = !isPlaceholderURL(labelRef) &&
          looksLikeLabelURL(labelRef) &&
          await isURLReachable(labelRef);
        if (!ok) {
          structured.registration.label_reference = null;
          structured.verification.unresolved_fields = Array.from(
            new Set([...structured.verification.unresolved_fields, "label_reference"]),
          ).sort();
        }
      }
      // Additive envelope: what kind of answer this is. "unresolved" means
      // the AI established neither actives nor a registration — the client
      // should route the operator to manual entry rather than pretending.
      structured.match_source =
        (structured.active_ingredients.length > 0 ||
            structured.registration?.registration_number)
          ? "ai_candidate"
          : "unresolved";

      // 3) Grow the catalogue: identity-complete AI results become CANDIDATE
      //    rows for human review. Never blocks or fails the lookup.
      await enqueueMasterCandidate(structured, productName);

      return json(structured);
    }

    if (action === "info") {
      const productName = typeof body?.productName === "string"
        ? body.productName.trim()
        : "";
      if (!productName) return json({ error: "Missing productName" }, 400);
      if (productName.length > 200) {
        return json({ error: "productName too long" }, 400);
      }
      const { system, user } = buildInfoPrompt(productName, country);
      const raw = await callOpenAI(system, user, apiKey);
      const parsed = extractJSON(raw);
      const normalized = await normalizeInfo(parsed);
      return json(normalized);
    }

    return json({ error: "Unknown action" }, 400);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message }, 502);
  }
});
