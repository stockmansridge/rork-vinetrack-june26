#!/usr/bin/env bash
set -euo pipefail
umask 077
# Connection values must be injected securely into the process, never committed or printed.
# Use an existing authorised login only; never link, create roles or change grants.
# PGHOST/PGUSER and a local secret store, PGSERVICE or password file are libpq inputs.
readonly expected_ref=tbafuqwruefgkbyxrxyb
: "${PGHOST:?Provide the authorised source host through secure environment configuration}"
: "${PGUSER:?Provide the authorised source user through secure environment configuration}"
if [[ -z "${PGPASSWORD:-}" && -z "${PGSERVICE:-}" && -z "${PGPASSFILE:-}" && ! -f "${HOME}/.pgpass" ]]; then
  printf 'Configure an existing authorised libpq service/password file or local secret-store injection; no password prompt is allowed.\n' >&2
  exit 1
fi
case "$PGHOST" in
  "db.$expected_ref.supabase.co") ;;
  *.pooler.supabase.com) [[ "$PGUSER" == *".$expected_ref" ]] || { printf 'Refusing mismatched pooled project user\n' >&2; exit 1; } ;;
  *) printf 'Refusing a source other than the approved VineTrackv2 project\n' >&2; exit 1 ;;
esac
export PGDATABASE=postgres PGSSLMODE=require PGCONNECT_TIMEOUT=15
export PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=900000 -c lock_timeout=10000'
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Artifacts always remain outside the repository; do not supply a repository output path.
readonly output="$(mktemp -d /tmp/vinetrack-schema-private.XXXXXXXX)"
chmod 700 "$output"
psql --no-password -X -v ON_ERROR_STOP=1 -At -f "$script_dir/vinetrack-review-catalog.sql" > "$output/source-catalog.json"
# Do NOT use Supabase's default managed-schema exclusions. Native auth and every
# non-system schema/dependency, owner, policy and ACL are required in this export.
pg_dump --no-password --schema-only --format=plain --quote-all-identifiers --file="$output/schema.sql"
pg_dumpall --no-password --roles-only --no-role-passwords --file="$output/roles-password-free.sql"
psql --no-password -X -v ON_ERROR_STOP=1 -At -f "$script_dir/vinetrack-review-catalog.sql" > "$output/source-catalog-after.json"
# Abort if DDL changed while the artifacts were captured. This is not a restore validation.
cmp "$output/source-catalog.json" "$output/source-catalog-after.json"
sha256sum "$output/schema.sql" "$output/roles-password-free.sql" "$output/source-catalog.json" > "$output/SHA256SUMS"
printf 'Private schema-only and password-free role exports prepared at %s\n' "$output"
printf 'Restore only into an isolated PostgreSQL 17/Supabase-compatible clone; compare catalogs before SQL v2.\n'
