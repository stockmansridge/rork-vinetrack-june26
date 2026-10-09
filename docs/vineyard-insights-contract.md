# Vineyard Insights — Vintage Report generation contract

## Status — 2026-10-09

The next phase is **implemented in source, not deployed or runtime-verified**. The new native workspaces are wired into Vineyard Insights on iOS and Android; the Round 1 disabled placeholders remain unwired historical references. The user's authorization permits this development. It does **not** establish prior Scout/Vintage Notes field acceptance or authorize release.

No builds, automated tests, simulators, Gradle, XCTest, live SQL, function deployments or paid model calls are permitted in this implementation pass. A single final `git diff --check` is the source-format validation boundary. Compilation, SQL/catalog resolution, RLS execution, provider calls, rendered UI, recovery and exports all require later acceptance.

## Access and isolation

The existing `can_use_vineyard_insights(vineyard_id)` predicate remains the authority: authenticated **System Admin AND member of the selected vineyard**. Native workspaces continuously check the existing gate, account and vineyard. No ordinary owner/manager-only route is introduced. Server retrieval, request creation, narrative editing, candidate activation and cancellation verify the same predicate plus the client-persisted author ID against `auth.uid()`, so transport token refresh/account switching cannot re-author an old intent under a new session. The privileged worker rechecks the persisted author inside its transaction; the endpoint verifies the caller's actual JWT and vineyard access before using service credentials.

Report/revision/request tables have RLS and explicit grants. Authenticated users cannot directly insert/update/delete report tables. Provider diagnostics are service-only, separate from provider-independent revisions. Clients cache under account/vineyard/vintage paths; exports are account-scoped private files shared only by an explicit user action. Signing out/switching account or vineyard cannot expose another scope through this interface. Offline access relies on the existing cached native preview gate, not a claim of live permission revalidation while disconnected.

## Workspace and revision protocol

The workspace shows vineyard, selected vintage, canonical season dates, a Report through date, status, current revision, saved date, source counts/gaps and saved narrative. Server coverage defaults Report through to vineyard-local today or season end, whichever is earlier. Future vintages show **Not yet covered** and cannot generate. The date editor uses explicit YYYY-MM-DD input and server validation; season display/export headers reuse RegionFormatter.

Actions are Generate, Re-generate, Add to Existing, review/edit as a new revision, history, PDF and genuine DOCX. Only an explicit generation/recovery action can execute a queued paid request. Entry, refresh, sync, resume and export never initiate AI. Previously downloaded revisions remain readable when refresh/generation fails; a prior current report is never blanked during generation.

Before generation both apps invoke relevant existing Scout/Notes and operational sync/replay paths, including irrigation pending writes. Unresolved evidence is warned about, with Retry sync and Generate from synced records. iOS operational counters and Android's generic outbox warning are conservative and may include another vineyard. No claim is made that all devices are synchronized or that the server can see other devices' pending work. Failed sync does not masquerade as successful inclusion.

### Generate and re-generate

Generate creates the first saved revision and current pointer atomically. Regenerate uses all eligible frozen evidence and saves a **candidate** revision. The old report remains current until explicit confirmation. Activation checks both the caller's expected pointer and the original generation baseline; a newer edit causes a conflict rather than silent overwrite. Old/manual revisions are retained.

### Add to Existing

Compare stable source IDs, relevant content fingerprints and normalized content against the previous frozen manifest, not a timestamp cutoff. Ignore timestamp/revision-only changes to unchanged content. Include older events entered late, amendments and records that are now deleted/out of scope/no longer completed. Report-scope metadata is itself an authoritative manifest entry, so changing the reporting window is an explicit update.

Only changed evidence is sent to AI. Existing narrative, including manual edits, is appended **verbatim in application/server code**; AI is not asked to reproduce it. Amendments/removals receive explicit corrections, and revised rainfall summaries supersede previous summaries. Earlier source appendices and timeline entries remain preserved with dated coverage updates, so old references remain readable. An unchanged manifest and reporting window returns **No new information to add** without an AI call or new revision.

Both report-through date and evidence collection timestamp are stored. They are different concepts: event eligibility versus when the database snapshot was collected.

### Review/edit

Editing creates an immutable new revision from the current saved narrative. Its frozen evidence, report-through date, original collection cutoff, timeline and source appendix are retained. Edits are labelled by revision action/manual-edit metadata; they are human-authored, not represented as newly AI-validated facts. A stale expected current pointer conflicts. Both native editors capture the revision ID when review begins and keep that original baseline when reports refresh; submission must never rebase older wording onto a newly current revision. If refresh reveals a newer current revision, the draft remains visible with a warning and submission is rejected locally before creating an operation. A concurrent change not yet refreshed is rejected by the server's expected-pointer check. Unsent editor text stays mounted on errors, and submitted text and its original baseline are part of the durable operation envelope.

## Evidence actually integrated

`_vr_collect` is a stable database helper using a statement snapshot across explicit 500-row parent pages and server-cursor child iteration. No PostgREST default row limit can silently cut off evidence. Revisions/history are read in 20-row keyset pages, so concurrent insertions cannot shift offsets and duplicate history identities. Oversized sources/packages reject explicitly; nothing is silently truncated.

| Source | Inclusion and honesty boundary |
| --- | --- |
| `scout_visits` | Completed, nondeleted trips in the server-authoritative selected vintage. Excluded draft-trip counts are shown. |
| `scout_block_assessments`, `scout_observations` | Every distinct complete saved stop, including repeated blocks; `is_draft` stops excluded. Meaningful saved item values/notes only. New stop event dates use recorded capture context; legacy stops keep their associated trip date and explicitly unknown stop metadata. Canonical-linked E-L items are not counted again. |
| `vintage_notes` | Note dates, notes, custom type IDs and historical `note_type_label` snapshots. No historical relabelling from a current type catalogue. |
| `growth_stage_records` | Canonical stored E-L codes/labels, observed dates, variety and notes; deleted records excluded. Unknown codes remain raw codes. |
| `spray_records` | Non-template recorded applications, recorded date/times, application blocks, targets and compact recorded product/rate/unit identities. No raw tank costing or route payload is sent. Linked operational Trips are suppressed only when an eligible spray record represents the operation. |
| `work_tasks`, `trips` | Planning versus finalized records distinguished; active Trips retain their active flag. E-L compatibility dates are never reported as activity dates. Explicit business completion dates/timestamps are used when present; otherwise activity date is unknown. Eligible linked pruning/Trip work is not counted twice as a task operation. |
| `pruning_activities` | Nondeleted parent activity dates/times and notes. These establish recorded activity, not an invented vineyard-wide start/completion. Allocation progress and independent legacy pruning-entry histories are not integrated. |
| `irrigation_sessions` | Recorded completed/corrected/imported/estimated sessions with original status, calculation method, total/effective litres, duration and notes; reversed/planned/running/cancelled sessions excluded. Calculated/estimated volumes are not called meter-measured water. Per-block allocations are not integrated. |
| `fertiliser_records` | Completed application records, including legacy `calculation_mode=fertigation`, recorded product, quantity, rate and units. These are not equivalent to the separate SQL 266 linked-fertigation application authority. |
| `season_yield_estimates`, `damage_records`, `picking_records` | Canonical vintage, dated base estimates distinctly labelled as estimates, recorded damage, picked kg and recorded fruit-analysis units. Picking is actual recorded yield, not proof of whole-vineyard harvest completion. Undated/historical archive yield and detailed work logs are not integrated. |
| `get_daily_rainfall` | Existing authoritative daily resolver, including provider priority, station information, nondeleted readings and NULL missing days. No historical downloads are initiated. |

Every included source stores a stable ID, relevant version fields, event date (or explicit unknown), relevant content fingerprint and frozen compact content. Source coverage and collection time are recorded. No operational table is mutated by the report generator. SQL 272/273 and Scout synchronization/deletion contracts are unchanged; the Scout service addition only reads pending evidence for preflight.

### Known source/deployment limits

Repository/schema source contracts were inspected; **no fresh deployed-schema or production-record inspection was performed** under this source-only restriction. Jonathan must check actual table/RPC contracts before applying/deploying.

Not integrated: the dedicated SQL 266 linked-fertigation applications/products RPC source (its migration definition was not located in the inspected SQL tree), detailed irrigation/fertiliser allocations, independent work-log tables, legacy pruning-entry allocations, historical actual-yield archives, photo evidence/analysis, and a complete historical temperature/wind/baseline series. Their absence is stated rather than guessed. Date-less or out-of-period records are not assigned invented event dates.

## Deterministic weather — vr-weather-v1

Daily rainfall thresholds, in mm/day: **wet >=1; dry <1; heavy >=25**. Before AI, compute measured totals, recorded heavy-rain days and longest supported consecutive wet/dry runs **separately by provider/station**. Missing days and provider/station switches break runs. Coverage uses the actual selected season reporting range; missing days remain unknown, never zero. The appendix states thresholds, units, daily frequency, provider/station, covered/missing days and contributing source IDs.

The current-weather cache is **not** a historical series. Occasional Scout weather snapshots are observation-time evidence only. No hourly temperature/wind extremes, heat/frost/wind event claims, climate “average” comparison or causal damage inference is produced. No uncontrolled provider download occurs. A future extension needs verified historical frequency, units, coverage, comparable seasonal dates and a stated adequately covered baseline period.

## AI contract and narrative

Dedicated authenticated endpoint: **POST `/functions/v1/vintage-report`**.

- Body: `{operation_id, action: "execute" | "status"}`; the scoped durable request must already exist.
- Credentials stay server-side: `OPENAI_API_KEY`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`.
- Dedicated model setting: `VINTAGE_REPORT_MODEL`; default pinned snapshot `gpt-4.1-mini-2025-04-14`. Allowlist also includes `gpt-4.1-2025-04-14` only by explicit configuration, not automatic escalation. Official Responses/Structured Outputs support was checked in documentation, not by a paid call.
- Responses API, strict schema, eight sections, bounded paragraph fact-ID arrays and <=20 timeline entries. No search tools, photo analysis or model-initiated mutations.
- **Conservative v1:** server renders factual sentences from compact supplied records and calculated metrics. AI chooses ordering/paragraph grouping and timeline selection using supplied fact IDs; it cannot invent factual prose or numerical values. This is an AI-organized evidence report, not unrestricted literary synthesis. All facts must appear exactly once in their allowed section. Unknown/duplicate/omitted references, unsupported timeline IDs, malformed/incomplete/refused output reject without replacing the report.
- Notes are quoted evidence, never instructions. Model output contains IDs only. No treatment advice, inferred quality claim or causal explanation is authored by the model.
- The eight sections remain: season opening/winter; pruning/early activity; budburst/frost/spring; flowering/fruit set/canopy; summer/water/disease; veraison/ripening; harvest/yield/fruit condition; overall summary. Include timeline, technical glossary and source/coverage appendix.
- Ongoing reports are **Season to date**. Missing past evidence says **No records available**. Dates beyond the reporting cutoff are **not yet covered**. Missing later E-L records do not prove a stage remains in the future: v1 explicitly says actual stage timing is unknown rather than making a calendar/hemisphere assumption. Stage-specific future classification needs an additional authoritative stage-timing contract.
- Record facts retain explicitly labelled canonical/recorded units and invariant ISO event dates; native period headers use regional date formatting. Full preferred-unit conversion of every narrative fact and localization of event prose remain follow-up work.

### Cost and recovery

Limits: database package <=500,000 bytes; model input <=180,000 UTF-8 bytes and <=1,000 fact records; output <=10,000 tokens. Sources beyond the scan boundary reject rather than truncate. These are first-version safety limits, not performance/scale acceptance results. Large vintages can fail the budget and need a later approved compaction strategy; no automatic expensive-model escalation or partial report is substituted.

Each client persists the exact operation UUID/action/baseline/date/narrative before transport. Server requests are queued/running/succeeded/failed/unchanged; report-row locks serialize claims, new requests, edits and commits. A running request prevents a second concurrent generation; an intentional edit may proceed, causing an in-flight stale generator to conflict at commit. Paid calls are never blindly replayed.

The handler awaits a bounded provider request, not an untracked background task. Provider response ID/model/usage are recorded separately, and a validated result is durably saved before atomic revision commit. Responses use `store:true` to allow retrieval of the **same paid response** after interruption; Jonathan must review provider retention/privacy settings. Status recovery fetches an existing stored response or commits its already validated result without another model POST. Clients can restore their own queued/running request envelope from server reads.

If interruption happens **before a provider response ID is persisted**, the paid outcome cannot be established. After the running timeout, status becomes an explicit unknown-outcome failure, retaining the previous report and frozen request. It is not automatically retried. A replacement requires explicit acknowledgement, with another-charge warning. Stored-response expiry/unavailability also does not cause paid replay. This irreducible boundary remains an acceptance case, not a claim of exactly-once provider billing.

An explicit cancellation-fence RPC resolves unsent/rejected/queued requests: even an absent operation is recorded as cancelled so a delayed original request cannot later generate. It refuses to discard a running request. This avoids permanently blocking an editor after invalid input or a pre-acceptance conflict. Unreadable local caches are preserved/quarantined and block new generation until server recovery; acknowledgement is published only after persistence succeeds.

## PDF and Word

Exports use the selected immutable saved revision, never another AI call. Both contain vineyard name, available cached branding logo (aspect-fit), vintage/period, narrative and dated addenda, timeline, revision/saved/collection dates, coverage limitations and readable references. Saved vineyard name is preferred over a later rename. Logos are current cached branding, not a frozen historical logo record.

PDF is locally paginated A4 with margins, wrapping and footers. Word is a **genuine OOXML DOCX ZIP**, with document XML, package relationships/content types and optional proportionate image media; not renamed text or HTML. Native private-file caching supports offline re-export/share. Creation/share failures are explicit. Rendering, page-break quality, large Dynamic Type and Word compatibility still require handset/desktop acceptance.

## Migration / deployment order — Jonathan only

1. Confirm the existing 272 and 273 state; **do not rerun/edit them**. Confirm/apply `sql/274_scout_trip_observation_stops.sql` if not already applied. Its application is not confirmed here.
2. Review the live canonical source/RPC definitions against the table above, then review/apply **`sql/275_vintage_report_revisions.sql`** once. It adds four report-only tables, RLS/grants and collection/command/worker/cancellation RPCs; no operational schema or data is rewritten. The worker is service-only. This migration remains unapplied.
3. Configure the server environment names listed above; keep keys off clients. Review the pinned model, budget, stored-response retention and provider privacy settings.
4. Deploy `supabase/functions/vintage-report/index.ts` as **`vintage-report`**. The function performs its own JWT/user/membership authentication; do not expose service credentials to native apps. No deployment happened in this pass.
5. Perform controlled preview acceptance before enabling any wider access/release. Previous field acceptance remains outstanding.

## Changed files

- `sql/275_vintage_report_revisions.sql` (new, unapplied).
- `supabase/functions/vintage-report/index.ts` (new, undeployed).
- iOS `VineTrack/App/Insights/`: new `VintageReportModel.swift`, `VintageReportWorkspaceView.swift`, `VintageReportExport.swift`, `VintageReportContent.swift`, `VintageReportCoverage.swift`, `VintageReportRevision.swift`, `VintageReportRequestInput.swift`, `VintageReportRequest.swift`, `VintageReportCommand.swift`, `VintageReportCache.swift`, `VintageReportRead.swift`; edited `VineyardInsightsView.swift` navigation and `VineyardInsightsService.swift` read-only pending-evidence helper.
- Android `app/src/main/java/com/rork/vinetrack/`: new `data/insights/VintageReportViewModel.kt`, `data/insights/VintageReportExport.kt`, `ui/screens/VintageReportScreen.kt`; new data/insights models `VintageReportContent.kt`, `VintageReportCoverage.kt`, `VintageReportRevision.kt`, `VintageReportNarrative.kt`, `VintageReportRequestInput.kt`, `VintageReportRequest.kt`, `VintageReportCommand.kt`, `VintageReportCache.kt`, `VintageReportUiState.kt`, `VintageReportPointer.kt`, `VintageReportRead.kt`; edited `ui/AppViewModel.kt` report preflight/gates and `ui/screens/VineyardInsightsScreen.kt` navigation.
- `android-vinetrack/app/src/main/res/xml/file_paths.xml` adds the narrow persistent export path.
- This existing contract is updated. No prior Work Task plan/acceptance status is changed.

## Acceptance checklist — not executed

- Generate an empty/partial/complete season; verify canonical non-January, January and leap-day boundaries, timezone and through-date behavior; no fabricated empty report.
- Regenerate while keeping old/manual revisions visible; candidate remains noncurrent until confirmation.
- Add an older late-entered event; unchanged append makes no paid call/revision; amendments, deletion, reopening and changed reporting scope produce explicit corrections.
- Two stops in one block remain distinct; unfinished/deleted stops excluded; legacy context unknown; stop capture crossing midnight/report cutoff handled honestly.
- Linked E-L, sprays/Trips and task/pruning operations are not duplicated; plans and E-L compatibility dates never become actual activity/completion dates.
- Restart/double-tap/lost response: reuse exact operation, restore server envelope, recover a stored/validated result without another model POST; test missing provider ID, expiry and safe cancellation fence.
- Concurrent edit/generation/activation: expected-pointer conflict, immutable history, no silent overwrite or automatic rebase. Open a narrative draft, advance the current revision from another session, refresh while editing, then attempt Save: retain the draft and reject the stale edit without creating an operation. Repeat without refreshing to verify server-side conflict handling.
- Missing rain days/source switches break runs; no current-cache season extrapolation, imaginary average, frost-damage or wind-damage inference.
- Offline downloaded history/PDF/DOCX readable; sign-out, account/vineyard/vintage switching and revoked preview access isolate the interface.
- PDF wrapping/long references/branding and genuine Word opening, dated addenda, historical/current appendices, pagination and explicit share/storage errors on both platforms.
