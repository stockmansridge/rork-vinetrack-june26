#!/usr/bin/env bash
set -euo pipefail
umask 077
# Connection values must be injected securely into the process, never committed or printed.
# Use an existing authorised login only; never link, create roles or change grants.
# PGHOST/PGUSER and a local secret store, PGSERVICE or password file are libpq inputs.
readonly expected_ref=tbafuqwruefgkbyxrxyb
for tool in psql pg_dump pg_dumpall; do
  command -v "$tool" >/dev/null || { printf 'Missing required PostgreSQL 17 tool: %s\n' "$tool" >&2; exit 1; }
  [[ "$("$tool" --version)" =~ PostgreSQL\)\ 17\. ]] || { printf 'PostgreSQL 17 required for %s\n' "$tool" >&2; exit 1; }
done
command -v sha256sum >/dev/null || { printf 'Missing sha256sum (install coreutils)\n' >&2; exit 1; }
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
stage='source catalog inspection'
trap 'printf "Export stopped during %s. Keep diagnostics private; report the exact denied object/privilege. Do not restore partial artifacts or change production permissions.\n" "$stage" >&2' ERR
psql --no-password -X -v ON_ERROR_STOP=1 -At -f "$script_dir/vinetrack-review-catalog.sql" > "$output/source-catalog.json"
# Do NOT use Supabase's default managed-schema exclusions. Native auth and every
# non-system schema/dependency, owner, policy and ACL are required in this export.
stage='complete schema-only pg_dump'
pg_dump --no-password --schema-only --format=plain --quote-all-identifiers --file="$output/schema.sql"
stage='password-free role catalog pg_dumpall'
pg_dumpall --no-password --roles-only --no-role-passwords --file="$output/roles-password-free.sql"
stage='post-export source catalog inspection'
psql --no-password -X -v ON_ERROR_STOP=1 -At -f "$script_dir/vinetrack-review-catalog.sql" > "$output/source-catalog-after.json"
# Abort if DDL changed while the artifacts were captured. This is not a restore validation.
stage='catalog drift comparison'
cmp "$output/source-catalog.json" "$output/source-catalog-after.json"
stage='private artifact checksums'
(cd "$output" && sha256sum schema.sql roles-password-free.sql source-catalog.json source-catalog-after.json > SHA256SUMS)
printf 'Private schema-only and password-free role exports prepared at %s\n' "$output"
printf 'Roles dump includes managed roles: REVIEW ONLY. Never replay it wholesale.\n'
printf 'Restore only approved required custom roles/grants; preserve staging native Supabase roles.\n'
printf 'Restore only into an isolated PostgreSQL 17/Supabase-compatible clone; compare catalogs before SQL v2.\n'
