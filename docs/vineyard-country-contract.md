# VineTrack Supported Vineyard Countries — Contract v1

Status: **live on iOS + Android** · Portal (Lovable) MUST present this exact
set. Owner: **Rork/VineTrack mobile** — the portal consumes this contract
as-is and must not invent, drop or rename countries.

Pinned in code by:

- iOS: `ios/VineTrack/App/VineyardCountryCatalog.swift` — single source for
  the vineyard country pickers and jurisdiction display names.
- Android:
  `android-vinetrack/app/src/main/java/com/rork/vinetrack/data/VineyardCountryCatalog.kt`
  — same role, byte-identical list.
- Parity tests: `ios/VineTrackTests/VineyardCountryContractTests.swift` and
  `android-vinetrack/app/src/test/java/com/rork/vinetrack/data/VineyardCountryContractTest.kt`
  assert the identical 30-row matrix on both platforms.

If code and this document ever disagree, fix the document.

## 1. The 30 supported vineyard countries

Canonical picker order (alphabetical by display name):

| ISO-2 | Display name |
| ----- | -------------- |
| AR | Argentina |
| AU | Australia |
| AT | Austria |
| BR | Brazil |
| BG | Bulgaria |
| CA | Canada |
| CL | Chile |
| CN | China |
| HR | Croatia |
| FR | France |
| GE | Georgia |
| DE | Germany |
| GR | Greece |
| HU | Hungary |
| IN | India |
| IE | Ireland |
| IL | Israel |
| IT | Italy |
| JP | Japan |
| MX | Mexico |
| NZ | New Zealand |
| PT | Portugal |
| RO | Romania |
| SI | Slovenia |
| ZA | South Africa |
| ES | Spain |
| CH | Switzerland |
| GB | United Kingdom |
| US | United States |
| UY | Uruguay |

Contract v1 is the union of the previous 25-country mobile picker set and the
5 portal-only countries (IE, BG, HR, SI, GE). Nothing was removed from either
side.

## 2. Storage rules

- `vineyards.country` keeps storing the canonical DISPLAY NAME — the storage
  contract unchanged since sql/001.
- Everything jurisdiction-scoped persists canonical ISO-2 codes: registration
  identity keys (`"AU:apvma:66541"`), `saved_chemicals.registration_country`,
  `master_chemicals.registration_country`. Codes are produced by the shared
  normaliser (`ChemicalRegistration.normaliseCountry`, identical on both
  apps).
- No new display-name storage may be introduced.

## 3. Normalisation and aliases

Canonical display names resolve case-insensitively to their ISO-2 code, and
bare ISO-2 codes pass through uppercased. Approved aliases (identical
resolution on both platforms):

| Alias | Resolves to |
| ----- | ----------- |
| uk | GB |
| great britain | GB |
| usa | US |
| united states of america | US |
| aotearoa | NZ |
| newzealand | NZ |

Rules:

- A platform need not carry every convenience alias, but an alias may NEVER
  resolve to a different jurisdiction than it does elsewhere.
- No fuzzy country guessing. Unknown names stay unresolved: they fall through
  UPPERCASED, which can never equal a served ISO-2 code, so every
  jurisdiction gate fails closed (see
  `docs/chemical-intelligence-json-contract.md` §12.3–12.4).
- No device/browser-locale fallback anywhere. A missing vineyard country
  fails closed.

## 4. Vineyard-country support ≠ chemical-register support

A country being a supported VineTrack vineyard country does NOT mean
VineTrack has an authoritative chemical register integration for it. Wired
registers today: AU (APVMA) and NZ (ACVM / NZ EPA) — see
`ChemicalRegistrationScheme.schemes(forCountryCode:)` /
`schemesForCountry`, which return empty for every other code on purpose.

Server-side authoritative INGESTION (register-first discovery that builds
Master Catalogue candidates, Stage 3) is narrower still: only AU has an
implemented source adapter (APVMA PubCRIS register extract); NZ/GB/US are
declared future entries in the country source registry, and every other
country has none. The vineyard's resolved country — never AI, never locale —
selects the adapter, and a missing country runs no ingestion at all. See
`docs/master-chemical-ingestion.md` §2.

For a vineyard in any other supported country (e.g. IE), the expected
chemical behaviour is:

> Vineyard country recognised, but no verified chemical registration
> currently available for this jurisdiction.

Never fall back to GB/AU/etc. Foreign registrations can never become
label-authoritative for the current vineyard — jurisdiction rules 1–5 and the
suitability rule in `docs/chemical-intelligence-json-contract.md` §12.3–12.4
apply unchanged.

## 5. Database

- NO database change accompanies Contract v1.
- `master_chemicals.registration_country` (sql/199) enforces only the generic
  ISO-2 shape (`check (registration_country ~ '^[A-Z]{2}$')`) — deliberately
  NOT restricted to these 30 countries, so the Master Catalogue can expand to
  further jurisdictions without a migration.

## 6. Change control

Adding or removing a supported country is Contract v2: update BOTH platform
catalogues, both parity tests and this document in the same change, and
notify the portal. The portal must never ship a divergent set.
