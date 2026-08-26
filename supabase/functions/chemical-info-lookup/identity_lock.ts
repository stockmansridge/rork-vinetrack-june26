// Selected-registration immutability (task Phase 6, 9).
//
// # The rule
//
// Search is DISCOVERY. It may guess, rank, suggest and be wrong, because a
// human is about to look at the list and decide. The moment they decide,
// guessing is over:
//
//   country + scheme + registration number become IMMUTABLE for that lookup.
//
// Everything downstream — register resolution, web research, the master
// catalogue, caches, fallbacks — may enrich that registration, fail to enrich
// it, or report that it cannot be found. Not one of them may answer with a
// DIFFERENT one.
//
// # Why a rule this obvious needs enforcement code
//
// No stage ever intended to substitute a product. The substitution came from
// the structured lookup being asked in NAME terms: the request carried the
// typed phrase as well as the number, and several stages could still resolve
// on the phrase. `fetchApprovedMaster` is the clearest example — it tries the
// exact identity key first, and when that misses it falls through to matching
// the NAME against approved rows. Perfectly reasonable in isolation. But an
// operator who has just selected APVMA 33182 and gets an answer resolved from
// the words "Hortitrol winter oil" has been silently handed whatever product
// that phrase matched instead: a different registration, a different label, a
// different withholding period, presented with no indication that a
// substitution occurred.
//
// A fallback that answers a question nobody asked is not a fallback.
//
// # Failing is allowed. Substituting is not.
//
// When the selected registration cannot be resolved, this returns an
// unresolved state naming that registration. "We could not load APVMA 33182"
// sends an operator to their label. Quietly serving APVMA 50067 sends them to
// their sprayer.

// deno-lint-ignore-file no-explicit-any

/** An exact registered identity, as chosen by a human. */
export interface SelectedRegistration {
  /** ISO-2, upper case. */
  country: string;
  /** Register scheme, lower case ("apvma"). Null when the client did not
   *  state one — the number and country still lock. */
  scheme: string | null;
  /** The registration number, trimmed. Upper-cased for comparison only. */
  number: string;
}

/** Normalises a registration number for comparison. Registers are not
 *  case-sensitive about the letters some schemes use, but they are absolutely
 *  sensitive about the digits, so nothing else is touched. */
function normaliseNumber(value: unknown): string {
  return String(value ?? "").trim().toUpperCase();
}

/**
 * Read the caller's SELECTED identity from a structured-lookup request.
 *
 * Returns null when no registration number was supplied — an unselected
 * lookup (a first-time name resolution) is unchanged and unlocked. The lock
 * exists to hold a human decision, and without a number no decision was made.
 */
export function readSelectedRegistration(
  body: any,
  countryCode: string,
): SelectedRegistration | null {
  const number = normaliseNumber(body?.registrationNumber);
  if (!number) return null;
  const scheme = String(
    body?.registrationScheme ?? body?.registration_scheme ?? "",
  ).trim().toLowerCase();
  return {
    country: String(countryCode ?? "").trim().toUpperCase(),
    scheme: scheme || null,
    number,
  };
}

/**
 * The identity a structured payload actually SERVES.
 *
 * Reads the registration block every structured response carries, master and
 * register paths alike.
 */
export function servedIdentity(payload: any): {
  country: string;
  scheme: string | null;
  number: string;
} {
  const reg = payload?.registration ?? {};
  return {
    country: String(reg?.country_code ?? "").trim().toUpperCase(),
    scheme: String(reg?.scheme ?? "").trim().toLowerCase() || null,
    number: normaliseNumber(reg?.registration_number),
  };
}

/**
 * Why a served payload violates the selected identity, or null when it holds.
 *
 * Deliberately narrow. Only two things can be a violation:
 *
 *   * a DIFFERENT registration number, or
 *   * a different country.
 *
 * A payload that serves NO number has failed to resolve, which is an honest
 * outcome and not a substitution — it is reported by the caller as unresolved,
 * with the number it was asked about. The scheme is compared only when both
 * sides state one, so a client that omits it is not punished for being terse.
 */
export function registrationViolation(
  selected: SelectedRegistration | null,
  payload: any,
): string | null {
  if (!selected) return null;
  const served = servedIdentity(payload);
  if (!served.number) return null;

  if (served.number !== selected.number) {
    return `selected ${selected.number}, served ${served.number}`;
  }
  if (served.country && selected.country && served.country !== selected.country) {
    return `selected ${selected.country}, served ${served.country}`;
  }
  if (
    served.scheme && selected.scheme && served.scheme !== selected.scheme
  ) {
    return `selected ${selected.scheme}, served ${served.scheme}`;
  }
  return null;
}

/**
 * The response served INSTEAD of a substituted product.
 *
 * Shaped as an ordinary unresolved structured answer rather than an HTTP
 * error, because the lookup did not fail — it declined. The client already
 * handles an unresolved match by keeping the operator on the record and
 * letting them fill it in; that is exactly the right behaviour here, and it
 * arrives with the selected registration still named so the screen can say
 * WHICH product could not be loaded.
 */
export function unresolvedForSelection(
  selected: SelectedRegistration,
  reason: string,
): Record<string, any> {
  return {
    product_name: null,
    product_category: "",
    form_type: null,
    registration: {
      country_code: selected.country,
      scheme: selected.scheme,
      registration_number: selected.number,
      registrant: null,
      registered_product_name: null,
      label_reference: null,
      manufacturer_label_url: null,
      regulator_label_url: null,
      label_version: null,
    },
    label_urls: {
      regulator_label_url: null,
      manufacturer_label_url: null,
      product_url: null,
    },
    active_ingredients: [],
    activity_groups: [],
    activity_group_scheme: null,
    registered_uses: [],
    grapevine_uses: [],
    other_crop_uses: [],
    registered_for_grapevine: false,
    label_reference_rate_ranges: [],
    label_rate_bases: [],
    verification: {
      status: "unverified",
      sources: [],
      conflicts: [],
      unresolved_fields: ["registration", "registered_uses", "rates"],
      verified_at: null,
    },
    match_source: "unresolved",
    /** Why this is unresolved, in identity terms. Never a different product. */
    identity_guard: {
      outcome: "selection_not_resolved",
      selected_registration_number: selected.number,
      selected_country: selected.country,
      selected_scheme: selected.scheme,
      reason,
    },
  };
}
