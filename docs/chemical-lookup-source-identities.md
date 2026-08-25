# Chemical lookup — the four source identities

Status: contract. Applies to the `chemical-info-lookup` Edge Function response
and every client that decodes it (iOS, Android, Portal).

## The fields

The `registration` block carries five URL fields. Four are distinct source
identities; the fifth is a legacy alias retained for shipped clients.

```jsonc
{
  "registration": {
    "label_reference":          "https://elabels.apvma.gov.au/80160ELBL.pdf",
    "regulator_label_url":      "https://elabels.apvma.gov.au/80160ELBL.pdf",
    "manufacturer_label_url":   "https://www.omnia.com.au/files/2025/07/Sprayseal%205L_Digi.pdf",
    "manufacturer_product_url": "https://www.omnia.com.au/products/sprayseal",
    "sds_url":                  "https://www.omnia.com.au/files/sprayseal-sds.pdf"
  }
}
```

These names are **snake_case and final**. `productURL`, `sdsURL` and `labelURL`
are keys of the *internal extraction shape* that feeds the response builder —
they are not the wire contract, and clients must not decode them.

The exact key set is locked by `WIRE:` tests in
`supabase/functions/chemical-info-lookup/sprayseal_acceptance_test.ts`. They
assert the full key set rather than individual membership, so adding, renaming
or dropping a field fails there rather than silently in a client.

| Field | Meaning | Authority |
| --- | --- | --- |
| `regulator_label_url` | The regulator's approved label (APVMA eLabels). | Authoritative for registration. |
| `manufacturer_label_url` | The registrant's own rendering of the approved label. | Complementary evidence. Never establishes registration identity. |
| `manufacturer_product_url` | The registrant's product page. | Marketing. Never a label, never a rate. |
| `sds_url` | The Safety Data Sheet. | Handling and first aid. Never a label. |
| `label_reference` | Legacy single field. | Points at `regulator_label_url` when present, otherwise `manufacturer_label_url`. |

### Why they are never collapsed

An SDS and a brochure are both PDFs on a manufacturer's domain. Collapsing them
into one "label URL" is how a marketing rate acquires the authority of an
approved label. Each identity is derived separately by the server and travels
in its own field.

`label_reference` keeps pointing at the **regulator** document so that clients
built before the split do not regress. It falls back to the manufacturer label
only when no regulator document was found — a client that decodes only this
field then still gets a label rather than nothing.

## How `manufacturer_label_url` is established

Promotion requires evidence that is reproducible from bytes. The server fetches
the registrant's product page and re-derives the relationship; it does **not**
trust the research model's account of what a page linked.

1. Registration identity resolves against the register (APVMA).
2. Research proposes candidate product pages. These are **leads**.
3. `research/page_inspector.ts` fetches at most **2 pages per lookup**
   (attempts, not successes), each already classified as a trusted registrant
   product page. Search engines and resellers are discovery routes and are
   never fetched for evidence.
4. Anchors are parsed from the fetched HTML: hrefs resolved against the final
   URL, entities decoded, `title`/`aria-label` included as wording.
5. `research/linked_documents.ts` decides. A PDF is promoted only when the page
   corresponds to the registered product, the PDF is on the same registrant
   host, the link text says label, and it does not say SDS/Brochure/TDS. A
   combined `Label & SDS` link is refused rather than guessed at.

Model-supplied `link_text` / `linked_from_url` / `linked_from_product_name`
remain in the schema as **discovery hints and debug fields only**. When a page
was not inspected, any such claim is recorded in the rejection log with the
`model_relationship_hint_only:` prefix and promotes nothing.

### Bounds

| Bound | Value |
| --- | --- |
| Product-page fetch attempts per lookup | 2 (attempts, not successes) |
| Response body | 2 MB, enforced by incremental read + stream cancel |
| Anchors parsed per page | 400 |
| Per-fetch timeout | 6 s |
| Total inspection budget per lookup | 9 s |

An oversized response is **rejected**, never parsed from a truncated body: half
a document list is an excellent way to promote the wrong PDF as the label.

Every failure — HTTP error, non-HTML content type, off-host redirect, oversize,
timeout — fails closed with a named outcome and promotes nothing. Register
identity, chemistry and regulator label evidence are never degraded by a
registrant's website being unavailable.

## Rate authority is unchanged

Manufacturer evidence does not carry rates. Canonical structured rates come
from the authoritative label document path only. A number printed in product
page marketing copy is never promoted to a registered rate, even when it agrees
with the label — the inspector carries no rate text out of the page at all.
