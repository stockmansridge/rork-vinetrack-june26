#!/usr/bin/env bash
# =============================================================================
# probe-sql190-pruning-labour.sh — post-deploy verification for SQL 190
# =============================================================================
# Verifies that a DEPLOYED vinetrack-api is serving the SQL 190 pruning labour
# payload, that pre-190 consumers are unaffected, and that an activity with
# MULTIPLE labour lines reports the right numbers.
#
# No secrets live in this file. Provide fixtures via environment variables.
#
# Required:
#   GATEWAY_URL          e.g. https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api
#   VT_VINEYARD_GRANTED  vineyard UUID granted to the integration
#   VT_KEY_SENSITIVE     key with pruning:read + labour:read + costs:read
#
# Optional (checks are skipped when unset):
#   VT_KEY_FULL          key with pruning:read but NO labour:read / costs:read
#                        (proves the new fields are scope-gated)
#   VT_PRUNING_MULTILINE pruning_activities UUID known to own >= 2 active
#                        labour lines. When unset the script discovers one by
#                        scanning the collection for labour_line_count >= 2.
#   VT_PRUNING_LEGACY    pruning_activities UUID created BEFORE SQL 190
#                        (worker_or_crew + labour_hours + hourly_rate, no
#                        labour lines) — proves legacy records are untouched.
#
# Usage:
#   GATEWAY_URL=... VT_KEY_SENSITIVE=vt_live_... VT_VINEYARD_GRANTED=... \
#     ./scripts/probe-sql190-pruning-labour.sh
# =============================================================================

set -uo pipefail

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
: "${GATEWAY_URL:?set GATEWAY_URL}"
: "${VT_KEY_SENSITIVE:?set VT_KEY_SENSITIVE}"
: "${VT_VINEYARD_GRANTED:?set VT_VINEYARD_GRANTED}"

PASS=0; FAIL=0; SKIP=0
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

call() { # call <method> <path> <auth>
  curl -s -X "$1" -o "$BODY_FILE" -w "%{http_code}" -H "Authorization: Bearer $3" "${GATEWAY_URL}$2"
}
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1 (body=$(head -c 400 "$BODY_FILE"))"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP  $1"; }
body() { if jq -e "$2" "$BODY_FILE" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== 1. Function is live and serving SQL 190 =="
s=$(call GET "/v1/pruning?vineyard_id=$VT_VINEYARD_GRANTED&limit=25" "$VT_KEY_SENSITIVE")
if [ "$s" != 200 ]; then
  bad "GET /v1/pruning -> 200 (got $s)"
  echo; echo "Cannot continue without a readable pruning collection."; exit 1
fi
ok "GET /v1/pruning -> 200"

# The three scalars are unconditional on every activity: their presence is the
# single clearest signal that the NEW build is live, not the old one.
body "every activity carries total_labour_hours" \
  '(.data|length)==0 or ([.data[]|has("total_labour_hours")]|all)'
body "every activity carries labour_hours_source" \
  '(.data|length)==0 or ([.data[]|has("labour_hours_source")]|all)'
body "every activity carries labour_line_count" \
  '(.data|length)==0 or ([.data[]|has("labour_line_count")]|all)'
body "labour_hours_source is a known value or null" \
  '[.data[].labour_hours_source]|all(.==null or IN("labour_lines","activity_hours"))'
body "labour_line_count is a non-negative integer" \
  '[.data[].labour_line_count]|all(type=="number" and .>=0 and (.==floor))'
body "labour_lines present with labour:read" \
  '(.data|length)==0 or ([.data[]|.labour_lines|type=="array"]|all)'
body "labour_line_count matches labour_lines length" \
  '(.data|length)==0 or ([.data[]|.labour_line_count==(.labour_lines|length)]|all)'
body "labour_cost_source uses the SQL 190 vocabulary" \
  '[.data[].labour_cost_source]|all(.==null or IN("piece_rate","pruning_labour_lines","labour_lines","activity_hours"))'

echo
echo "== 2. Backward compatibility: every pre-190 key survives =="
# A pre-190 consumer reads these. Same names, same types, same meaning.
body "pre-190 identity keys intact" \
  '(.data|length)==0 or ([.data[]|has("id") and has("vineyard_id") and has("date")]|all)'
body "pre-190 labour_hours still present (AS RECORDED)" \
  '(.data|length)==0 or ([.data[]|has("labour_hours")]|all)'
body "pre-190 metric keys intact" \
  '(.data|length)==0 or ([.data[]|has("vines_pruned") and has("row_equivalents") and has("quarters_completed") and has("vines_per_labour_hour")]|all)'
body "pre-190 labour_hours is number-or-null (type unchanged)" \
  '[.data[].labour_hours]|all(.==null or type=="number")'
body "pre-190 vines_per_labour_hour is number-or-null" \
  '[.data[].vines_per_labour_hour]|all(.==null or type=="number")'
body "pre-190 crew still gated behind labour:read" \
  '(.data|length)==0 or ([.data[]|has("crew")]|all)'
# The cardinal money rule: unknown is null, never 0.00.
body "labour_cost is never a manufactured 0 when source is null" \
  '[.data[]|select(.labour_cost_source==null)|.labour_cost]|all(.==null)'

echo
echo "== 3. Scope gating on the NEW fields =="
if [ -n "${VT_KEY_FULL-}" ]; then
  s=$(call GET "/v1/pruning?vineyard_id=$VT_VINEYARD_GRANTED&limit=25" "$VT_KEY_FULL")
  if [ "$s" = 200 ]; then
    ok "GET /v1/pruning with base key -> 200"
    body "labour_lines hidden without labour:read" \
      '[.data[]|has("labour_lines")]|any|not'
    body "crew hidden without labour:read" \
      '[.data[]|has("crew")]|any|not'
    # Hours are operational, not financial — they stay visible.
    body "total_labour_hours still visible (hours are not financial)" \
      '(.data|length)==0 or ([.data[]|has("total_labour_hours")]|all)'
  else bad "GET /v1/pruning with base key -> 200 (got $s)"; fi
else skip "base-key scope gating (set VT_KEY_FULL)"; fi

echo
echo "== 4. Live probe: an activity with MULTIPLE labour lines =="
TARGET="${VT_PRUNING_MULTILINE-}"
if [ -z "$TARGET" ]; then
  s=$(call GET "/v1/pruning?vineyard_id=$VT_VINEYARD_GRANTED&limit=200" "$VT_KEY_SENSITIVE")
  TARGET=$(jq -r 'first(.data[]|select(.labour_line_count>=2)|.id) // empty' "$BODY_FILE")
  [ -n "$TARGET" ] && echo "  discovered multi-line activity: $TARGET"
fi

if [ -z "$TARGET" ]; then
  skip "multi-line probe (no activity with >=2 labour lines; set VT_PRUNING_MULTILINE)"
else
  s=$(call GET "/v1/pruning/$TARGET" "$VT_KEY_SENSITIVE")
  if [ "$s" != 200 ]; then bad "GET /v1/pruning/$TARGET -> 200 (got $s)"; else
    ok "GET /v1/pruning/$TARGET -> 200"
    jq '{id,labour_hours,total_labour_hours,labour_hours_source,labour_line_count,
         labour_cost,labour_cost_source,costing_method,
         lines:[.labour_lines[]|{worker_type,worker_count,hours_per_worker,total_hours,hourly_rate,total_cost}]}' \
      "$BODY_FILE"

    body "detail exposes >= 2 labour lines" '.labour_lines|length>=2'
    body "lines carry the mirrored work_task_labour_lines shape" \
      '[.labour_lines[]|has("id") and has("work_date") and has("worker_type") and has("worker_count") and has("hours_per_worker") and has("total_hours") and has("line_index")]|all'
    body "lines are ordered by line_index" \
      '[.labour_lines[].line_index] as $i | $i == ($i|sort)'
    # HOURS sum EVERY active line, including unrated ones.
    body "total_labour_hours == sum of ALL line total_hours (unrated included)" \
      '(([.labour_lines[].total_hours]|add) - .total_labour_hours)|fabs < 0.005'
    body "labour_hours_source == labour_lines when lines exist" \
      '.labour_hours_source=="labour_lines"'
    # COST sums only RATED lines — unrated must not become $0.00.
    body "labour_cost == sum of RATED line total_cost (or null when none rated)" \
      'if ([.labour_lines[]|select(.hourly_rate!=null)]|length)==0
       then .labour_cost==null
       else ((([.labour_lines[]|select(.hourly_rate!=null)|.total_cost]|add) - .labour_cost)|fabs < 0.005) end'
    body "unrated lines report total_cost null, never 0.00" \
      '[.labour_lines[]|select(.hourly_rate==null)|.total_cost]|all(.==null)'
    body "cost source is pruning_labour_lines OR piece_rate (never summed)" \
      '.labour_cost_source==null or IN(.labour_cost_source;"pruning_labour_lines","piece_rate")'
    # Piece rate wins outright; it is never added to line cost.
    body "piece-rate activity ignores line cost entirely" \
      'if .costing_method=="piece_rate" and .labour_cost!=null
       then .labour_cost_source=="piece_rate" else true end'
    body "vines_per_labour_hour derived from total_labour_hours" \
      'if (.total_labour_hours//0)>0 and (.vines_pruned//0)>0
       then ((.vines_pruned/.total_labour_hours*10|round/10) - .vines_per_labour_hour)|fabs < 0.05
       else true end'
  fi
fi

echo
echo "== 5. Legacy activity is untouched =="
if [ -n "${VT_PRUNING_LEGACY-}" ]; then
  s=$(call GET "/v1/pruning/$VT_PRUNING_LEGACY" "$VT_KEY_SENSITIVE")
  if [ "$s" = 200 ]; then
    ok "GET legacy activity -> 200"
    body "legacy activity owns no labour lines" '.labour_line_count==0'
    body "legacy labour_hours reported as recorded" \
      '.labour_hours!=null and .total_labour_hours==.labour_hours'
    body "legacy hours source is activity_hours" '.labour_hours_source=="activity_hours"'
    body "legacy crew text preserved" 'has("crew")'
    body "legacy cost still resolves from the scalar pair" \
      '.labour_cost_source==null or IN(.labour_cost_source;"activity_hours","labour_lines","piece_rate")'
  else bad "GET legacy activity -> 200 (got $s)"; fi
else skip "legacy activity (set VT_PRUNING_LEGACY)"; fi

echo
echo "==============================================="
echo "PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "==============================================="
[ "$FAIL" -eq 0 ] || exit 1
