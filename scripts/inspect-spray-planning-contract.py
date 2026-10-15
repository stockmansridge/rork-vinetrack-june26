#!/usr/bin/env python3
"""Capture read-only planning dependencies; no customer rows or database mutations."""
import hashlib
import json
import os
import tempfile
import urllib.error
import urllib.request
from urllib.parse import urlparse
from pathlib import Path

REF = "tbafuqwruefgkbyxrxyb"
QUERY = r"""
with functions as (
 select p.oid, n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) arguments,
 pg_get_userbyid(p.proowner) owner, p.prosecdef, p.proconfig, p.proacl::text privileges,
 pg_get_functiondef(p.oid) definition
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='public' or (n.nspname='auth' and p.proname in ('uid','role','jwt')))
 and p.prokind='f'
), relations as (
 select c.oid,c.relname,c.relrowsecurity,c.relforcerowsecurity,
 pg_get_userbyid(c.relowner) owner,c.relacl::text privileges
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind in ('r','p','v','m','S')
)
select jsonb_build_object(
 'captured_at',now(),'server_version',current_setting('server_version'),
 'relations',(select jsonb_agg(to_jsonb(r)) from relations r),
 'columns',(select jsonb_agg(jsonb_build_object('table',r.relname,'column',a.attname,
 'type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,'acl',a.attacl::text,
 'default',pg_get_expr(d.adbin,d.adrelid)) order by r.relname,a.attnum)
 from relations r join pg_attribute a on a.attrelid=r.oid
 left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
 where a.attnum>0 and not a.attisdropped),
 'constraints',(select jsonb_agg(jsonb_build_object('table',r.relname,'name',c.conname,
 'definition',pg_get_constraintdef(c.oid),'validated',c.convalidated))
 from relations r join pg_constraint c on c.conrelid=r.oid),
 'triggers',(select jsonb_agg(jsonb_build_object('table',r.relname,'name',t.tgname,
 'enabled',t.tgenabled,'definition',pg_get_triggerdef(t.oid),'function_oid',t.tgfoid))
 from relations r join pg_trigger t on t.tgrelid=r.oid where not t.tgisinternal),
 'policies',(select jsonb_agg(to_jsonb(p)) from pg_policies p where schemaname='public'
 and tablename in (select relname from relations)),
 'indexes',(select jsonb_agg(jsonb_build_object('table',r.relname,'definition',pg_get_indexdef(i.indexrelid),
 'valid',i.indisvalid)) from relations r join pg_index i on i.indrelid=r.oid),
 'views',(select jsonb_agg(jsonb_build_object('name',c.relname,'definition',pg_get_viewdef(c.oid,true)))
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relkind in ('v','m')),
 'effective_table_grants',(select jsonb_agg(jsonb_build_object('role',p.rolname,'table',r.relname,
 'select',has_table_privilege(p.oid,r.oid,'SELECT'),'insert',has_table_privilege(p.oid,r.oid,'INSERT'),
 'update',has_table_privilege(p.oid,r.oid,'UPDATE'),'delete',has_table_privilege(p.oid,r.oid,'DELETE')))
 from pg_roles p cross join relations r where p.rolname in ('anon','authenticated','service_role','authenticator')
 and r.relname in ('spray_records','spray_jobs','trips','spray_tank_actuals')),
 'effective_function_grants',(select jsonb_agg(jsonb_build_object('role',p.rolname,'function',f.proname,
 'arguments',f.arguments,'execute',has_function_privilege(p.oid,f.oid,'EXECUTE')))
 from pg_roles p cross join functions f where p.rolname in ('anon','authenticated','service_role','authenticator')),
 'functions',(select jsonb_agg(to_jsonb(f)) from functions f),
 'roles',(select jsonb_agg(jsonb_build_object('name',rolname,'superuser',rolsuper,
 'bypassrls',rolbypassrls,'inherit',rolinherit,'login',rolcanlogin,'config',rolconfig))
 from pg_roles where rolname !~ '^pg_'),
 'memberships',(select jsonb_agg(jsonb_build_object('role',pg_get_userbyid(roleid),
 'member',pg_get_userbyid(member),'set',set_option,'inherit',inherit_option)) from pg_auth_members),
 'default_acl',(select jsonb_agg(jsonb_build_object('owner',pg_get_userbyid(defaclrole),
 'schema',n.nspname,'type',defaclobjtype,'acl',defaclacl::text))
 from pg_default_acl d left join pg_namespace n on n.oid=d.defaclnamespace)
) inspection;
"""


def main() -> None:
    # Managed native credentials can live in the app's ignored dotenv file.
    values = dict(os.environ)
    dotenv = Path(__file__).resolve().parents[1] / "android-vinetrack" / ".env"
    if dotenv.exists():
        for line in dotenv.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip() in ("SUPABASE_ACCESS_TOKEN", "V2_SUPABASE_URL"):
                values.setdefault(key.strip(), value.strip().strip("\"'"))
    token = values.get("SUPABASE_ACCESS_TOKEN")
    url = values.get("V2_SUPABASE_URL", "")
    if not token or urlparse(url).hostname != f"{REF}.supabase.co":
        raise SystemExit("Expected V2 scope/token unavailable; no request made.")
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=json.dumps({"query": QUERY, "read_only": True}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            rows = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Read-only catalog request failed: HTTP {error.code}; no credentials logged.") from None
    except (urllib.error.URLError, TimeoutError):
        raise SystemExit("Read-only catalog transport failed; no credentials logged.") from None
    catalog = rows[0]["inspection"]
    if isinstance(catalog, str):
        catalog = json.loads(catalog)
    directory = Path(tempfile.mkdtemp(prefix="spray-planning-catalog-", dir="/tmp"))
    directory.chmod(0o700)
    payload = json.dumps(catalog, indent=2, sort_keys=True).encode()
    artifact = directory / "catalog.json"
    artifact.write_bytes(payload)
    artifact.chmod(0o600)
    print(json.dumps({"artifact": str(artifact), "sha256": hashlib.sha256(payload).hexdigest(),
                      "read_only": True, "captured_at": catalog["captured_at"],
                      "captured_function_definitions": len(catalog["functions"]),
                      "columns": {table: sum(c["table"] == table for c in catalog["columns"])
                                  for table in ("spray_records", "spray_jobs")}}))


if __name__ == "__main__":
    main()
