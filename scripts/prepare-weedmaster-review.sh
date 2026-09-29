#!/usr/bin/env bash
# Jonathan only: authenticated Weedmaster cover attestation + pending preview, never Master apply.
# Usage: bash scripts/prepare-weedmaster-review.sh LIVE_MASTER_UUID EXISTING_PRIVATE_OUTPUT_DIRECTORY
# Requires V2_SUPABASE_URL, EXPO_PUBLIC_SUPABASE_ANON_KEY and VINETRACK_ADMIN_ACCESS_TOKEN.
set -euo pipefail
if [[ $# -ne 2 || ! -d "$2" || ! -f docs/weedmaster-acceptance/weedmaster_duo_documented.pdf ]]; then
  printf 'Run from repo root; supply live Weedmaster Master UUID and existing private output directory.\n' >&2
  exit 1
fi
: "${V2_SUPABASE_URL:?Set backend URL}"
: "${EXPO_PUBLIC_SUPABASE_ANON_KEY:?Set public anon key}"
: "${VINETRACK_ADMIN_ACCESS_TOKEN:?Set authenticated System Admin JWT}"
# Do not use the locally reconstructed acceptance fixture as proof of the live row ID.
# The runner reads the live row and rejects a mismatched registration identity before preparing.
deno run --allow-env=V2_SUPABASE_URL,EXPO_PUBLIC_SUPABASE_ANON_KEY,VINETRACK_ADMIN_ACCESS_TOKEN \
  --allow-net --allow-read --allow-write="$2" scripts/master-stored-review.ts prepare \
  --master-id "$1" --expected-identity AU:apvma:53576 \
  --evidence-file docs/weedmaster-acceptance/visual_review_candidate.json \
  --document docs/weedmaster-acceptance/weedmaster_duo_documented.pdf \
  --manifest "$2/weedmaster-pending-manifest.json" \
  --report "$2/weedmaster-preparation-report.json" \
  --diagnostic "$2/weedmaster-indexed-diagnostic.json"
