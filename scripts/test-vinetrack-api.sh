#!/usr/bin/env bash
# =============================================================================
# test-vinetrack-api.sh — Stage 3A-3D + Stage 8 gateway security tests (HTTP level)
# =============================================================================
# Runs the security/contract checks against a DEPLOYED vinetrack-api gateway.
# Complements sql/tests/173_integration_api_gateway_tests.sql (DB level).
#
# No secrets live in this file. Provide fixtures via environment variables.
# Create fixtures with the SQL 172 management RPCs (integration_create_client,
# integration_grant_vineyard, integration_grant_scope,
# integration_create_api_key) in the Supabase SQL editor — see
# docs/vinetrack-api-v1.md "Creating test credentials".
#
# Required:
#   GATEWAY_URL           e.g. https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/vinetrack-api
#   VT_KEY_FULL           active key; integration has vineyards:read, blocks:read,
#                         trips:read, sprays:read, fuel:read, equipment:read,
#                         work_tasks:read, pruning:read, irrigation:read,
#                         growth_stages:read, yield:read, pins:read,
#                         weather:read, rainfall:read, disease_risk:read
#                         (NO costs:read / labour:read) and a grant to
#                         VT_VINEYARD_GRANTED
#   VT_VINEYARD_GRANTED   vineyard UUID granted to the integration
#   VT_BLOCK_GRANTED      block UUID inside VT_VINEYARD_GRANTED
#
# Optional (tests are skipped when unset):
#   VT_KEY_NO_SCOPES      active key on an integration with NO scopes granted
#   VT_KEY_BLOCKS_ONLY    active key with ONLY blocks:read granted
#   VT_KEY_SENSITIVE      key with all base scopes PLUS costs:read + labour:read
#   VT_KEY_REVOKED        a revoked API key
#   VT_KEY_EXPIRED        an expired API key
#   VT_KEY_PAUSED         key on a paused integration
#   VT_KEY_CLIENT_REVOKED key on a revoked integration
#   VT_VINEYARD_OTHER     vineyard UUID belonging to ANOTHER account (never granted)
#   VT_BLOCK_OTHER        block UUID inside VT_VINEYARD_OTHER
#   VT_TRIP_GRANTED       trip UUID inside VT_VINEYARD_GRANTED
#   VT_TRIP_OTHER         trip UUID inside VT_VINEYARD_OTHER
#   VT_SPRAY_GRANTED      spray record UUID inside VT_VINEYARD_GRANTED
#   VT_SPRAY_OTHER        spray record UUID inside VT_VINEYARD_OTHER
#   VT_SPRAY_PLANNED_ONLY Phase 5 planned-only spray record UUID
#   VT_SPRAY_PARTIAL      Phase 5 partially confirmed spray record UUID
#   VT_SPRAY_COMPLETE     Phase 5 fully confirmed spray record UUID
#   VT_SPRAY_ZERO         Phase 5 fully confirmed record with an explicit zero product
#   VT_SPRAY_MISSING_LINE Phase 5 actual row missing a planned chemical line
#   VT_FUEL_RECORD_GRANTED    tractor_fuel_logs UUID inside VT_VINEYARD_GRANTED
#   VT_FUEL_RECORD_OTHER      tractor_fuel_logs UUID inside VT_VINEYARD_OTHER
#   VT_FUEL_PURCHASE_GRANTED  fuel_purchases UUID inside VT_VINEYARD_GRANTED
#   VT_FUEL_PURCHASE_OTHER    fuel_purchases UUID inside VT_VINEYARD_OTHER
#   VT_EQUIPMENT_GRANTED  vineyard_machines/spray_equipment/equipment_items UUID
#                         inside VT_VINEYARD_GRANTED
#   VT_EQUIPMENT_OTHER    equipment UUID inside VT_VINEYARD_OTHER
#   VT_WORK_TASK_GRANTED    work_tasks UUID inside VT_VINEYARD_GRANTED
#   VT_WORK_TASK_OTHER      work_tasks UUID inside VT_VINEYARD_OTHER
#   VT_PRUNING_GRANTED      pruning_activities UUID inside VT_VINEYARD_GRANTED
#   VT_PRUNING_OTHER        pruning_activities UUID inside VT_VINEYARD_OTHER
#   VT_IRRIGATION_GRANTED   irrigation_sessions UUID inside VT_VINEYARD_GRANTED
#   VT_IRRIGATION_OTHER     irrigation_sessions UUID inside VT_VINEYARD_OTHER
#   VT_GROWTH_STAGE_GRANTED growth_stage_records UUID inside VT_VINEYARD_GRANTED
#   VT_GROWTH_STAGE_OTHER   growth_stage_records UUID inside VT_VINEYARD_OTHER
#   VT_YIELD_GRANTED        historical_yield_records UUID inside VT_VINEYARD_GRANTED
#   VT_YIELD_OTHER          historical_yield_records UUID inside VT_VINEYARD_OTHER
#   VT_PIN_GRANTED          pins UUID inside VT_VINEYARD_GRANTED
#   VT_PIN_OTHER            pins UUID inside VT_VINEYARD_OTHER
#   VT_KEY_WRITE            (Stage 8) active key whose integration has
#                           work_tasks:write (+ optionally the other write
#                           scopes) and a grant to VT_VINEYARD_GRANTED.
#                           NOTE: the write tests CREATE clearly-labelled
#                           "Stage 8 API test" work tasks inside
#                           VT_VINEYARD_GRANTED — use a dedicated test
#                           vineyard, then archive/delete the test tasks.
#
# Usage:
#   GATEWAY_URL=... VT_KEY_FULL=vt_test_... VT_VINEYARD_GRANTED=... \
#   VT_BLOCK_GRANTED=... ./scripts/test-vinetrack-api.sh
# =============================================================================

set -uo pipefail

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
: "${GATEWAY_URL:?set GATEWAY_URL}"
: "${VT_KEY_FULL:?set VT_KEY_FULL}"
: "${VT_VINEYARD_GRANTED:?set VT_VINEYARD_GRANTED}"
: "${VT_BLOCK_GRANTED:?set VT_BLOCK_GRANTED}"

PASS=0; FAIL=0; SKIP=0
BODY_FILE=$(mktemp); HDR_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$HDR_FILE"' EXIT

# call <method> <path> [auth-header-value]
call() {
  local method="$1" path="$2" auth="${3-}"
  local args=(-s -X "$method" -o "$BODY_FILE" -D "$HDR_FILE" -w "%{http_code}")
  [ -n "$auth" ] && args+=(-H "Authorization: $auth")
  curl "${args[@]}" "${GATEWAY_URL}${path}"
}

check() { # check <name> <expected_status> <actual_status> [expected_error_code]
  local name="$1" want="$2" got="$3" want_code="${4-}"
  local ok=1
  [ "$got" = "$want" ] || ok=0
  if [ -n "$want_code" ]; then
    local code; code=$(jq -r '.error.code // empty' "$BODY_FILE")
    [ "$code" = "$want_code" ] || ok=0
  fi
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); echo "PASS  $name"
  else FAIL=$((FAIL+1)); echo "FAIL  $name (status=$got, body=$(head -c 300 "$BODY_FILE"))"; fi
}

# check_body <name> <jq-expression> — passes when the expression is truthy
check_body() {
  local name="$1" expr="$2"
  if jq -e "$expr" "$BODY_FILE" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "PASS  $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $name (body=$(head -c 300 "$BODY_FILE"))"
  fi
}

# call_write <method> <path> <auth> <idempotency-key-or-empty> <raw-body-or-empty>
call_write() {
  local method="$1" path="$2" auth="$3" idem="$4" body="$5"
  local args=(-s -X "$method" -o "$BODY_FILE" -D "$HDR_FILE" -w "%{http_code}" -H "Content-Type: application/json")
  [ -n "$auth" ] && args+=(-H "Authorization: $auth")
  [ -n "$idem" ] && args+=(-H "Idempotency-Key: $idem")
  [ -n "$body" ] && args+=(--data "$body")
  curl "${args[@]}" "${GATEWAY_URL}${path}"
}

skip() { SKIP=$((SKIP+1)); echo "SKIP  $1 (fixture not provided)"; }

echo "== Authentication =="
s=$(call GET /v1/me);                              check "missing Authorization -> 401 missing_api_key" 401 "$s" missing_api_key
s=$(call GET /v1/me "NotBearer xyz");              check "malformed Authorization -> 401 invalid_api_key" 401 "$s" invalid_api_key
s=$(call GET /v1/me "Bearer not_a_vinetrack_key"); check "non-VineTrack token -> 401 invalid_api_key" 401 "$s" invalid_api_key
s=$(call GET /v1/me "Bearer vt_live_$(printf '0%.0s' {1..48})"); check "unknown key -> 401 invalid_api_key" 401 "$s" invalid_api_key
s=$(call GET /v1/me "Bearer $VT_KEY_FULL");        check "valid key -> 200 /v1/me" 200 "$s"

REQ_ID=$(grep -i '^x-vinetrack-request-id:' "$HDR_FILE" | tr -d '\r' | awk '{print $2}')
if [ -n "$REQ_ID" ]; then PASS=$((PASS+1)); echo "PASS  X-VineTrack-Request-ID present ($REQ_ID)"
else FAIL=$((FAIL+1)); echo "FAIL  X-VineTrack-Request-ID missing"; fi

if [ -n "${VT_KEY_EXPIRED-}" ]; then
  s=$(call GET /v1/me "Bearer $VT_KEY_EXPIRED"); check "expired key -> 401 expired_api_key" 401 "$s" expired_api_key
else skip "expired key"; fi
if [ -n "${VT_KEY_REVOKED-}" ]; then
  s=$(call GET /v1/me "Bearer $VT_KEY_REVOKED"); check "revoked key -> 401 revoked_api_key" 401 "$s" revoked_api_key
else skip "revoked key"; fi
if [ -n "${VT_KEY_PAUSED-}" ]; then
  s=$(call GET /v1/me "Bearer $VT_KEY_PAUSED"); check "paused integration -> 403 integration_not_active" 403 "$s" integration_not_active
else skip "paused integration"; fi
if [ -n "${VT_KEY_CLIENT_REVOKED-}" ]; then
  s=$(call GET /v1/me "Bearer $VT_KEY_CLIENT_REVOKED"); check "revoked integration -> 403 integration_not_active" 403 "$s" integration_not_active
else skip "revoked integration"; fi

echo
echo "== Scope enforcement =="
s=$(call GET /v1/vineyards "Bearer $VT_KEY_FULL"); check "vineyards:read allows /v1/vineyards" 200 "$s"
s=$(call GET "/v1/blocks?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL"); check "blocks:read allows /v1/blocks" 200 "$s"

if [ -n "${VT_KEY_NO_SCOPES-}" ]; then
  s=$(call GET /v1/me "Bearer $VT_KEY_NO_SCOPES"); check "/v1/me works without resource scopes" 200 "$s"
  s=$(call GET /v1/vineyards "Bearer $VT_KEY_NO_SCOPES"); check "no scopes -> vineyards 403 insufficient_scope" 403 "$s" insufficient_scope
  s=$(call GET "/v1/blocks?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_NO_SCOPES"); check "no scopes -> blocks 403 insufficient_scope" 403 "$s" insufficient_scope
  s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_NO_SCOPES"); check "no scopes -> trips 403 insufficient_scope" 403 "$s" insufficient_scope
  s=$(call GET "/v1/fuel-purchases?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_NO_SCOPES"); check "costs:read alone would still fail: no fuel:read -> 403" 403 "$s" insufficient_scope
else skip "no-scope key (5 tests)"; fi

if [ -n "${VT_KEY_BLOCKS_ONLY-}" ]; then
  s=$(call GET /v1/vineyards "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply vineyards:read" 403 "$s" insufficient_scope
  s=$(call GET "/v1/blocks?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks-only key can read blocks" 200 "$s"
  s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply trips:read" 403 "$s" insufficient_scope
  s=$(call GET "/v1/spray-jobs?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply sprays:read" 403 "$s" insufficient_scope
  s=$(call GET "/v1/equipment?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply equipment:read" 403 "$s" insufficient_scope
else skip "blocks-only key (5 tests)"; fi

echo
echo "== Vineyard isolation =="
s=$(call GET "/v1/vineyards/$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL"); check "granted vineyard retrievable" 200 "$s"
s=$(call GET "/v1/blocks/$VT_BLOCK_GRANTED" "Bearer $VT_KEY_FULL"); check "granted block retrievable" 200 "$s"

if [ -n "${VT_VINEYARD_OTHER-}" ]; then
  s=$(call GET "/v1/vineyards/$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "other account's vineyard -> 404 (no existence leak)" 404 "$s" resource_not_found
  s=$(call GET "/v1/blocks?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "blocks in ungranted vineyard -> 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
  # Stage 3A regression (brief §17): the 403 must carry the full JSON envelope.
  check_body "403 vineyard_access_denied carries JSON error envelope (regression)" \
    '.error.code == "vineyard_access_denied" and (.error.message | length > 0) and (.error.request_id | startswith("req_"))'
  s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "trips in ungranted vineyard -> 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
  s=$(call GET "/v1/equipment?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "equipment in ungranted vineyard -> 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
else skip "other-account vineyard (5 tests)"; fi
if [ -n "${VT_BLOCK_OTHER-}" ]; then
  s=$(call GET "/v1/blocks/$VT_BLOCK_OTHER" "Bearer $VT_KEY_FULL"); check "other account's block -> 404 (no existence leak)" 404 "$s" resource_not_found
else skip "other-account block"; fi
s=$(call GET "/v1/vineyards/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL"); check "random vineyard uuid -> 404" 404 "$s" resource_not_found
s=$(call GET "/v1/blocks/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL"); check "random block uuid -> 404" 404 "$s" resource_not_found

echo
echo "== Responses & contract =="
s=$(call GET /v1/vineyards "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ] && jq -e 'has("data") and (.data | type == "array") and (.pagination | has("next_cursor"))' "$BODY_FILE" >/dev/null; then
  PASS=$((PASS+1)); echo "PASS  collection envelope { data: [], pagination: { next_cursor } }"
else FAIL=$((FAIL+1)); echo "FAIL  collection envelope"; fi

s=$(call GET "/v1/vineyards/$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ] && jq -e '(.data | type == "object") and (.data.id != null)' "$BODY_FILE" >/dev/null; then
  PASS=$((PASS+1)); echo "PASS  single-resource envelope { data: {} }"
else FAIL=$((FAIL+1)); echo "FAIL  single-resource envelope"; fi

s=$(call GET /v1/me)
if [ "$s" = 401 ] && jq -e '.error.code and .error.message and .error.request_id' "$BODY_FILE" >/dev/null; then
  PASS=$((PASS+1)); echo "PASS  error envelope { error: { code, message, request_id } }"
else FAIL=$((FAIL+1)); echo "FAIL  error envelope"; fi

s=$(call POST /v1/vineyards "Bearer $VT_KEY_FULL"); check "POST -> 405 method_not_allowed" 405 "$s" method_not_allowed
s=$(call DELETE /v1/me "Bearer $VT_KEY_FULL");     check "DELETE -> 405 method_not_allowed" 405 "$s" method_not_allowed
s=$(call POST "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL"); check "POST trips -> 405 (write access impossible)" 405 "$s" method_not_allowed
s=$(call GET /v1/nonexistent "Bearer $VT_KEY_FULL"); check "unknown route -> 404 JSON error" 404 "$s" resource_not_found
s=$(call GET "/v1/vineyards?cursor=%%%bogus" "Bearer $VT_KEY_FULL"); check "invalid cursor -> 400 invalid_cursor" 400 "$s" invalid_cursor
s=$(call GET "/v1/vineyards?limit=5000" "Bearer $VT_KEY_FULL"); check "limit > 1000 -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/vineyards?bogus_param=1" "Bearer $VT_KEY_FULL"); check "unknown query param -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/blocks" "Bearer $VT_KEY_FULL"); check "blocks without vineyard_id -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/me?api_key=$VT_KEY_FULL"); check "query-string credential -> 400 invalid_request" 400 "$s" invalid_request

echo
echo "== Stage 3B: operational collections =="
for res in trips spray-jobs fuel-records fuel-purchases equipment; do
  s=$(call GET "/v1/$res?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
  check "GET /v1/$res -> 200" 200 "$s"
  check_body "/v1/$res collection envelope" \
    'has("data") and (.data | type == "array") and (.pagination | has("next_cursor"))'
  s=$(call GET "/v1/$res" "Bearer $VT_KEY_FULL")
  check "/v1/$res without vineyard_id -> 400 invalid_request" 400 "$s" invalid_request
done

echo
echo "== Stage 3B: filters =="
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&from=2020-01-01&to=2030-12-31" "Bearer $VT_KEY_FULL"); check "trips date range accepted" 200 "$s"
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&from=2026-13-45" "Bearer $VT_KEY_FULL"); check "invalid date -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&from=2026-02-31" "Bearer $VT_KEY_FULL"); check "non-real date (Feb 31) -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&from=2026-06-01&to=2026-01-01" "Bearer $VT_KEY_FULL"); check "from > to -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&equipment_id=00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL")
check "unknown equipment filter -> 200 empty (non-disclosing)" 200 "$s"
check_body "unknown equipment filter returns empty data" '.data == []'
s=$(call GET "/v1/spray-jobs?vineyard_id=$VT_VINEYARD_GRANTED&status=done" "Bearer $VT_KEY_FULL"); check "unsupported spray filter -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/fuel-records?vineyard_id=$VT_VINEYARD_GRANTED&from=2020-01-01&to=2030-12-31" "Bearer $VT_KEY_FULL"); check "fuel-records date range accepted" 200 "$s"
s=$(call GET "/v1/equipment?vineyard_id=$VT_VINEYARD_GRANTED&type=machine" "Bearer $VT_KEY_FULL"); check "equipment type=machine accepted" 200 "$s"
s=$(call GET "/v1/equipment?vineyard_id=$VT_VINEYARD_GRANTED&type=tractor" "Bearer $VT_KEY_FULL"); check "equipment type=tractor (machine_type) accepted" 200 "$s"
s=$(call GET "/v1/equipment?vineyard_id=$VT_VINEYARD_GRANTED&type=spaceship" "Bearer $VT_KEY_FULL"); check "equipment unknown type -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/equipment?vineyard_id=$VT_VINEYARD_GRANTED&from=2020-01-01" "Bearer $VT_KEY_FULL"); check "equipment rejects date params -> 400 invalid_request" 400 "$s" invalid_request

echo
echo "== Stage 3B: sensitive-field gating (base key = no costs/labour) =="
s=$(call GET "/v1/fuel-purchases?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ]; then
  check_body "fuel purchases omit total_price / price_per_litre without costs:read" \
    '[.data[] | has("total_price") or has("price_per_litre")] | any | not'
fi
s=$(call GET "/v1/fuel-records?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ]; then
  check_body "fuel records omit cost fields without costs:read" \
    '[.data[] | has("cost_per_litre") or has("total_cost")] | any | not'
  check_body "fuel records omit operator without labour:read" \
    '[.data[] | has("operator")] | any | not'
fi
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ]; then
  check_body "trips omit operator without labour:read" \
    '[.data[] | has("operator")] | any | not'
fi

if [ -n "${VT_KEY_SENSITIVE-}" ]; then
  s=$(call GET "/v1/fuel-purchases?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_SENSITIVE")
  if [ "$s" = 200 ]; then
    check_body "fuel purchases include monetary fields with fuel:read + costs:read" \
      '(.data | length == 0) or ([.data[] | has("total_price") and has("price_per_litre")] | all)'
  else
    check "sensitive key can list fuel purchases" 200 "$s"
  fi
  s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_SENSITIVE")
  if [ "$s" = 200 ]; then
    check_body "trips include operator field with labour:read" \
      '(.data | length == 0) or ([.data[] | has("operator")] | all)'
  else
    check "sensitive key can list trips" 200 "$s"
  fi
else skip "sensitive key (costs/labour gating positive checks)"; fi

echo
echo "== Stage 3B: single resources & cross-vineyard non-disclosure =="
s=$(call GET "/v1/trips/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL"); check "random trip uuid -> 404" 404 "$s" resource_not_found
s=$(call GET "/v1/spray-jobs/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL"); check "random spray uuid -> 404" 404 "$s" resource_not_found
s=$(call GET "/v1/fuel-records/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL"); check "random fuel record uuid -> 404" 404 "$s" resource_not_found
s=$(call GET "/v1/fuel-purchases/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL"); check "random fuel purchase uuid -> 404" 404 "$s" resource_not_found
s=$(call GET "/v1/equipment/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL"); check "random equipment uuid -> 404" 404 "$s" resource_not_found

if [ -n "${VT_TRIP_GRANTED-}" ]; then
  s=$(call GET "/v1/trips/$VT_TRIP_GRANTED" "Bearer $VT_KEY_FULL"); check "granted trip retrievable" 200 "$s"
  check_body "trip detail has rows summary" '.data.rows | has("planned") and has("completed") and has("skipped")'
  check_body "trip detail omits costs without costs:read" '.data | has("costs") | not'
else skip "granted trip (3 tests)"; fi
if [ -n "${VT_TRIP_OTHER-}" ]; then
  s=$(call GET "/v1/trips/$VT_TRIP_OTHER" "Bearer $VT_KEY_FULL"); check "other account's trip -> 404 (no existence leak)" 404 "$s" resource_not_found
else skip "other-account trip"; fi

if [ -n "${VT_SPRAY_GRANTED-}" ]; then
  s=$(call GET "/v1/spray-records/$VT_SPRAY_GRANTED" "Bearer $VT_KEY_FULL"); check "granted spray record retrievable" 200 "$s"
  check_body "spray detail has tanks array" '.data.tanks | type == "array"'
  check_body "spray detail has blocks array" '.data.blocks | type == "array"'
  check_body "spray products omit cost_per_unit without costs:read" \
    '[.data.tanks[].products[]? | has("cost_per_unit")] | any | not'
  check_body "spray conditions use explicit units" \
    '.data.conditions | has("temperature_c") and has("wind_speed_kmh") and has("humidity_percent")'
  check_body "legacy water_volume_l remains planned water" '.data.water_volume_l == .data.planned_water_volume_l'
  check_body "actual tanks are exposed but cost basis is scope-gated" '(.data.actual_tanks | type == "array") and (.data | has("chemical_cost_basis") | not)'
else skip "granted spray record (7 tests)"; fi
if [ -n "${VT_SPRAY_OTHER-}" ]; then
  s=$(call GET "/v1/spray-records/$VT_SPRAY_OTHER" "Bearer $VT_KEY_FULL"); check "other account's spray record -> 404" 404 "$s" resource_not_found
else skip "other-account spray record"; fi

if [ -n "${VT_KEY_SENSITIVE-}" ]; then
  if [ -n "${VT_SPRAY_PLANNED_ONLY-}" ]; then
    s=$(call GET "/v1/spray-records/$VT_SPRAY_PLANNED_ONLY" "Bearer $VT_KEY_SENSITIVE"); check "Phase 5 planned-only spray" 200 "$s"
    check_body "planned-only actuals incomplete and estimated" '.data.actuals_complete == false and .data.actual_water_volume_l == null and .data.chemical_cost_basis == "estimated"'
  else skip "Phase 5 planned-only spray (2 tests)"; fi
  if [ -n "${VT_SPRAY_PARTIAL-}" ]; then
    s=$(call GET "/v1/spray-records/$VT_SPRAY_PARTIAL" "Bearer $VT_KEY_SENSITIVE"); check "Phase 5 partial spray" 200 "$s"
    check_body "partial actuals remain entirely estimated" '.data.actuals_complete == false and .data.actual_water_volume_l != null and .data.chemical_cost_basis == "estimated"'
  else skip "Phase 5 partial spray (2 tests)"; fi
  if [ -n "${VT_SPRAY_COMPLETE-}" ]; then
    s=$(call GET "/v1/spray-records/$VT_SPRAY_COMPLETE" "Bearer $VT_KEY_SENSITIVE"); check "Phase 5 complete spray" 200 "$s"
    check_body "complete actuals use actual basis" '.data.actuals_complete == true and .data.actual_water_volume_l != null and .data.chemical_cost_basis == "actual"'
  else skip "Phase 5 complete spray (2 tests)"; fi
  if [ -n "${VT_SPRAY_ZERO-}" ]; then
    s=$(call GET "/v1/spray-records/$VT_SPRAY_ZERO" "Bearer $VT_KEY_SENSITIVE"); check "Phase 5 confirmed-zero spray" 200 "$s"
    check_body "confirmed zero remains an explicit actual result" '.data.actuals_complete == true and [.data.actual_tanks[].actual_products[]? | select(.quantity_base == 0)] | length > 0'
  else skip "Phase 5 confirmed-zero spray (2 tests)"; fi
  if [ -n "${VT_SPRAY_MISSING_LINE-}" ]; then
    s=$(call GET "/v1/spray-records/$VT_SPRAY_MISSING_LINE" "Bearer $VT_KEY_SENSITIVE"); check "Phase 5 missing-line spray" 200 "$s"
    check_body "missing planned product confirmation is incomplete" '.data.actuals_complete == false and .data.chemical_cost_basis == "estimated"'
  else skip "Phase 5 missing-line spray (2 tests)"; fi
else skip "sensitive Phase 5 key and fixtures"; fi

if [ -n "${VT_FUEL_RECORD_GRANTED-}" ]; then
  s=$(call GET "/v1/fuel-records/$VT_FUEL_RECORD_GRANTED" "Bearer $VT_KEY_FULL"); check "granted fuel record retrievable" 200 "$s"
  check_body "fuel record uses volume_l" '.data | has("volume_l")'
else skip "granted fuel record (2 tests)"; fi
if [ -n "${VT_FUEL_RECORD_OTHER-}" ]; then
  s=$(call GET "/v1/fuel-records/$VT_FUEL_RECORD_OTHER" "Bearer $VT_KEY_FULL"); check "other account's fuel record -> 404" 404 "$s" resource_not_found
else skip "other-account fuel record"; fi

if [ -n "${VT_FUEL_PURCHASE_GRANTED-}" ]; then
  s=$(call GET "/v1/fuel-purchases/$VT_FUEL_PURCHASE_GRANTED" "Bearer $VT_KEY_FULL"); check "granted fuel purchase retrievable" 200 "$s"
  check_body "fuel purchase omits monetary fields without costs:read" \
    '.data | (has("total_price") or has("price_per_litre")) | not'
else skip "granted fuel purchase (2 tests)"; fi
if [ -n "${VT_FUEL_PURCHASE_OTHER-}" ]; then
  s=$(call GET "/v1/fuel-purchases/$VT_FUEL_PURCHASE_OTHER" "Bearer $VT_KEY_FULL"); check "other account's fuel purchase -> 404" 404 "$s" resource_not_found
else skip "other-account fuel purchase"; fi

if [ -n "${VT_EQUIPMENT_GRANTED-}" ]; then
  s=$(call GET "/v1/equipment/$VT_EQUIPMENT_GRANTED" "Bearer $VT_KEY_FULL"); check "granted equipment retrievable" 200 "$s"
  check_body "equipment has kind + equipment_type" \
    '.data | (.kind == "machine" or .kind == "sprayer" or .kind == "item") and has("equipment_type")'
else skip "granted equipment (2 tests)"; fi
if [ -n "${VT_EQUIPMENT_OTHER-}" ]; then
  s=$(call GET "/v1/equipment/$VT_EQUIPMENT_OTHER" "Bearer $VT_KEY_FULL"); check "other account's equipment -> 404" 404 "$s" resource_not_found
else skip "other-account equipment"; fi

echo
echo "== Stage 3C: operational collections =="
for res in work-tasks pruning irrigation-records growth-stages yield-records pins; do
  s=$(call GET "/v1/$res?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
  check "GET /v1/$res -> 200" 200 "$s"
  check_body "/v1/$res collection envelope" \
    'has("data") and (.data | type == "array") and (.pagination | has("next_cursor"))'
  s=$(call GET "/v1/$res" "Bearer $VT_KEY_FULL")
  check "/v1/$res without vineyard_id -> 400 invalid_request" 400 "$s" invalid_request
done

if [ -n "${VT_KEY_NO_SCOPES-}" ]; then
  s=$(call GET "/v1/work-tasks?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_NO_SCOPES"); check "no scopes -> work-tasks 403 insufficient_scope" 403 "$s" insufficient_scope
  s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_NO_SCOPES"); check "no scopes -> pins 403 insufficient_scope" 403 "$s" insufficient_scope
else skip "no-scope key 3C (2 tests)"; fi
if [ -n "${VT_KEY_BLOCKS_ONLY-}" ]; then
  s=$(call GET "/v1/pruning?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply pruning:read" 403 "$s" insufficient_scope
  s=$(call GET "/v1/irrigation-records?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply irrigation:read" 403 "$s" insufficient_scope
  s=$(call GET "/v1/yield-records?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply yield:read" 403 "$s" insufficient_scope
else skip "blocks-only key 3C (3 tests)"; fi
if [ -n "${VT_VINEYARD_OTHER-}" ]; then
  s=$(call GET "/v1/work-tasks?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "work-tasks in ungranted vineyard -> 403" 403 "$s" vineyard_access_denied
  s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "pins in ungranted vineyard -> 403" 403 "$s" vineyard_access_denied
else skip "other-account vineyard 3C (2 tests)"; fi

echo
echo "== Stage 3C: filters =="
s=$(call GET "/v1/work-tasks?vineyard_id=$VT_VINEYARD_GRANTED&from=2020-01-01&to=2030-12-31&status=completed&task_type=Mowing&block_id=$VT_BLOCK_GRANTED" "Bearer $VT_KEY_FULL"); check "work-tasks combined filters accepted" 200 "$s"
s=$(call GET "/v1/work-tasks?vineyard_id=$VT_VINEYARD_GRANTED&block_id=not-a-uuid" "Bearer $VT_KEY_FULL"); check "work-tasks bad block_id -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/work-tasks?vineyard_id=$VT_VINEYARD_GRANTED&worker=bob" "Bearer $VT_KEY_FULL"); check "work-tasks unknown param -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/pruning?vineyard_id=$VT_VINEYARD_GRANTED&from=2020-01-01&to=2030-12-31&block_id=$VT_BLOCK_GRANTED" "Bearer $VT_KEY_FULL"); check "pruning date+block filters accepted" 200 "$s"
s=$(call GET "/v1/irrigation-records?vineyard_id=$VT_VINEYARD_GRANTED&status=completed" "Bearer $VT_KEY_FULL"); check "irrigation status=completed accepted" 200 "$s"
s=$(call GET "/v1/irrigation-records?vineyard_id=$VT_VINEYARD_GRANTED&status=finished" "Bearer $VT_KEY_FULL"); check "irrigation unknown status -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/growth-stages?vineyard_id=$VT_VINEYARD_GRANTED&stage_code=EL-12&block_id=$VT_BLOCK_GRANTED" "Bearer $VT_KEY_FULL"); check "growth-stages stage_code+block filters accepted" 200 "$s"
s=$(call GET "/v1/yield-records?vineyard_id=$VT_VINEYARD_GRANTED&vintage=2026" "Bearer $VT_KEY_FULL"); check "yield vintage=2026 accepted" 200 "$s"
s=$(call GET "/v1/yield-records?vineyard_id=$VT_VINEYARD_GRANTED&vintage=26" "Bearer $VT_KEY_FULL"); check "yield bad vintage -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED&status=open&type=repairs&block_id=$VT_BLOCK_GRANTED" "Bearer $VT_KEY_FULL"); check "pins status+type+block filters accepted" 200 "$s"
s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED&status=fixed" "Bearer $VT_KEY_FULL"); check "pins unknown status -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED&type=spaceship" "Bearer $VT_KEY_FULL"); check "pins unknown type -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED&from=2020-01-01" "Bearer $VT_KEY_FULL"); check "pins reject date params -> 400" 400 "$s" invalid_request

echo
echo "== Stage 3C: sensitive-field gating (base key = no costs/labour) =="
s=$(call GET "/v1/pruning?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ]; then
  check_body "pruning omits crew without labour:read" '[.data[] | has("crew")] | any | not'
  check_body "pruning omits hourly_rate/labour_cost without costs:read" \
    '[.data[] | has("hourly_rate") or has("labour_cost")] | any | not'
fi
s=$(call GET "/v1/growth-stages?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ]; then
  check_body "growth-stages omit recorded_by without labour:read" '[.data[] | has("recorded_by")] | any | not'
fi
s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ]; then
  check_body "pins omit assigned_to/completed_by without labour:read" \
    '[.data[] | has("assigned_to") or has("completed_by")] | any | not'
fi

if [ -n "${VT_KEY_SENSITIVE-}" ]; then
  s=$(call GET "/v1/pruning?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_SENSITIVE")
  if [ "$s" = 200 ]; then
    check_body "pruning includes crew + rate fields with labour:read + costs:read" \
      '(.data | length == 0) or ([.data[] | has("crew") and has("hourly_rate") and has("labour_cost")] | all)'
  else check "sensitive key can list pruning" 200 "$s"; fi
  s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_SENSITIVE")
  if [ "$s" = 200 ]; then
    check_body "pins include identity fields with labour:read" \
      '(.data | length == 0) or ([.data[] | has("assigned_to") and has("completed_by")] | all)'
  else check "sensitive key can list pins" 200 "$s"; fi
else skip "sensitive key 3C (2 tests)"; fi

echo
echo "== Stage 3C: single resources & cross-vineyard non-disclosure =="
for res in work-tasks pruning irrigation-records growth-stages yield-records pins; do
  s=$(call GET "/v1/$res/00000000-0000-0000-0000-000000000000" "Bearer $VT_KEY_FULL")
  check "random /v1/$res uuid -> 404" 404 "$s" resource_not_found
done

if [ -n "${VT_WORK_TASK_GRANTED-}" ]; then
  s=$(call GET "/v1/work-tasks/$VT_WORK_TASK_GRANTED" "Bearer $VT_KEY_FULL"); check "granted work task retrievable" 200 "$s"
  check_body "work task detail has labour_lines + machine_lines + trip_ids" \
    '.data | (.labour_lines | type == "array") and (.machine_lines | type == "array") and (.trip_ids | type == "array")'
  check_body "work task labour lines omit rates without costs:read" \
    '[.data.labour_lines[] | has("hourly_rate") or has("total_cost")] | any | not'
  check_body "work task blocks carry id + name" \
    '(.data.blocks | length == 0) or ([.data.blocks[] | has("id") and has("name")] | all)'
else skip "granted work task (4 tests)"; fi
if [ -n "${VT_WORK_TASK_OTHER-}" ]; then
  s=$(call GET "/v1/work-tasks/$VT_WORK_TASK_OTHER" "Bearer $VT_KEY_FULL"); check "other account's work task -> 404" 404 "$s" resource_not_found
else skip "other-account work task"; fi

if [ -n "${VT_PRUNING_GRANTED-}" ]; then
  s=$(call GET "/v1/pruning/$VT_PRUNING_GRANTED" "Bearer $VT_KEY_FULL"); check "granted pruning activity retrievable" 200 "$s"
  check_body "pruning uses explicit vine/labour metrics" \
    '.data | has("vines_pruned") and has("labour_hours") and has("vines_per_labour_hour") and has("row_equivalents")'
  check_body "pruning detail omits crew without labour:read" '.data | has("crew") | not'
else skip "granted pruning activity (3 tests)"; fi
if [ -n "${VT_PRUNING_OTHER-}" ]; then
  s=$(call GET "/v1/pruning/$VT_PRUNING_OTHER" "Bearer $VT_KEY_FULL"); check "other account's pruning activity -> 404" 404 "$s" resource_not_found
else skip "other-account pruning activity"; fi

if [ -n "${VT_IRRIGATION_GRANTED-}" ]; then
  s=$(call GET "/v1/irrigation-records/$VT_IRRIGATION_GRANTED" "Bearer $VT_KEY_FULL"); check "granted irrigation record retrievable" 200 "$s"
  check_body "irrigation uses explicit units (volume_l, duration_minutes)" \
    '.data | has("volume_l") and has("duration_minutes") and has("status")'
  check_body "irrigation detail blocks carry depth_mm" \
    '(.data.blocks | length == 0) or ([.data.blocks[] | has("depth_mm")] | all)'
else skip "granted irrigation record (3 tests)"; fi
if [ -n "${VT_IRRIGATION_OTHER-}" ]; then
  s=$(call GET "/v1/irrigation-records/$VT_IRRIGATION_OTHER" "Bearer $VT_KEY_FULL"); check "other account's irrigation record -> 404" 404 "$s" resource_not_found
else skip "other-account irrigation record"; fi

if [ -n "${VT_GROWTH_STAGE_GRANTED-}" ]; then
  s=$(call GET "/v1/growth-stages/$VT_GROWTH_STAGE_GRANTED" "Bearer $VT_KEY_FULL"); check "granted growth stage retrievable" 200 "$s"
  check_body "growth stage has stage_code + observed_at" '.data | has("stage_code") and has("observed_at")'
  check_body "growth stage omits recorded_by without labour:read" '.data | has("recorded_by") | not'
else skip "granted growth stage (3 tests)"; fi
if [ -n "${VT_GROWTH_STAGE_OTHER-}" ]; then
  s=$(call GET "/v1/growth-stages/$VT_GROWTH_STAGE_OTHER" "Bearer $VT_KEY_FULL"); check "other account's growth stage -> 404" 404 "$s" resource_not_found
else skip "other-account growth stage"; fi

if [ -n "${VT_YIELD_GRANTED-}" ]; then
  s=$(call GET "/v1/yield-records/$VT_YIELD_GRANTED" "Bearer $VT_KEY_FULL"); check "granted yield record retrievable" 200 "$s"
  check_body "yield uses tonnes/ha units + vintage" \
    '.data | has("total_yield_tonnes") and has("total_area_ha") and has("vintage_year")'
  check_body "yield blocks use explicit unit names" \
    '(.data.blocks | length == 0) or ([.data.blocks[] | has("area_ha") and has("average_bunch_weight_g")] | all)'
else skip "granted yield record (3 tests)"; fi
if [ -n "${VT_YIELD_OTHER-}" ]; then
  s=$(call GET "/v1/yield-records/$VT_YIELD_OTHER" "Bearer $VT_KEY_FULL"); check "other account's yield record -> 404" 404 "$s" resource_not_found
else skip "other-account yield record"; fi

if [ -n "${VT_PIN_GRANTED-}" ]; then
  s=$(call GET "/v1/pins/$VT_PIN_GRANTED" "Bearer $VT_KEY_FULL"); check "granted pin retrievable" 200 "$s"
  check_body "pin preserves snapped path/row identity" \
    '.data.row | has("path_number") and has("row_number") and has("side") and has("snapped_to_row")'
  check_body "pin has coordinates + placement + status" \
    '.data | has("latitude") and has("longitude") and has("status") and (.location | has("scope") and has("assignment_basis"))'
  check_body "pin detail includes row_segments" '.data.row_segments | type == "array"'
  check_body "pin never exposes private photo paths" \
    '.data | tostring | contains("photo_path") | not'
else skip "granted pin (5 tests)"; fi
if [ -n "${VT_PIN_OTHER-}" ]; then
  s=$(call GET "/v1/pins/$VT_PIN_OTHER" "Bearer $VT_KEY_FULL"); check "other account's pin -> 404" 404 "$s" resource_not_found
else skip "other-account pin"; fi

echo
echo "== Stage 3C: pagination =="
s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED&limit=1" "Bearer $VT_KEY_FULL")
check "pins limit=1 accepted" 200 "$s"
NEXT3C=$(jq -r '.pagination.next_cursor // empty' "$BODY_FILE")
FIRST3C=$(jq -r '.data[0].id // empty' "$BODY_FILE")
if [ -n "$NEXT3C" ]; then
  s=$(call GET "/v1/pins?vineyard_id=$VT_VINEYARD_GRANTED&limit=1&cursor=$NEXT3C" "Bearer $VT_KEY_FULL")
  check "pins cursor page 2 -> 200" 200 "$s"
  SECOND3C=$(jq -r '.data[0].id // empty' "$BODY_FILE")
  if [ -n "$SECOND3C" ] && [ "$SECOND3C" != "$FIRST3C" ]; then
    PASS=$((PASS+1)); echo "PASS  pins cursor advances without duplicates"
  else
    FAIL=$((FAIL+1)); echo "FAIL  pins cursor advances without duplicates (first=$FIRST3C second=$SECOND3C)"
  fi
else
  skip "pins cursor iteration (needs >=2 pins in granted vineyard)"
fi
s=$(call GET "/v1/work-tasks?vineyard_id=$VT_VINEYARD_GRANTED&cursor=%%%bogus" "Bearer $VT_KEY_FULL"); check "work-tasks invalid cursor -> 400 invalid_cursor" 400 "$s" invalid_cursor

echo
echo "== Stage 3B: pagination =="
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&limit=1" "Bearer $VT_KEY_FULL")
check "trips limit=1 accepted" 200 "$s"
NEXT=$(jq -r '.pagination.next_cursor // empty' "$BODY_FILE")
FIRST_ID=$(jq -r '.data[0].id // empty' "$BODY_FILE")
if [ -n "$NEXT" ]; then
  s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&limit=1&cursor=$NEXT" "Bearer $VT_KEY_FULL")
  check "trips cursor page 2 -> 200" 200 "$s"
  SECOND_ID=$(jq -r '.data[0].id // empty' "$BODY_FILE")
  if [ -n "$SECOND_ID" ] && [ "$SECOND_ID" != "$FIRST_ID" ]; then
    PASS=$((PASS+1)); echo "PASS  cursor advances without duplicates"
  else
    FAIL=$((FAIL+1)); echo "FAIL  cursor advances without duplicates (first=$FIRST_ID second=$SECOND_ID)"
  fi
else
  skip "trips cursor iteration (needs >=2 trips in granted vineyard)"
fi
s=$(call GET "/v1/trips?vineyard_id=$VT_VINEYARD_GRANTED&cursor=%%%bogus" "Bearer $VT_KEY_FULL"); check "trips invalid cursor -> 400 invalid_cursor" 400 "$s" invalid_cursor

echo
echo "== Stage 3D: weather =="
s=$(call GET "/v1/weather?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
check "weather:read allows /v1/weather" 200 "$s"
check_body "weather envelope has data + meta.generated_at" \
  '.data.vineyard_id != null and .meta.generated_at != null'
check_body "weather current_status is a known value" \
  '.data.current_status | IN("ok","no_data","not_configured")'
check_body "weather forecast_status is a known value" \
  '.data.forecast_status | IN("ok","stale","unavailable","not_configured")'
check_body "weather current uses metric VineTrack field names when present" \
  '.data.current == null or (.data.current | has("temperature_c") and has("humidity_percent") and has("wind_speed_kmh") and has("is_stale") and has("observed_at"))'
check_body "weather forecast days use VineTrack field names when present" \
  '(.data.forecast | length) == 0 or (.data.forecast[0] | has("date") and has("rain_mm") and has("temp_min_c") and has("temp_max_c"))'
check_body "weather never leaks provider credentials or raw payloads" \
  '. | tostring | (contains("api_key") or contains("api_secret") or contains("willyweather.com.au") or contains("raw_payload")) | not'
s=$(call GET "/v1/weather" "Bearer $VT_KEY_FULL"); check "weather without vineyard_id -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/weather?vineyard_id=$VT_VINEYARD_GRANTED&lat=-33.2" "Bearer $VT_KEY_FULL"); check "weather rejects lat/lon params -> 400" 400 "$s" invalid_request
s=$(call POST "/v1/weather?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL"); check "POST /v1/weather -> 405" 405 "$s" method_not_allowed
if [ -n "${VT_KEY_BLOCKS_ONLY-}" ]; then
  s=$(call GET "/v1/weather?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks-only key -> weather 403 insufficient_scope" 403 "$s" insufficient_scope
else skip "blocks-only weather scope"; fi
if [ -n "${VT_VINEYARD_OTHER-}" ]; then
  s=$(call GET "/v1/weather?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "ungranted vineyard -> weather 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
else skip "ungranted-vineyard weather"; fi

echo
echo "== Stage 3D: rainfall =="
s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
check "rainfall:read allows /v1/rainfall" 200 "$s"
check_body "rainfall collection envelope" '.data | type == "array"'
check_body "rainfall pagination envelope" '.pagination | has("next_cursor")'
check_body "rainfall sources come from the canonical family" \
  '[.data[].source] | all(IN("manual","davis_weatherlink","wunderground_pws","open_meteo"))'
check_body "rainfall_mm is numeric mm" '[.data[].rainfall_mm] | all(type == "number")'
check_body "rainfall dates are ISO and descending" \
  '(.data | length) < 2 or ([.data[].date] as $d | $d == ($d | sort | reverse))'
s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED&from=2026-01-01&to=2026-01-31" "Bearer $VT_KEY_FULL"); check "rainfall from/to filter -> 200" 200 "$s"
check_body "rainfall from/to range respected" \
  '[.data[].date] | all(. >= "2026-01-01" and . <= "2026-01-31")'
s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED&from=2026-02-31" "Bearer $VT_KEY_FULL"); check "rainfall non-real date -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED&from=2026-05-01&to=2026-01-01" "Bearer $VT_KEY_FULL"); check "rainfall from > to -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED&interval=monthly" "Bearer $VT_KEY_FULL"); check "rainfall unknown param -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED&cursor=%%%bogus" "Bearer $VT_KEY_FULL"); check "rainfall invalid cursor -> 400" 400 "$s" invalid_cursor
s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED&limit=1" "Bearer $VT_KEY_FULL")
check "rainfall limit=1 accepted" 200 "$s"
NEXT3D=$(jq -r '.pagination.next_cursor // empty' "$BODY_FILE")
FIRST3D=$(jq -r '.data[0].date // empty' "$BODY_FILE")
if [ -n "$NEXT3D" ]; then
  s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED&limit=1&cursor=$NEXT3D" "Bearer $VT_KEY_FULL")
  check "rainfall cursor page 2 -> 200" 200 "$s"
  SECOND3D=$(jq -r '.data[0].date // empty' "$BODY_FILE")
  if [ -n "$SECOND3D" ] && [ "$SECOND3D" != "$FIRST3D" ]; then
    PASS=$((PASS+1)); echo "PASS  rainfall date cursor advances without duplicates"
  else
    FAIL=$((FAIL+1)); echo "FAIL  rainfall date cursor advances without duplicates (first=$FIRST3D second=$SECOND3D)"
  fi
else
  skip "rainfall cursor iteration (needs >=2 rainfall days in granted vineyard)"
fi
if [ -n "${VT_KEY_BLOCKS_ONLY-}" ]; then
  s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks-only key -> rainfall 403 insufficient_scope" 403 "$s" insufficient_scope
else skip "blocks-only rainfall scope"; fi
if [ -n "${VT_VINEYARD_OTHER-}" ]; then
  s=$(call GET "/v1/rainfall?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "ungranted vineyard -> rainfall 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
else skip "ungranted-vineyard rainfall"; fi

echo
echo "== Stage 3D: disease risk =="
s=$(call GET "/v1/disease-risk?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL")
if [ "$s" = 200 ]; then
  PASS=$((PASS+1)); echo "PASS  disease_risk:read allows /v1/disease-risk"
  check_body "disease risk returns exactly the three implemented models" \
    '[.data.risks[].disease] | sort == ["botrytis","downy_mildew","powdery_mildew"]'
  check_body "risk levels are low/medium/high" \
    '[.data.risks[].risk_level] | all(IN("low","medium","high"))'
  check_body "no manufactured numeric score exposed" \
    '[.data.risks[] | has("score")] | all(. == false)'
  check_body "model_version + wetness provenance present" \
    '.data.model_version != null and .data.wetness_source == "estimated_proxy"'
  check_body "weather-source provenance present" \
    '.data.weather_source | has("provider") and has("observed_through") and has("source_status")'
  check_body "calculated_at + freshness meta present" \
    '.data.calculated_at != null and (.meta | has("is_stale"))'
  check_body "disease risk never leaks provider secrets" \
    '. | tostring | (contains("api_key") or contains("api_secret")) | not'
elif [ "$s" = 503 ]; then
  code=$(jq -r '.error.code // empty' "$BODY_FILE")
  if [ "$code" = "disease_risk_unavailable" ]; then
    PASS=$((PASS+1)); echo "PASS  disease-risk unavailable path returns stable 503 disease_risk_unavailable"
    SKIP=$((SKIP+7)); echo "SKIP  disease-risk body checks (no coordinates/upstream in this environment)"
  else
    FAIL=$((FAIL+1)); echo "FAIL  disease-risk 503 without disease_risk_unavailable (code=$code)"
  fi
else
  FAIL=$((FAIL+1)); echo "FAIL  /v1/disease-risk unexpected status $s (body=$(head -c 300 "$BODY_FILE"))"
fi
s=$(call GET "/v1/disease-risk" "Bearer $VT_KEY_FULL"); check "disease-risk without vineyard_id -> 400" 400 "$s" invalid_request
s=$(call GET "/v1/disease-risk?vineyard_id=$VT_VINEYARD_GRANTED&disease=downy" "Bearer $VT_KEY_FULL"); check "disease-risk unknown param -> 400" 400 "$s" invalid_request
s=$(call POST "/v1/disease-risk?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL"); check "POST /v1/disease-risk -> 405" 405 "$s" method_not_allowed
if [ -n "${VT_KEY_BLOCKS_ONLY-}" ]; then
  s=$(call GET "/v1/disease-risk?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks-only key -> disease-risk 403 insufficient_scope" 403 "$s" insufficient_scope
else skip "blocks-only disease-risk scope"; fi
if [ -n "${VT_VINEYARD_OTHER-}" ]; then
  s=$(call GET "/v1/disease-risk?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "ungranted vineyard -> disease-risk 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
else skip "ungranted-vineyard disease-risk"; fi
s=$(call GET "/v1/weather/some-id" "Bearer $VT_KEY_FULL"); check "environmental singletons have no {id} form -> 404" 404 "$s" resource_not_found

echo
echo "== Stage 8: write API method gating =="
s=$(call DELETE "/v1/work-tasks/00000000-0000-4000-8000-000000000001" "Bearer $VT_KEY_FULL"); check "DELETE anywhere -> 405 (no public DELETE API)" 405 "$s" method_not_allowed
s=$(call PUT "/v1/work-tasks/00000000-0000-4000-8000-000000000001" "Bearer $VT_KEY_FULL"); check "PUT -> 405" 405 "$s" method_not_allowed
s=$(call_write POST "/v1/trips" "Bearer $VT_KEY_FULL" "k" '{}'); check "POST on a read-only resource -> 405" 405 "$s" method_not_allowed
s=$(call_write PATCH "/v1/irrigation-records/00000000-0000-4000-8000-000000000001" "Bearer $VT_KEY_FULL" "" '{}'); check "PATCH on a create-only resource -> 405" 405 "$s" method_not_allowed
s=$(call_write POST "/v1/not-a-resource" "Bearer $VT_KEY_FULL" "k" '{}'); check "POST unknown path -> 404" 404 "$s" resource_not_found
s=$(call_write POST "/v1/work-tasks" "" "k" '{}'); check "unauthenticated POST -> 401" 401 "$s" missing_api_key
s=$(call_write POST "/v1/work-tasks" "Bearer $VT_KEY_FULL" "scope-test-1" "{\"vineyard_id\":\"$VT_VINEYARD_GRANTED\",\"task_type\":\"X\",\"date\":\"2026-01-15T09:00:00Z\"}")
check "read-scope key cannot write -> 403 insufficient_scope" 403 "$s" insufficient_scope

echo
echo "== Stage 8: write API contract =="
if [ -n "${VT_KEY_WRITE-}" ]; then
  WAUTH="Bearer $VT_KEY_WRITE"
  IDEM="s8-test-$(date +%s)-$RANDOM"
  WT_BODY="{\"vineyard_id\":\"$VT_VINEYARD_GRANTED\",\"task_type\":\"Stage 8 API test\",\"date\":\"2026-01-15T09:00:00Z\",\"notes\":\"Created by test-vinetrack-api.sh — safe to archive\",\"external_id\":\"$IDEM\"}"

  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "" "$WT_BODY"); check "POST without Idempotency-Key -> 400 idempotency_required" 400 "$s" idempotency_required
  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM-mal" '{not json'); check "malformed JSON -> 400 invalid_request" 400 "$s" invalid_request
  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM-empty" ''); check "missing body -> 400 invalid_request" 400 "$s" invalid_request
  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM-nov" '{"task_type":"X","date":"2026-01-15T09:00:00Z"}')
  check "missing vineyard_id -> 422 validation_failed" 422 "$s" validation_failed
  check_body "validation details carry field + issue" '.error.details | type == "array" and length > 0 and all(has("field") and has("issue"))'
  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM-unk" "{\"vineyard_id\":\"$VT_VINEYARD_GRANTED\",\"task_type\":\"X\",\"date\":\"2026-01-15T09:00:00Z\",\"labour_cost\":500}")
  check "unknown field -> 422 validation_failed" 422 "$s" validation_failed
  check_body "no SQL/internal text in validation errors" '. | tostring | test("(?i)(syntax error|pg_|constraint|stack)") | not'

  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM" "$WT_BODY")
  check "valid POST /v1/work-tasks -> 201" 201 "$s"
  check_body "created representation carries id + origin + external_id" '.data.id != null and .data.origin == "integration" and .data.external_id != null'
  WREQ=$(grep -i '^x-vinetrack-request-id:' "$HDR_FILE" | tr -d '\r' | awk '{print $2}')
  if [ -n "$WREQ" ]; then PASS=$((PASS+1)); echo "PASS  write responses carry X-VineTrack-Request-ID"; else FAIL=$((FAIL+1)); echo "FAIL  write X-VineTrack-Request-ID missing"; fi
  WT_ID=$(jq -r '.data.id' "$BODY_FILE"); WT_UPDATED=$(jq -r '.data.updated_at' "$BODY_FILE")

  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM" "$WT_BODY")
  check "idempotent replay -> 201 with the ORIGINAL record" 201 "$s"
  check_body "replay returns the same id" ".data.id == \"$WT_ID\""
  if grep -qi '^idempotency-replayed: true' "$HDR_FILE"; then PASS=$((PASS+1)); echo "PASS  Idempotency-Replayed header on replay"; else FAIL=$((FAIL+1)); echo "FAIL  Idempotency-Replayed header missing"; fi
  s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM" "{\"vineyard_id\":\"$VT_VINEYARD_GRANTED\",\"task_type\":\"Different payload\",\"date\":\"2026-01-16T09:00:00Z\"}")
  check "same key + different payload -> 409 idempotency_conflict" 409 "$s" idempotency_conflict

  s=$(call GET "/v1/work-tasks/$WT_ID" "$WAUTH")
  if [ "$s" = 200 ]; then
    PASS=$((PASS+1)); echo "PASS  GET sees the POSTed record"
  else SKIP=$((SKIP+1)); echo "SKIP  GET-after-POST (write key lacks work_tasks:read)"; fi

  s=$(call_write PATCH "/v1/work-tasks/$WT_ID" "$WAUTH" "" '{"status":"in_progress"}')
  check "PATCH without expected_updated_at -> 422" 422 "$s" validation_failed
  s=$(call_write PATCH "/v1/work-tasks/$WT_ID" "$WAUTH" "" '{"expected_updated_at":"2000-01-01T00:00:00Z","status":"in_progress"}')
  check "stale expected_updated_at -> 409 conflict" 409 "$s" conflict
  s=$(call_write PATCH "/v1/work-tasks/$WT_ID" "$WAUTH" "" "{\"expected_updated_at\":\"$WT_UPDATED\",\"status\":\"in_progress\"}")
  check "valid PATCH -> 200" 200 "$s"
  check_body "PATCH response reflects the update" '.data.status == "in_progress"'
  s=$(call_write PATCH "/v1/work-tasks/00000000-0000-4000-8000-0000000000aa" "$WAUTH" "" '{"expected_updated_at":"2026-01-01T00:00:00Z"}')
  check "PATCH unknown id -> 404" 404 "$s" resource_not_found

  if [ -n "${VT_VINEYARD_OTHER-}" ]; then
    s=$(call_write POST "/v1/work-tasks" "$WAUTH" "$IDEM-other" "{\"vineyard_id\":\"$VT_VINEYARD_OTHER\",\"task_type\":\"X\",\"date\":\"2026-01-15T09:00:00Z\"}")
    check "POST to ungranted vineyard -> 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
  else skip "ungranted-vineyard write"; fi
  echo "NOTE  Stage 8 test work task created: $WT_ID (task_type='Stage 8 API test') — archive/delete it in-app."
else
  skip "Stage 8 write-contract tests (set VT_KEY_WRITE)"
fi

echo
echo "== Done: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" = 0 ]
