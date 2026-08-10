#!/usr/bin/env bash
# =============================================================================
# test-vinetrack-api.sh — Stage 3A + 3B gateway security tests (HTTP level)
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
#                         trips:read, sprays:read, fuel:read, equipment:read
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
#   VT_FUEL_RECORD_GRANTED    tractor_fuel_logs UUID inside VT_VINEYARD_GRANTED
#   VT_FUEL_RECORD_OTHER      tractor_fuel_logs UUID inside VT_VINEYARD_OTHER
#   VT_FUEL_PURCHASE_GRANTED  fuel_purchases UUID inside VT_VINEYARD_GRANTED
#   VT_FUEL_PURCHASE_OTHER    fuel_purchases UUID inside VT_VINEYARD_OTHER
#   VT_EQUIPMENT_GRANTED  vineyard_machines/spray_equipment/equipment_items UUID
#                         inside VT_VINEYARD_GRANTED
#   VT_EQUIPMENT_OTHER    equipment UUID inside VT_VINEYARD_OTHER
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
  s=$(call GET "/v1/spray-jobs/$VT_SPRAY_GRANTED" "Bearer $VT_KEY_FULL"); check "granted spray record retrievable" 200 "$s"
  check_body "spray detail has tanks array" '.data.tanks | type == "array"'
  check_body "spray detail has blocks array" '.data.blocks | type == "array"'
  check_body "spray products omit cost_per_unit without costs:read" \
    '[.data.tanks[].products[]? | has("cost_per_unit")] | any | not'
  check_body "spray conditions use explicit units" \
    '.data.conditions | has("temperature_c") and has("wind_speed_kmh") and has("humidity_percent")'
else skip "granted spray record (5 tests)"; fi
if [ -n "${VT_SPRAY_OTHER-}" ]; then
  s=$(call GET "/v1/spray-jobs/$VT_SPRAY_OTHER" "Bearer $VT_KEY_FULL"); check "other account's spray record -> 404" 404 "$s" resource_not_found
else skip "other-account spray record"; fi

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
echo "== Done: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" = 0 ]
