// Stable, deterministic identity for one authoritative registered label rate
// (Gate D1).
//
// # The problem this solves
//
// A client that lets an operator choose an operational DEFAULT rate has to
// persist which registered rate they chose, and recover that choice later. It
// currently cannot. The only recovery available is matching on the stored
// NUMBER, which cannot tell apart two registered directions that happen to
// state the same figure:
//
//     Grapevine scale      3 L/100 L
//     European red mite    3 L/100 L
//
// Those are two distinct authoritative directions. Matching on `3` resolves to
// whichever sorted first, so the operator's choice is silently re-decided
// every time the record is reopened.
//
// # What an identity must survive
//
// The identity is minted from the rate's MEANING, never from the circumstances
// of its retrieval. It must not move when:
//
//   * the array is reordered by a parser or a projection;
//   * the same label is extracted a second time;
//   * a cache serves the row instead of a live fetch;
//   * whitespace, capitalisation or punctuation differ between parser passes;
//   * a NEW label version restates the same rate unchanged.
//
// The last one is why `label_version` is deliberately NOT part of the input.
// A 2019 label and a 2024 label that both say "Grapevine scale, 3 L/100 L,
// NSW" state the SAME registered direction, and an operator's default should
// survive the label being reissued. Detecting that the source document moved
// on is a separate job, done by storing the label version in the default's
// snapshot — a question about the evidence, not about the rate's identity.
//
// # What this is NOT
//
// `rate_id` is identity metadata. It confers no authority and changes no
// value: crop, target_raw, basis, value, min_value, max_value, unit,
// condition, raw_text, restrictions, WHP and REI are untouched by everything
// in this file. `registered_uses` remains immutable label evidence.
//
// # One identity per registered ROW, not per number
//
// A later operational default may reference SEVERAL rate ids, because the UI
// legitimately groups identical numbers across different directions into one
// choice ("3 L/100 L"). That grouping happens above this layer. Here, every
// distinct authoritative direction keeps its own identity — collapsing them
// would destroy the very information a compliance record needs.

// ---------------------------------------------------------------------------
// Canonical inputs
// ---------------------------------------------------------------------------

/** The locked registered product the rate belongs to. */
export interface RateIdentityProduct {
  country?: string | null;
  scheme?: string | null;
  registration_number?: string | null;
}

/**
 * ONE PRINTED LABEL DIRECTION.
 *
 * # Why this is not "a row"
 *
 * A Directions for Use table prints one direction per line, and a line may
 * name SEVERAL pests:
 *
 * ```text
 *   Grapes | Grapeleaf Blister Mites,  | Tas | 2 L / 100 L
 *          | European Red Mites,       |     |
 *          | Two Spotted Mites         |     |
 * ```
 *
 * That is ONE regulatory direction covering three pests — not three
 * directions. The `registered_uses` contract carries one target per row, so
 * the direction is FANNED OUT into three rows downstream. That fan-out is a
 * projection for clients to render; it is not a statement that the regulator
 * granted three separate approvals.
 *
 * Identity therefore belongs to the printed direction and is minted BEFORE the
 * fan-out. Deriving it afterwards from a projected row's single `target_raw`
 * mints three identities for one direction — and where the projection shares
 * one rate object across those rows, whichever row is stamped last wins,
 * leaving the others advertising an identity computed from a pest they do not
 * name.
 */
export interface RateIdentityDirection {
  crop?: string | null;
  /**
   * EVERY target the printed direction names, in the label's own wording.
   *
   * Canonicalised order-independently: the label's reading order is a
   * typesetting fact, not a regulatory one.
   */
  targets?: (string | null | undefined)[] | null;
  /**
   * The direction's condition/jurisdiction wording ("Tas", "NSW, Vic, SA").
   *
   * Part of identity: the same crop and pest under two state sets are two
   * distinct registered directions, not one.
   */
  condition?: string | null;
  /**
   * Degenerate single-target form, for sources that publish one target per
   * printed direction, and for already-projected historical rows.
   *
   * Used ONLY when `targets` is absent or empty. A source that genuinely
   * states one pest per direction is not a fan-out, so treating its row as its
   * own direction is correct rather than a fallback.
   */
  target_raw?: string | null;
}

/** Prior name for the same concept, kept so call sites read naturally. */
export type RateIdentityUse = RateIdentityDirection;

/** The rate row itself, in the sql/194 wire vocabulary. */
export interface RateIdentityRate {
  basis?: string | null;
  unit?: string | null;
  value?: number | null;
  min_value?: number | null;
  max_value?: number | null;
  /**
   * What the label calls this rate. This IS the condition — "Tasmania",
   * "NSW/Vic/Qld/SA/WA", "Dilute spraying", "High disease pressure" — and it
   * is part of semantic identity: the same target under two jurisdictions is
   * two directions, not one.
   */
  label?: string | null;
  /**
   * Verbatim label wording. Participates ONLY for `basis: "other"`.
   *
   * For a parsed numeric rate the structured fields carry the meaning and the
   * raw text is just the wording they were read from — including it would
   * make a punctuation-only reprint mint a new identity, which is exactly what
   * this must not do.
   *
   * For `basis: "other"` there ARE no numeric fields: the contract states that
   * such an entry carries only its verbatim text. Excluding it there would
   * give every unparsed rate on one use the same identity — a proven
   * structural collision, not a speculative one.
   */
  raw_text?: string | null;
  /**
   * A separately structured jurisdiction/state restriction, if the rate
   * contract ever grows one.
   *
   * Today it does not: jurisdiction reaches VineTrack inside `label`, which is
   * already part of the identity, so state-level distinctions are honoured
   * through that field. Reserved here so that adding the structured field
   * later is a contract change made deliberately rather than by accident.
   */
  jurisdiction?: string | null;
}

/** Version prefix. Bump only if the canonical input changes shape. */
export const RATE_ID_VERSION = "rate_v1";

/** Version prefix for a printed-direction identity. */
export const DIRECTION_ID_VERSION = "direction_v1";

// ---------------------------------------------------------------------------
// Normalisation
// ---------------------------------------------------------------------------

/**
 * Fold a text field to its semantic core.
 *
 * Unicode-normalised, lowercased, and every run of non-alphanumeric characters
 * flattened to a single space. Two parser passes that differ only in spacing,
 * case or punctuation — `"NSW/Vic/SA"` versus `"NSW, Vic, SA "` — therefore
 * produce one identity, which is the requirement.
 */
export function normaliseIdentityText(value: string | null | undefined): string {
  return String(value ?? "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/**
 * Canonical decimal rendering, so `3`, `3.0` and `3.000` are one number.
 *
 * Absent is the literal `-`, distinct from any numeric value: "no upper bound"
 * and "an upper bound of zero" must never hash alike.
 */
export function normaliseIdentityNumber(value: number | null | undefined): string {
  if (typeof value !== "number" || !Number.isFinite(value)) return "-";
  // Six decimal places is far beyond label precision; trailing zeros are then
  // stripped so the representation is canonical rather than merely consistent.
  const fixed = value.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
  return fixed === "-0" ? "0" : fixed;
}

/** Registration numbers differ only in decoration ("APVMA 33182" vs "33182"). */
function normaliseIdentityToken(value: string | null | undefined): string {
  const folded = normaliseIdentityText(value).replace(/ /g, "");
  return folded || "-";
}

function orDash(value: string): string {
  return value || "-";
}

// ---------------------------------------------------------------------------
// The canonical string
// ---------------------------------------------------------------------------

/**
 * The target set a direction names, canonicalised order-independently.
 *
 * Normalised, de-duplicated and sorted, so identity depends on WHICH pests the
 * direction covers and never on the order the label printed them or a parser
 * happened to emit them.
 */
export function canonicalTargetSet(
  direction: RateIdentityDirection | null | undefined,
): string[] {
  const raw = (direction?.targets?.length ? direction.targets : [direction?.target_raw]) ?? [];
  const folded = raw.map((t) => normaliseIdentityText(t)).filter((t) => t.length > 0);
  return [...new Set(folded)].sort();
}

/**
 * The exact bytes hashed for a PRINTED DIRECTION identity.
 *
 * Fields are NAME-tagged and separated by a unit separator (U+001F) that
 * cannot survive `normaliseIdentityText`. Without both, `crop="ab"` +
 * `target="c"` and `crop="a"` + `target="bc"` would hash identically. Targets
 * inside the set are joined by a record separator (U+001E) for the same
 * reason.
 */
export function canonicalDirectionIdentityInput(
  product: RateIdentityProduct | null | undefined,
  direction: RateIdentityDirection | null | undefined,
): string {
  const targets = canonicalTargetSet(direction);
  return [
    `v=${DIRECTION_ID_VERSION}`,
    `country=${normaliseIdentityToken(product?.country)}`,
    `scheme=${normaliseIdentityToken(product?.scheme)}`,
    `number=${normaliseIdentityToken(product?.registration_number)}`,
    `crop=${orDash(normaliseIdentityText(direction?.crop))}`,
    `targets=${targets.join("\u001e") || "-"}`,
    `condition=${orDash(normaliseIdentityText(direction?.condition))}`,
  ].join("\u001f");
}

/**
 * Mint the stable identity for ONE PRINTED LABEL DIRECTION.
 *
 * Must be called while the direction still holds its complete target set —
 * that is, before any fan-out into one-target-per-row projection rows.
 */
export function mintDirectionId(
  product: RateIdentityProduct | null | undefined,
  direction: RateIdentityDirection | null | undefined,
): string {
  const digest = sha256Hex(canonicalDirectionIdentityInput(product, direction));
  return `${DIRECTION_ID_VERSION}_${digest.slice(0, 32)}`;
}

/**
 * The exact bytes hashed for a rate identity.
 *
 * Scoped to the printed DIRECTION rather than to a projected row's single
 * target. That is the whole correction: a three-pest direction states one
 * rate, so it carries one rate identity whichever of its three projected rows
 * a client happens to be looking at.
 */
export function canonicalRateIdentityInput(
  product: RateIdentityProduct | null | undefined,
  directionId: string,
  rate: RateIdentityRate | null | undefined,
): string {
  const basis = orDash(normaliseIdentityText(rate?.basis));
  // See `RateIdentityRate.raw_text` — verbatim wording IS the rate when the
  // grammar could not parse one, and is noise when it could.
  const rawText = basis === "other" ? orDash(normaliseIdentityText(rate?.raw_text)) : "-";

  return [
    `v=${RATE_ID_VERSION}`,
    `country=${normaliseIdentityToken(product?.country)}`,
    `scheme=${normaliseIdentityToken(product?.scheme)}`,
    `number=${normaliseIdentityToken(product?.registration_number)}`,
    // The direction, never the projected target.
    `direction=${orDash(normaliseIdentityText(directionId))}`,
    `basis=${basis}`,
    `unit=${orDash(normaliseIdentityText(rate?.unit))}`,
    `value=${normaliseIdentityNumber(rate?.value)}`,
    `min=${normaliseIdentityNumber(rate?.min_value)}`,
    `max=${normaliseIdentityNumber(rate?.max_value)}`,
    `condition=${orDash(normaliseIdentityText(rate?.label))}`,
    `jurisdiction=${orDash(normaliseIdentityText(rate?.jurisdiction))}`,
    `other=${rawText}`,
  ].join("\u001f");
}

/**
 * Mint a rate identity against an ALREADY-MINTED direction identity.
 *
 * The form the fan-out uses: mint the direction once, mint its rates against
 * it, then copy both onto every projected row verbatim.
 */
export function mintRateIdForDirection(
  product: RateIdentityProduct | null | undefined,
  directionId: string,
  rate: RateIdentityRate | null | undefined,
): string {
  const digest = sha256Hex(canonicalRateIdentityInput(product, directionId, rate));
  // 128 bits of a SHA-256. Collision probability is negligible at any
  // plausible catalogue size, and the shorter string keeps the payload light.
  return `${RATE_ID_VERSION}_${digest.slice(0, 32)}`;
}

/**
 * Mint the stable identity for one registered rate of a printed direction.
 *
 * Deterministic and pure: the same semantic rate always yields the same
 * string, on any machine, in any order, at any time. Never a UUID — a random
 * identity would change on every extraction, defeating the entire purpose.
 */
export function mintRateId(
  product: RateIdentityProduct | null | undefined,
  direction: RateIdentityDirection | null | undefined,
  rate: RateIdentityRate | null | undefined,
): string {
  return mintRateIdForDirection(product, mintDirectionId(product, direction), rate);
}

// ---------------------------------------------------------------------------
// Applying identities to a structured response
// ---------------------------------------------------------------------------

interface MutableUse {
  crop?: string | null;
  target_raw?: string | null;
  target?: string | null;
  direction_id?: string | null;
  rates?: unknown;
}

/**
 * Stamp `direction_id` and `rate_id` onto every use and rate, in place.
 *
 * # The direction a row already belongs to is never re-decided
 *
 * A row that ALREADY carries `direction_id` was fanned out from a printed
 * direction whose full target set is no longer visible here — only one of its
 * pests survives on this row. Re-deriving identity from that single pest is
 * precisely the defect this gate closes, so a carried `direction_id` is
 * honoured verbatim and its rates are minted against it.
 *
 * A row WITHOUT one is its own direction: sources that publish one target per
 * printed direction are not fan-outs, and treating such a row as a
 * single-target direction is the correct reading rather than a fallback.
 *
 * Additive and idempotent — identity is a pure function of meaning, so it is
 * safe to call on a projection already stamped upstream.
 *
 * Nothing else about a use or a rate is read, written, reordered or removed.
 */
export function assignRateIds(
  uses: unknown,
  product: RateIdentityProduct | null | undefined,
): void {
  if (!Array.isArray(uses)) return;
  for (const raw of uses) {
    const use = raw as MutableUse | null;
    if (!use || typeof use !== "object") continue;
    if (!Array.isArray(use.rates)) continue;

    const directionId = use.direction_id?.trim()
      ? use.direction_id
      : mintDirectionId(product, {
        crop: use.crop ?? null,
        // `target_raw` is the authoritative wording; `target` is the mapped
        // VineTrack enum and only stands in when the raw wording is absent.
        target_raw: use.target_raw ?? use.target ?? null,
      });
    use.direction_id = directionId;

    for (const rateRaw of use.rates) {
      const rate = rateRaw as (RateIdentityRate & { rate_id?: string }) | null;
      if (!rate || typeof rate !== "object") continue;
      rate.rate_id = mintRateIdForDirection(product, directionId, rate);
    }
  }
}

/**
 * Stamp identities across a whole structured lookup response.
 *
 * `grapevine_uses` and `other_crop_uses` are projections of `registered_uses`,
 * and whether a projection copies rate objects or shares them is an
 * implementation detail that must not decide whether clients see an id. All
 * three are stamped; because minting is deterministic, a shared object simply
 * receives the same value twice.
 */
export function applyRateIdentities(structured: unknown): void {
  const s = structured as Record<string, unknown> | null;
  if (!s || typeof s !== "object") return;

  const registration = (s.registration ?? null) as Record<string, unknown> | null;
  const product: RateIdentityProduct = {
    country: (registration?.country_code as string | undefined) ?? null,
    scheme: (registration?.scheme as string | undefined) ?? null,
    registration_number: (registration?.registration_number as string | undefined) ?? null,
  };

  assignRateIds(s.registered_uses, product);
  assignRateIds(s.grapevine_uses, product);
  assignRateIds(s.other_crop_uses, product);
}

// ---------------------------------------------------------------------------
// SHA-256 (synchronous, dependency-free)
// ---------------------------------------------------------------------------
//
// `crypto.subtle.digest` is async, and minting runs inside synchronous array
// mapping across several call sites. Making those async would ripple through
// the extraction pipeline for no benefit, so the digest is computed inline.
// This is a plain FIPS 180-4 SHA-256 over UTF-8 bytes — the standard vectors
// are asserted in the tests, so a transcription slip cannot pass silently.

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

function rotr(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

/** Hex SHA-256 of a UTF-8 string. */
export function sha256Hex(input: string): string {
  const bytes = new TextEncoder().encode(input);
  const bitLength = bytes.length * 8;
  const blocks = new Uint8Array(Math.ceil((bytes.length + 9) / 64) * 64);
  blocks.set(bytes);
  blocks[bytes.length] = 0x80;

  const view = new DataView(blocks.buffer);
  view.setUint32(blocks.length - 8, Math.floor(bitLength / 0x1_0000_0000));
  view.setUint32(blocks.length - 4, bitLength >>> 0);

  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  const w = new Uint32Array(64);

  for (let offset = 0; offset < blocks.length; offset += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4);
    for (let i = 16; i < 64; i++) {
      const a0 = w[i - 15];
      const a1 = w[i - 2];
      const s0 = (rotr(a0, 7) ^ rotr(a0, 18) ^ (a0 >>> 3)) >>> 0;
      const s1 = (rotr(a1, 17) ^ rotr(a1, 19) ^ (a1 >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }

    let a = h[0], b = h[1], c = h[2], d = h[3];
    let e = h[4], f = h[5], g = h[6], hh = h[7];

    for (let i = 0; i < 64; i++) {
      const S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
      const ch = ((e & f) ^ (~e & g)) >>> 0;
      const t1 = (hh + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const t2 = (S0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }

    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }

  let out = "";
  for (let i = 0; i < 8; i++) out += h[i].toString(16).padStart(8, "0");
  return out;
}
