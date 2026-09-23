import type { RegisterCandidate } from "./ingestion/contract.ts";

/** A search hint is not a selection: refuse competing registrations. */
export function chooseLabelCandidate(query: string, candidates: RegisterCandidate[]): RegisterCandidate | null {
  const normal = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const number = /^(?:(?:apvma|product|registration)\s*(?:no\.?|number)?\s*)?(\d{3,8})$/i.exec(query.trim())?.[1];
  const matches = candidates.filter((c) =>
    (number != null && c.registration_number === number) ||
    normal(c.registered_product_name) === normal(query) ||
    (normal(query).length >= 8 && normal(c.registered_product_name).startsWith(normal(query))) ||
    (c.registrant != null && normal(query) === normal(`${c.registrant} ${c.registered_product_name}`))
  );
  return matches.length === 1 ? matches[0] : null;
}

/** Only a direct, product-specific official label document can be served. */
export function directOfficialLabelURL(raw: unknown, registrationNumber: string): string | null {
  if (typeof raw !== "string") return null;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.username || url.password || url.searchParams.has("redirect")) return null;
    const number = registrationNumber.replace(/\D/g, "");
    if (!number || url.hostname.toLowerCase() !== "elabels.apvma.gov.au" ||
      !url.pathname.toLowerCase().endsWith(".pdf") || !url.pathname.includes(number)) return null;
    return url.toString();
  } catch { return null; }
}

/** An AI suggestion must be literally visible in OCR and carry product-specific evidence. */
export function confirmedOCRName(name: unknown, ocr: string): string | null {
  if (typeof name !== "string") return null;
  const value = name.trim().replace(/\s+/g, " ");
  if (value.length < 5 || value.length > 120 || !/[a-z]/i.test(value)) return null;
  const lines = ocr.split(/\r?\n/).map((line) => line.trim().replace(/\s+/g, " "));
  if (!lines.some((line) => line.toLowerCase() === value.toLowerCase())) return null;
  // Require a specific product identity, not a generic single-word regulatory header.
  if (value.split(" ").length < 2 && !/\d/.test(value)) return null;
  if (/^(?:safety directions|directions for use|keep out of reach|active constituent|net contents?|first aid|read (?:the )?label|batch (?:no|number)|manufactur(?:ed|ing) (?:date|by))$/i.test(value)) return null;
  const generic = new Set(["warning", "caution", "danger", "poison", "fungicide", "herbicide", "insecticide", "label", "registered", "product", "safety", "directions", "for", "use"]);
  if (value.toLowerCase().split(/\s+/).every((word) => generic.has(word))) return null;
  // The model must choose a literal line, supported by surrounding product/label context.
  if (!/(?:fungicide|herbicide|insecticide|miticide|adjuvant|fertilis[ez]r|active constituent|apvma|registration|grapevine|vineyards)/i.test(ocr)) return null;
  return value;
}
