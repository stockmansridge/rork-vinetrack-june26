# Release notes — iOS 2.8.9 / Android 0.7

Grower-facing copy for the store listings. Paste verbatim.

- **App Store** — App Store Connect → Version 2.8.9 → What's New (4,000 char limit; draft below is ~1,450).
- **Google Play** — Release notes for versionName 0.7 / versionCode 7 (500 char limit; draft below is ~430).

Keep both in step: everything claimed here is shipped and verified on BOTH
platforms. Do not add a line to one store that the other build cannot do.

---

## App Store — "What's New" (2.8.9)

```text
Piece-rate pruning

• Pay pruning crews by the vine instead of by the hour. Choose Piece Rate on a pruning job, enter the agreed rate per vine, and VineTrack works out the total.
• Every row now counts its own vines automatically, from that row's mapped length and your block's vine spacing. There is nothing to type and nothing new to set up.
• Counted a row yourself? Enter your own number for that row and VineTrack uses it instead of the calculated one. Every other row keeps calculating itself.
• Hourly jobs are untouched. Existing pruning records cost exactly as they always have, and hourly and piece-rate totals are never mixed together.
• A finished job keeps the vine count it was priced on, so re-mapping or re-surveying a block later never rewrites an invoice you have already paid.

Yield

• Yield estimation sessions are now called Bunch Count Trips, and Vintage replaces Year and Season throughout.
• The new Yield Report shows the estimated yield per block for the vintage, taken from the most recent completed Bunch Count Trip.
• Starting a trip is simpler: a bigger map, and a single Start Sampling button.
• Picking Log prices, values and totals are now visible only to vineyard owners and managers.

Clones and rootstocks

• Browse a built-in catalogue of grape clones and rootstocks, or add your own for your vineyard.
• Record clone and rootstock against each planting, including Mass selection and Own roots.

Also in this release

• Place pins on a full-screen map with deep zoom, for exact positioning on a single vine.
• Filter by block name or row number when picking rows, instead of scrolling the whole list.
• Stability and performance improvements.
```

## Google Play — release notes (0.7)

```text
Piece-rate pruning: pay by the vine. Choose Piece Rate on a pruning job, enter your rate per vine, and VineTrack totals it. Every row counts its own vines automatically from its mapped length and your block's vine spacing — or enter your own count for any row. Hourly jobs are unchanged.

Also: new Yield Report and Bunch Count Trips, a clone and rootstock catalogue, full-screen pin placement with deep zoom, block and row filtering, plus fixes.
```

## Why the piece-rate wording is what it is

- **"There is nothing to type"** is the actual headline. The vine count is derived
  from geometry the grower already has, so the feature works on day one without a
  data-entry project. Leading with the rate field would undersell it.
- **"Hourly jobs are untouched"** pre-empts the obvious fear — that a costing
  change silently re-prices historical work. It does not; `costing_method` is the
  only switch and every legacy record stays hourly.
- **"keeps the vine count it was priced on"** describes the snapshot in
  `work_task_piece_rate_rows.vine_count`. Worth stating publicly because it is the
  difference between a costing tool and an accounting liability.
- We do NOT mention rounding, per-row overrides being optional in JSONB, or the
  distinction from the block-level vine count. Correct, but not store copy.
