// Supabase Edge Function: chemical-info-lookup
//
// Server-side AI proxy for chemical search and product info lookup.
// Keeps the OpenAI API key off the device.
//
// Request (POST JSON):
//   { "action": "search", "query": string, "country"?: string }
//   { "action": "info",   "productName": string, "country"?: string }
//
// Response 200 JSON shapes:
//   action=search -> { results: ChemicalSearchResult[] }
//   action=info   -> ChemicalInfoResponse
//
// Errors return { error: string } with appropriate HTTP status.

// deno-lint-ignore-file no-explicit-any

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
      const { system, user } = buildSearchPrompt(query, country);
      const raw = await callOpenAI(system, user, apiKey);
      const parsed = extractJSON(raw);
      return json(normalizeSearchResults(parsed));
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
