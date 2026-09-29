#!/usr/bin/env bash
# Jonathan only: deploy the shared lookup function. Does not prepare or apply Master.
set -euo pipefail
: "${PROJECT_REF:?Set the reviewed Supabase project ref before deploying}"
if [[ ! -d supabase/functions/chemical-info-lookup ]]; then
  printf 'Run from the repository root.\n' >&2
  exit 1
fi
supabase functions deploy chemical-info-lookup --project-ref "$PROJECT_REF"
