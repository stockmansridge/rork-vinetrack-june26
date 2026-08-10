#!/usr/bin/env bash
# =============================================================================
# deploy-edge-functions.sh
# =============================================================================
# Deploys Supabase Edge Functions to the VineTrack iOS Supabase project.
# (Optional convenience for Mac/Linux developers. Windows users: use
#  scripts/deploy-edge-functions.ps1 instead.)
#
# Prerequisites:
#   - Supabase CLI installed
#       brew install supabase/tap/supabase            # macOS
#       npm install -g supabase                       # cross-platform
#       https://supabase.com/docs/guides/cli/getting-started
#   - supabase login
#   - Run from the repo root:
#       ./scripts/deploy-edge-functions.sh
#   - You must have access to the Supabase project tbafuqwruefgkbyxrxyb.
#
# Security:
#   - No service-role keys, anon keys, or secrets are stored in this script.
#   - Auth comes from `supabase login`. Do NOT hardcode credentials here.
# =============================================================================

set -euo pipefail

PROJECT_REF="${PROJECT_REF:-tbafuqwruefgkbyxrxyb}"
if [ -n "${FUNCTIONS:-}" ]; then
  # Space-separated override, e.g. FUNCTIONS="send-invitation-email support-request"
  read -r -a FUNCTIONS <<<"$FUNCTIONS"
else
  FUNCTIONS=(
    davis-proxy willyweather-proxy open-meteo-proxy wunderground-proxy
    weather-current weather-nearby-stations chemical-info-lookup
    tractor-fuel-lookup
    # Unified email system (shared module in supabase/functions/_shared/email/)
    send-invitation-email support-request
    test-resend-email test-invitation-email test-support-staff-email
    test-support-receipt-email test-notification-email
    # Phase 2B — RevenueCat store-purchase synchronisation.
    # BEFORE first deploy, set the webhook secret (never commit it):
    #   supabase secrets set REVENUECAT_WEBHOOK_SECRET="<random long secret>" --project-ref tbafuqwruefgkbyxrxyb
    # Then configure the same value as the Authorization header in the
    # RevenueCat dashboard webhook settings.
    revenuecat-webhook
    # Stage 3A — public read-only VineTrack API gateway (SQL 172/173).
    # Deployed with --no-verify-jwt: callers present VineTrack API keys
    # (Authorization: Bearer vt_live_...), not Supabase JWTs.
    vinetrack-api
  )
fi

section() { printf "\n=== %s ===\n" "$1"; }

section "Pre-flight checks"
if ! command -v supabase >/dev/null 2>&1; then
  echo "Supabase CLI not found. Install via:"
  echo "  brew install supabase/tap/supabase"
  echo "  npm install -g supabase"
  exit 1
fi
supabase --version

if [ ! -d "supabase/functions" ]; then
  echo "supabase/functions not found. Run from repo root." >&2
  exit 1
fi

for fn in "${FUNCTIONS[@]}"; do
  section "Deploying $fn -> $PROJECT_REF"
  if [ ! -d "supabase/functions/$fn" ]; then
    echo "Function source not found at supabase/functions/$fn" >&2
    exit 1
  fi
  if [ "$fn" = "revenuecat-webhook" ] || [ "$fn" = "vinetrack-api" ]; then
    # CRITICAL: these functions authenticate callers themselves and do NOT
    # receive Supabase JWTs:
    #   - revenuecat-webhook: shared-secret Authorization header
    #     (constant-time compare, fails closed when secret unset).
    #   - vinetrack-api: VineTrack API keys (Bearer vt_live_...) validated
    #     against the SQL 172 integration foundation.
    # With gateway JWT verification on, every request would be rejected
    # with 401 before the function's own auth check runs.
    supabase functions deploy "$fn" --project-ref "$PROJECT_REF" --no-verify-jwt
  else
    supabase functions deploy "$fn" --project-ref "$PROJECT_REF"
  fi
  echo "Deployed: $fn"
done

section "Functions on $PROJECT_REF"
supabase functions list --project-ref "$PROJECT_REF" || true

section "Verification"
cat <<EOF
Run:
  curl -i https://${PROJECT_REF}.supabase.co/functions/v1/willyweather-proxy

Expected:
  401 / 405 / other auth or method error = function IS deployed (good)
  404 NOT_FOUND                          = still NOT deployed (bad)

Then test from the Lovable portal:
  Setup -> Weather -> Test saved credentials
EOF

echo
echo "Done."
