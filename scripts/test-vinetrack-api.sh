#!/usr/bin/env bash
# =============================================================================
# test-vinetrack-api.sh — Stage 3A gateway security tests (HTTP level)
# =============================================================================
# Runs the section-26 checks against a DEPLOYED vinetrack-api gateway.
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
#   VT_KEY_FULL           active key; integration has vineyards:read + blocks:read
#                         and a grant to VT_VINEYARD_GRANTED
#   VT_VINEYARD_GRANTED   vineyard UUID granted to the integration
#   VT_BLOCK_GRANTED      block UUID inside VT_VINEYARD_GRANTED
#
# Optional (tests are skipped when unset):
#   VT_KEY_NO_SCOPES      active key on an integration with NO scopes granted
#   VT_KEY_BLOCKS_ONLY    active key with ONLY blocks:read granted
#   VT_KEY_REVOKED        a revoked API key
#   VT_KEY_EXPIRED        an expired API key
#   VT_KEY_PAUSED         key on a paused integration
#   VT_KEY_CLIENT_REVOKED key on a revoked integration
#   VT_VINEYARD_OTHER     vineyard UUID belonging to ANOTHER account (never granted)
#   VT_BLOCK_OTHER        block UUID inside VT_VINEYARD_OTHER
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
else skip "no-scope key (3 tests)"; fi

if [ -n "${VT_KEY_BLOCKS_ONLY-}" ]; then
  s=$(call GET /v1/vineyards "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks:read does NOT imply vineyards:read" 403 "$s" insufficient_scope
  s=$(call GET "/v1/blocks?vineyard_id=$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_BLOCKS_ONLY"); check "blocks-only key can read blocks" 200 "$s"
else skip "blocks-only key (2 tests)"; fi

echo
echo "== Vineyard isolation =="
s=$(call GET "/v1/vineyards/$VT_VINEYARD_GRANTED" "Bearer $VT_KEY_FULL"); check "granted vineyard retrievable" 200 "$s"
s=$(call GET "/v1/blocks/$VT_BLOCK_GRANTED" "Bearer $VT_KEY_FULL"); check "granted block retrievable" 200 "$s"

if [ -n "${VT_VINEYARD_OTHER-}" ]; then
  s=$(call GET "/v1/vineyards/$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "other account's vineyard -> 404 (no existence leak)" 404 "$s" resource_not_found
  s=$(call GET "/v1/blocks?vineyard_id=$VT_VINEYARD_OTHER" "Bearer $VT_KEY_FULL"); check "blocks in ungranted vineyard -> 403 vineyard_access_denied" 403 "$s" vineyard_access_denied
else skip "other-account vineyard (2 tests)"; fi
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
s=$(call GET /v1/nonexistent "Bearer $VT_KEY_FULL"); check "unknown route -> 404 JSON error" 404 "$s" resource_not_found
s=$(call GET "/v1/vineyards?cursor=%%%bogus" "Bearer $VT_KEY_FULL"); check "invalid cursor -> 400 invalid_cursor" 400 "$s" invalid_cursor
s=$(call GET "/v1/vineyards?limit=5000" "Bearer $VT_KEY_FULL"); check "limit > 1000 -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/vineyards?bogus_param=1" "Bearer $VT_KEY_FULL"); check "unknown query param -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/blocks" "Bearer $VT_KEY_FULL"); check "blocks without vineyard_id -> 400 invalid_request" 400 "$s" invalid_request
s=$(call GET "/v1/me?api_key=$VT_KEY_FULL"); check "query-string credential -> 400 invalid_request" 400 "$s" invalid_request

echo
echo "== Done: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" = 0 ]
