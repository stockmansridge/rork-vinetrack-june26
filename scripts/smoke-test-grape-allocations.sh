#!/usr/bin/env bash
# =============================================================================
# smoke-test-grape-allocations.sh — grape allocation API smoke tests (HTTP)
# =============================================================================
# Runs the pre-Portal verification against a DEPLOYED vinetrack-api gateway
# with sql/217 + sql/218 applied. Complements
# sql/tests/217_grape_allocations_tests.sql (DB level).
#
# Covers:
#   - GET /v1/grape-allocations (list + envelope)
#   - POST own_use
#   - POST external WITH price (financial key)
#   - PATCH (expected_updated_at concurrency)
#   - non-financial key: price OMITTED on read, price write REJECTED
#   - costs:read alone does NOT authorise a price write (needs costs:write)
#   - cross-vineyard access rejected
#
# No secrets live in this file. Create fixtures with the SQL 172 management
# RPCs (see docs/vinetrack-api-v1.md "Creating test credentials"):
#
# Required:
#   GATEWAY_URL          e.g. https://<ref>.supabase.co/functions/v1/vinetrack-api
#   VT_GA_KEY_FIN        key whose integration has grape_allocations:read,
#                        grape_allocations:write, costs:read AND costs:write,
#                        granted to VT_VINEYARD_GRANTED
#   VT_GA_KEY_BASE       key with ONLY grape_allocations:read +
#                        grape_allocations:write (no costs scopes)
#   VT_VINEYARD_GRANTED  vineyard UUID granted to both integrations
#
# Optional (tests skipped when unset):
#   VT_GA_KEY_COSTSREAD  key with grape_allocations write + costs:read but
#                        WITHOUT costs:write (proves read disclosure never
#                        authorises a financial write)
#   VT_VINEYARD_OTHER    vineyard UUID belonging to ANOTHER account
#   VT_BLOCK_GRANTED     block UUID inside VT_VINEYARD_GRANTED (block split)
#
# NOTE: the write tests create clearly-labelled "GA smoke test" allocations
# inside VT_VINEYARD_GRANTED — use a test vineyard, then delete them in the
# app (Yields → Grape Allocation) afterwards.
#
# Usage:
#   GATEWAY_URL=... VT_GA_KEY_FIN=vt_test_... VT_GA_KEY_BASE=vt_test_... \
#   VT_VINEYARD_GRANTED=... ./scripts/smoke-test-grape-allocations.sh
# =============================================================================

set -uo pipefail

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
: "${GATEWAY_URL:?set GATEWAY_URL}"
: "${VT_GA_KEY_FIN:?set VT_GA_KEY_FIN}"
: "${VT_GA_KEY_BASE:?set VT_GA_KEY_BASE}"
: "${VT_VINEYARD_GRANTED:?set VT_VINEYARD_GRANTED}"

PASS=0; FAIL=0; SKIP=0
BODY_FILE=$(mktemp); HDR_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$HDR_FILE"' EXIT

# call <method> <path> <auth> [idempotency-key] [json-body]
call() {
  local method="$1" path="$2" auth="$3" idem="${4-}" body="${5-}"
  local args=(-s -X "$method" -o "$BODY_FILE" -D "$HDR_FILE" -w "%{http_code}")
  [ -n "$auth" ] && args+=(-H "Authorization: Bearer $auth")
  [ -n "$idem" ] && args+=(-H "Idempotency-Key: $idem")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
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

check_body() { # check_body <name> <jq-expression>
  local name="$1" expr="$2"
  if jq -e "$expr" "$BODY_FILE" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "PASS  $name"
  else FAIL=$((FAIL+1)); echo "FAIL  $name (body=$(head -c 300 "$BODY_FILE"))"; fi
}

skip() { SKIP=$((SKIP+1)); echo "SKIP  $1 (fixture not provided)"; }

RUN="ga-smoke-$(date +%s)-$RANDOM"

echo "== 1. GET allocations =="
s=$(call GET "/v1/grape-allocations?vineyard_id=$VT_VINEYARD_GRANTED" "$VT_GA_KEY_FIN")
check "GET list -> 200" 200 "$s"
check_body "collection envelope { data, pagination.next_cursor }" \
  'has("data") and (.data | type == "array") and (.pagination | has("next_cursor"))'
s=$(call GET "/v1/grape-allocations?vineyard_id=$VT_VINEYARD_GRANTED&vintage=2027" "$VT_GA_KEY_FIN")
check "GET list vintage filter -> 200" 200 "$s"
s=$(call GET "/v1/grape-allocations" "$VT_GA_KEY_FIN")
check "GET list without vineyard_id -> 400" 400 "$s" invalid_request

echo
echo "== 2. POST own_use =="
OWN_BODY="{\"vineyard_id\":\"$VT_VINEYARD_GRANTED\",\"vintage\":2027,\"allocation_type\":\"own_use\",\"variety_name\":\"Pinot Noir\",\"destination_name\":\"GA smoke test — safe to delete\",\"quantity_tonnes\":3.5}"
s=$(call POST "/v1/grape-allocations" "$VT_GA_KEY_FIN" "$RUN-own" "$OWN_BODY")
check "POST own_use -> 201" 201 "$s"
check_body "own_use representation correct, no price key" \
  '.data.allocation_type == "own_use" and .data.quantity_tonnes == 3.5 and (.data | has("price_per_tonne") | not)'
OWN_ID=$(jq -r '.data.id // empty' "$BODY_FILE")
s=$(call POST "/v1/grape-allocations" "$VT_GA_KEY_FIN" "$RUN-own" "$OWN_BODY")
check "POST replay (same Idempotency-Key) -> 201" 201 "$s"
check_body "replay returns the SAME id" ".data.id == \"$OWN_ID\""
s=$(call POST "/v1/grape-allocations" "$VT_GA_KEY_FIN" "" "$OWN_BODY")
check "POST without Idempotency-Key -> 400" 400 "$s" idempotency_required

echo
echo "== 3. POST external WITH price (financial key) =="
EXT_BODY="{\"vineyard_id\":\"$VT_VINEYARD_GRANTED\",\"vintage\":2027,\"allocation_type\":\"external\",\"variety_name\":\"Shiraz\",\"purchaser_name\":\"GA smoke test — safe to delete\",\"quantity_tonnes\":4,\"price_per_tonne\":2500"
if [ -n "${VT_BLOCK_GRANTED-}" ]; then
  EXT_BODY="$EXT_BODY,\"blocks\":[{\"block_id\":\"$VT_BLOCK_GRANTED\",\"quantity_tonnes\":4}]}"
else
  EXT_BODY="$EXT_BODY}"
fi
s=$(call POST "/v1/grape-allocations" "$VT_GA_KEY_FIN" "$RUN-ext" "$EXT_BODY")
check "POST external with price -> 201" 201 "$s"
EXT_ID=$(jq -r '.data.id // empty' "$BODY_FILE")
check_body "created representation itself carries NO price (base shape)" \
  '.data | has("price_per_tonne") | not'
s=$(call GET "/v1/grape-allocations/$EXT_ID" "$VT_GA_KEY_FIN")
check "GET single (financial key) -> 200" 200 "$s"
check_body "financial key sees price 2500 + contract_value 10000 (4t x 2500)" \
  '.data.price_per_tonne == 2500 and .data.contract_value == 10000'
EXT_UPDATED=$(jq -r '.data.updated_at // empty' "$BODY_FILE")

echo
echo "== 4. PATCH allocation =="
s=$(call PATCH "/v1/grape-allocations/$EXT_ID" "$VT_GA_KEY_FIN" "" '{"quantity_tonnes":6}')
check "PATCH without expected_updated_at -> 422" 422 "$s" validation_failed
s=$(call PATCH "/v1/grape-allocations/$EXT_ID" "$VT_GA_KEY_FIN" "" \
  "{\"expected_updated_at\":\"$EXT_UPDATED\",\"quantity_tonnes\":6}")
check "PATCH with expected_updated_at -> 200" 200 "$s"
check_body "PATCH updated quantity" '.data.quantity_tonnes == 6'
s=$(call PATCH "/v1/grape-allocations/$EXT_ID" "$VT_GA_KEY_FIN" "" \
  "{\"expected_updated_at\":\"$EXT_UPDATED\",\"quantity_tonnes\":7}")
check "PATCH with STALE expected_updated_at -> 409 conflict" 409 "$s" conflict
s=$(call GET "/v1/grape-allocations/$EXT_ID" "$VT_GA_KEY_FIN")
check "GET after PATCH -> 200" 200 "$s"
check_body "untouched price survived PATCH; contract_value now 15000 (6t x 2500)" \
  '.data.price_per_tonne == 2500 and .data.contract_value == 15000'

echo
echo "== 5. Non-financial key: money invisible and unwritable =="
s=$(call GET "/v1/grape-allocations/$EXT_ID" "$VT_GA_KEY_BASE")
check "GET single (base key) -> 200" 200 "$s"
check_body "base key: price_per_tonne + contract_value OMITTED (not nulled)" \
  '.data | (has("price_per_tonne") or has("contract_value")) | not'
s=$(call GET "/v1/grape-allocations?vineyard_id=$VT_VINEYARD_GRANTED" "$VT_GA_KEY_BASE")
check "GET list (base key) -> 200" 200 "$s"
check_body "base key: no money field on ANY row" \
  '[.data[] | has("price_per_tonne") or has("contract_value")] | any | not'
PRICE_BODY="{\"vineyard_id\":\"$VT_VINEYARD_GRANTED\",\"vintage\":2027,\"allocation_type\":\"external\",\"variety_name\":\"Merlot\",\"purchaser_name\":\"GA smoke test — safe to delete\",\"quantity_tonnes\":2,\"price_per_tonne\":3000}"
s=$(call POST "/v1/grape-allocations" "$VT_GA_KEY_BASE" "$RUN-noprice" "$PRICE_BODY")
check "base key POST with price -> 422 validation_failed" 422 "$s" validation_failed
check_body "rejection names the costs:write scope" \
  '[.error.details[]? | select(.field == "price_per_tonne") | .issue] | any(contains("costs:write"))'
s=$(call PATCH "/v1/grape-allocations/$EXT_ID" "$VT_GA_KEY_BASE" "" \
  "{\"expected_updated_at\":\"$(jq -r '.data.updated_at' "$BODY_FILE" 2>/dev/null || echo x)\",\"price_per_tonne\":9999}")
# status may be 409 (stale token) or 422 (scope) — the invariant is it can NEVER be 200:
if [ "$s" != "200" ]; then PASS=$((PASS+1)); echo "PASS  base key PATCH price never succeeds (status=$s)"
else FAIL=$((FAIL+1)); echo "FAIL  base key PATCH price SUCCEEDED"; fi

if [ -n "${VT_GA_KEY_COSTSREAD-}" ]; then
  s=$(call POST "/v1/grape-allocations" "$VT_GA_KEY_COSTSREAD" "$RUN-cr" "$PRICE_BODY")
  check "costs:read WITHOUT costs:write cannot write price -> 422" 422 "$s" validation_failed
  check_body "costs:read-only rejection names costs:write" \
    '[.error.details[]? | select(.field == "price_per_tonne") | .issue] | any(contains("costs:write"))'
else skip "costs:read-without-costs:write key (2 tests)"; fi

echo
echo "== 6. Cross-vineyard access rejected =="
if [ -n "${VT_VINEYARD_OTHER-}" ]; then
  s=$(call GET "/v1/grape-allocations?vineyard_id=$VT_VINEYARD_OTHER" "$VT_GA_KEY_FIN")
  check "GET list in ungranted vineyard -> 403" 403 "$s" vineyard_access_denied
  s=$(call POST "/v1/grape-allocations" "$VT_GA_KEY_FIN" "$RUN-xv" \
    "{\"vineyard_id\":\"$VT_VINEYARD_OTHER\",\"vintage\":2027,\"allocation_type\":\"own_use\",\"variety_name\":\"Merlot\",\"quantity_tonnes\":1}")
  check "POST into ungranted vineyard -> 403" 403 "$s" vineyard_access_denied
else skip "cross-vineyard (2 tests)"; fi
s=$(call GET "/v1/grape-allocations/00000000-0000-0000-0000-000000000000" "$VT_GA_KEY_FIN")
check "random allocation uuid -> 404 (no existence leak)" 404 "$s" resource_not_found

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
echo "Created test allocations (own_use $OWN_ID, external $EXT_ID) are labelled"
echo "'GA smoke test — safe to delete' — remove them in the app when done."
[ "$FAIL" = 0 ] || exit 1
