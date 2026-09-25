import type { ResolvedRegistration } from "./contract.ts";

/** Skip optional product-page research only when a fetched official label already
 * supplies at least one usable, unambiguous grapevine rate for this identity. */
export function hasOfficialGrapevineRate(registration: ResolvedRegistration | null | undefined): boolean {
  if (!registration?.label_document?.document || !registration.label_text_extracted) return false;
  return registration.label_evidence?.claims.some((claim) =>
    /grape\s*vines?/i.test(claim.crop) &&
    claim.rates?.some((rate) =>
      !rate.condition_ambiguous &&
      (rate.basis === "per_100_litres" || rate.basis === "per_hectare" ||
        rate.basis === "range_per_100_litres" || rate.basis === "range_per_hectare") &&
      ((rate.value != null && rate.value > 0) ||
        (rate.min_value != null && rate.min_value > 0 &&
          rate.max_value != null && rate.max_value >= rate.min_value))
    )
  ) ?? false;
}
