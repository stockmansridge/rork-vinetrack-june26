# Issue #55 data-parity comparison (P-01, P-05, P-09)

Static code comparison only. Nothing here was run on a device or against production.
Status: MATCH, MISMATCH (fixed or open) or UNVERIFIED (needs the on-screen values).

## P-09 Cost Reports (iOS $0.00 vs Android $128.20)

| Input | iOS | Android (before) | Status |
| --- | --- | --- | --- |
| Source of "Trip allocation cost" | Saved Trip allocations only (`CostingReadAuthority`) | Saved allocations PLUS live estimates for Trips with no saved allocation | MISMATCH, fixed |
| Treated area | Saved rows only | Saved + estimated rows | MISMATCH, fixed |
| Cost per area / per tonne | Unavailable when any row is incomplete | Unavailable when any row carries a warning (estimates do) | MATCH |
| Re-costing saved rows | Never replaces a saved total | Never replaces a saved total | MATCH |

Fix: Android totals and treated area now count saved allocations only. Estimated Trips are shown on a separate
line, "Estimated, not saved (excluded)", with a count and an explanation. No data was re-costed, rewritten or
deleted. The $128.20 is expected to move to that separate line until an owner or manager recalculates and saves
the allocations.

## P-01 Irrigation (crop use 5.5 vs 16.2 mm, effective rain 9.6 vs 9.0 mm)

The calculators (`IrrigationCalculator.swift` and `Irrigation.kt`) are identical line for line, including the
2 mm rain threshold, the recent-rain offset and the v2 soil rules. The difference is in the INPUTS.

| Input | iOS | Android | Status |
| --- | --- | --- | --- |
| Forecast length | Saved per vineyard, choice of 3/5/7/14 days | Fixed at 5 days | MISMATCH, open |
| Forecast provider | Vineyard setting: WillyWeather, Open-Meteo or auto; Open-Meteo fallback | Open-Meteo only | MISMATCH, open |
| ETo from WillyWeather | `et0Mm ?? 0`, so a missing ETo counts as 0 mm | Not applicable | Suspect for the low iOS crop use, UNVERIFIED |
| Kc, efficiency, rain effectiveness, replacement, buffer | Shared vineyard settings (`store.settings`) | Device-local saved defaults | MISMATCH, open |
| Default application rate | Typed value, then vineyard default, then area-weighted block average | Area-weighted block average only | MISMATCH, open |
| Recent rain | Toggle plus a shared look-back window | Fixed 7 days, always on | MISMATCH, open |
| Whole Vineyard soil profile | Vineyard profile, else conservative aggregate of block profiles | Vineyard default profile only | MISMATCH, open |
| Soil-aware v2 | Gated by the system feature flag | On whenever a profile exists | MISMATCH, open |

Not changed. The 3x crop-use gap is almost certainly a different forecast length, Kc or provider ETo. Which one
needs the iOS and Android values for Kc, forecast days, source label and the daily ETo breakdown. Changing
Android to read the shared vineyard settings is a larger change and is not done yet.

## P-05 Yield (iOS "No completed Bunch Count Trip" vs Android tonnage cards)

| Input | iOS | Android | Status |
| --- | --- | --- | --- |
| Latest completed session per block | Filtered to the selected vineyard | Same | MATCH |
| Estimate rule (`latestCompletedSessionForBlock`) | Completed and has a recorded site, in the vintage | Same | MATCH |
| Actual rows (`actualRows`) | Picking records plus historical yield records | Same logic | MATCH |
| Source lists | `historicalYieldRecords`, `pickingRecords` | `yieldRecords`, `pickingRecords` | UNVERIFIED |

The logic matches, so a difference in what is shown must come from which records each app has loaded or from
vineyard scoping of the records list. That cannot be seen in code. Nothing changed. It needs the vintage, the
vineyard and the card titles from each screen to decide whether it is data, scoping or a real defect.
