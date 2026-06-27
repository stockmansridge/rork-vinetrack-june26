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
FUNCTIONS=("${FUNCTIONS[@]:-davis-proxy willyweather-proxy open-meteo-proxy wunderground-proxy weather-current weather-nearby-stations chemical-info-lookup tractor-fuel-lookup}")

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
  supabase functions deploy "$fn" --project-ref "$PROJECT_REF"
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
