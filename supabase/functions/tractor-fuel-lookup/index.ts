// Supabase Edge Function: tractor-fuel-lookup
//
// Server-side AI proxy for estimating tractor fuel consumption (L/hr)
// under working load. Keeps the OpenAI API key off the device.
//
// Request (POST JSON):
//   { "brand": string, "model": string, "year"?: number }
//
// Response 200 JSON:
//   {
//     fuelUsageLPerHour: number,
//     notes?: string,
//     confidence?: string,        // "low" | "medium" | "high"
//     matchedBrand?: string,      // brand AI actually referenced
//     matchedModel?: string,      // model AI actually referenced
//     matchedYearRange?: string   // e.g. "2018-2021" or "2020"
//   }
//
// Errors return { error: string } with appropriate HTTP status.

// deno-lint-ignore-file no-explicit-any

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") ?? "gpt-4o-mini";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function callOpenAI(
  prompt: string,
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
      temperature: 0.1,
      messages: [
        {
          role: "system",
          content:
            "You are an agricultural equipment expert. Respond ONLY with valid JSON, no markdown or commentary.",
        },
        { role: "user", content: prompt },
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

  const brand = typeof body?.brand === "string" ? body.brand.trim() : "";
  const model = typeof body?.model === "string" ? body.model.trim() : "";
  const yearRaw = body?.year;
  let year: number | null = null;
  if (typeof yearRaw === "number" && isFinite(yearRaw)) year = yearRaw;
  else if (typeof yearRaw === "string" && yearRaw.trim()) {
    const n = Number(yearRaw);
    if (isFinite(n)) year = n;
  }

  if (!brand || !model) {
    return json({ error: "Missing brand or model" }, 400);
  }
  if (brand.length > 80 || model.length > 80) {
    return json({ error: "brand/model too long" }, 400);
  }

  const yearPart = year != null ? ` ${year}` : "";
  const prompt =
    `What is the typical fuel consumption rate in litres per hour (L/hr) for a${yearPart} ${brand} ${model} tractor when the engine is under load?
I need the figure for real field working conditions — for example, pulling a sprayer or implement through a vineyard at typical PTO operating RPM.
Do NOT provide the idle or stationary fuel consumption. Provide the average consumption under moderate to heavy working load.
Use the model year to narrow down the specific engine/spec variant if relevant.
Also echo back the exact brand, model and production year range you used so the user can confirm you referenced the correct tractor.
Return ONLY a JSON object with no other text, in this exact format:
{"fuelUsageLPerHour": 8.5, "confidence": "low|medium|high", "notes": "short caveat", "matchedBrand": "John Deere", "matchedModel": "5075E", "matchedYearRange": "2018-2021"}
If you cannot identify the tractor at all, set confidence to "low" and matchedModel to an empty string.
If you are unsure of the exact model or year, provide your best estimate for a similar tractor in that brand's lineup under working load and set confidence to "low".
Return ONLY valid JSON, nothing else.`;

  try {
    const raw = await callOpenAI(prompt, apiKey);
    const parsed = extractJSON(raw);
    let fuel: number | null = null;
    if (typeof parsed?.fuelUsageLPerHour === "number") {
      fuel = parsed.fuelUsageLPerHour;
    } else if (typeof parsed?.fuelUsageLPerHour === "string") {
      const n = Number(parsed.fuelUsageLPerHour);
      if (isFinite(n)) fuel = n;
    }
    if (fuel == null || !isFinite(fuel) || fuel <= 0) {
      return json({ error: "Could not determine fuel usage" }, 502);
    }
    return json({
      fuelUsageLPerHour: fuel,
      confidence: typeof parsed?.confidence === "string"
        ? parsed.confidence
        : null,
      notes: typeof parsed?.notes === "string" ? parsed.notes : null,
      matchedBrand: typeof parsed?.matchedBrand === "string"
        ? parsed.matchedBrand
        : null,
      matchedModel: typeof parsed?.matchedModel === "string"
        ? parsed.matchedModel
        : null,
      matchedYearRange: typeof parsed?.matchedYearRange === "string"
        ? parsed.matchedYearRange
        : null,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message }, 502);
  }
});
