#!/usr/bin/env python3
"""Inspect existing authority contracts read-only; never exports customer records."""
import json
import os
import urllib.request
import urllib.error
import tempfile
from pathlib import Path

REF = "tbafuqwruefgkbyxrxyb"
QUERY = r"""
select jsonb_build_object(
 'revision_evidence', (select coalesce(jsonb_agg(x),'[]'::jsonb) from (
   select review_status, count(distinct r.id) revisions,
     count(distinct r.id) filter(where label_sha256 is not null) hashed_labels,
     count(distinct r.id) filter(where source_summary::text ~* 'concentrat|dilute') summaries_with_terms,
     count(distinct r.id) filter(where vineyard_uses::text ~* 'concentrat|dilute') uses_with_terms,
     array_agg(distinct k) filter(where k is not null) source_keys
   from public.chemical_v3_product_revisions r
   left join lateral jsonb_object_keys(r.source_summary) k on true group by review_status
 ) x),
 'rate_evidence', (select coalesce(jsonb_agg(x),'[]'::jsonb) from (
   select basis, application_method, needs_review, count(*) rates,
     count(*) filter(where source_document_id is not null) document_linked,
     count(*) filter(where concat_ws(' ',condition,raw_text) ~* 'concentrat|dilute') rates_with_terms
   from public.chemical_v3_rate_options group by basis,application_method,needs_review
 ) x),
 'document_evidence', (select coalesce(jsonb_agg(x),'[]'::jsonb) from (
   select document_role,is_current,count(distinct d.id) documents,count(distinct d.id) filter(where sha256 is not null) hashed,
     array_agg(distinct k) filter(where k is not null) metadata_keys
   from public.chemical_v3_documents d left join lateral jsonb_object_keys(d.metadata) k on true
   group by document_role,is_current
 ) x),
 'approved_rate_excerpts', (select coalesce(jsonb_agg(x),'[]'::jsonb) from (
   select r.product_name,r.country_code,r.registration_scheme,r.registration_number,
     o.basis,o.application_method,o.condition,o.raw_text,o.source_page,
     d.document_role,d.sha256 is not null hashed_document,
     d.revision_id=r.id same_revision_document
   from public.chemical_v3_rate_options o
   join public.chemical_v3_product_revisions r on r.id=o.revision_id
   join public.chemical_v3_products p on p.id=r.product_id and p.approved_revision_id=r.id and p.status='approved'
   left join public.chemical_v3_documents d on d.id=o.source_document_id
   where r.review_status='approved' and concat_ws(' ',o.application_method,o.condition,o.raw_text) ~* 'concentrat|dilute'
   order by r.product_name,o.sort_order limit 12
 ) x),
 'authority_writers', (select coalesce(jsonb_agg(x),'[]'::jsonb) from (
   select p.proname,pg_get_function_identity_arguments(p.oid) arguments,pg_get_functiondef(p.oid) definition
   from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prokind='f'
   and (p.proname ~ 'chemical_v3.*(approv|review|rate)|saved_chemicals.*(master|v3)|master.*approv')
 ) x),
 'migration_history', (select coalesce(jsonb_agg(jsonb_build_object('version',version,'name',name,
    'statement_count',cardinality(statements),'bytes',length(statements::text))), '[]'::jsonb)
    from supabase_migrations.schema_migrations)
) inspection;
"""


def main() -> None:
    token = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if not token:
        raise SystemExit("Authorised Management API token unavailable; no connection attempted.")
    request = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=json.dumps({"query": QUERY, "read_only": True}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            rows = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Read-only inspection failed (HTTP {error.code}); credentials not logged.") from None
    output = Path(tempfile.mkdtemp(prefix="vinetrack-authority-private.", dir="/tmp"))
    output.chmod(0o700)
    artifact = output / "inspection.json"
    artifact.write_text(json.dumps(rows, indent=2))
    artifact.chmod(0o600)
    summary = rows[0]["inspection"]
    summary["authority_writers"] = [row["proname"] for row in summary["authority_writers"]]
    print(json.dumps({"artifact": str(artifact), "read_only": True, "inspection": summary}, indent=2))


if __name__ == "__main__":
    main()
