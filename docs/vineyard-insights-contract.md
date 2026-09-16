# Vineyard Insights — Vintage Report generation contract

Status: **Round 1 prepared only.** The report workspace exists, its controls are
visibly disabled, and nothing generates prose. This document defines the
behaviour a later round must implement so the information architecture is
settled before any generator is written.

Round 1 deliberately ships no AI generation, no PDF export and no Word export,
and produces no template narrative. A plausible-looking vintage story written
before the capture data has been reviewed is indistinguishable from a real one,
and a grower would reasonably believe it. Nothing here may be implemented until
the Scout and Vintage Notes foundation has been verified in the field.

---

## 1. Data sources

Every statement in a generated report must trace to a record the vineyard
actually holds. The intended sources are:

- Scout visits and block observations (`scout_visits`, `scout_block_assessments`,
  `scout_observations`, `scout_observation_photos`)
- Vintage Notes (`vintage_notes`, with their note-type label snapshots)
- Growth Stage records (`growth_stage_records` — the canonical phenology
  authority, including E-L observations created during scouting)
- Spray dates, times, blocks, targets and applications
- Rainfall and available weather history
- Rainfall and temperature against a **clearly stated** historical baseline
- Frost, heat, wind, hail, smoke and prolonged wet or dry periods
- Work Tasks and operational Trips
- Pruning activity: start, progress and completion
- Shoot thinning, desuckering, wire lifting, leaf plucking and trimming
- Disease pressure and the responses to it
- Yield estimates, damage, picking and actual yield
- Harvest start and completion

All sources are read for the **selected Vintage**, resolved server-side through
the existing authoritative resolver (`resolve_vineyard_vintage_year`, SQL 119).
A report must never group by calendar year.

---

## 2. Generate / Re-generate Report

Builds a completely new draft from all available evidence for the selected
Vintage.

- Produces a **new revision**. The previous report is never replaced silently.
- If a report already exists, the operator must confirm before it is superseded.
- Every previous revision is preserved and remains readable.
- Each revision records its **source coverage cutoff**: the timestamp up to
  which evidence was considered. This is what makes "Add to Existing Report"
  able to find genuinely new information later.
- A regeneration reconsiders all evidence, including records that existed at the
  time of the previous revision. It is a fresh reading, not an append.

## 3. Add to Existing Report

Extends the current report rather than rewriting it.

- The existing narrative is **preserved verbatim**.
- Identifies evidence created or amended **since the current revision's source
  coverage cutoff**.
- Adds only that new information. Events already described are not repeated,
  restated or re-summarised.
- Writes a new revision with an updated coverage cutoff, preserving the prior
  revision.
- If no new evidence exists since the cutoff, it says so and writes nothing —
  it does not manufacture an update.

## 4. Revision history

Both actions maintain:

- An ordered revision history for the Vintage.
- Per revision: created-at, created-by, source coverage cutoff, and which action
  produced it (generate or add).
- No revision is ever destroyed by a later one.

---

## 5. Honesty requirements

These are not stylistic preferences. A vintage report is used to explain a
season to owners, buyers and insurers, and an confidently-worded gap is worse
than an acknowledged one.

- **Missing data must be exposed.** If no rainfall history exists for February,
  the report says the rainfall record is incomplete for February. It does not
  omit February, and it does not describe the season as though the gap were dry.
- **Incomplete weather coverage must be stated**, including partial months,
  missing stations and provider outages. The Scout weather snapshot already
  records stale and unavailable states explicitly for this reason.
- **No comparison against an "average"** unless BOTH are known:
  1. the baseline period (for example "the 2015–2024 mean for this site"), and
  2. sufficient source coverage within that period to support the comparison.

  Where either is unknown, the report states the measured values without
  characterising them as above or below normal.
- **Nothing is inferred from an absence.** No scouting record for a block does
  not mean the block was healthy; it means the block was not scouted.
- **Stored codes, not guesses.** Where an observation's code is not recognised
  by the generator, the raw stored value is reported rather than an invented
  label.
- **Photo positions are reported at their recorded honesty.** A photo captured
  without a qualifying GPS fix is described as block-associated, never as
  positioned.

---

## 6. Intended narrative sections

1. Season opening and winter conditions
2. Pruning and early vineyard activity
3. Budburst, frost and spring development
4. Flowering, fruit set and canopy development
5. Summer weather, water and disease pressure
6. Veraison and ripening
7. Harvest timing, yield and fruit condition
8. Overall Vintage summary

A section with no supporting evidence states that plainly. It is not padded and
it is not silently dropped.

---

## 7. Explicitly out of scope for the next round

- No speculative AI tables.
- No model-provider coupling in the stored report shape. A revision stores the
  narrative and its evidence coverage — not prompts, model names or provider
  metadata, which would make the record depend on a vendor.
- No automatic Repair Pins or Work Tasks derived from report content.

---

## 8. Round 1 control state

All four controls are present and disabled, with the message:

> Vintage Report generation will be enabled after the Scout and Vintage Notes
> data foundation is verified.

Controls: `Generate / Re-generate Report`, `Add to Existing Report`,
`Export PDF`, `Export Word`.
