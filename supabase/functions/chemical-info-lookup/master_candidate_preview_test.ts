// deno-lint-ignore-file no-explicit-any require-await
import { assert, assertEquals } from "jsr:@std/assert";
import { fetchApprovedMaster } from "./ingestion/master_lookup.ts";
import { isGrapevineCrop } from "./grapevine_label.ts";
import { validateDefaultRates } from "./default_rates.ts";

const fixture = JSON.parse(await Deno.readTextFile(new URL(
  "../../../docs/weedmaster-acceptance/revision-2-shared/master-revision-2.sanitized-fixture.json", import.meta.url,
)));
const candidate = fixture.row ?? fixture;
const before = structuredClone(candidate);
type Handler = (request: Request) => Promise<Response>;

Deno.test("exact candidate preview: authorization, identities, grouped rates and database-only serving", async (t) => {
  const originalServe = Deno.serve;
  const originalGet = Deno.env.get;
  const originalFetch = globalThis.fetch;
  let captured: Handler | null = null;
  let row: any = structuredClone(candidate);
  let authenticated = true;
  let admin: unknown = true;
  let dbUnavailable = false;
  let expectedStatus = "candidate";
  const calls: string[] = [];
  const body = { action: "structured_master_preview", master_chemical_id: candidate.id,
    country: "Australia", registrationScheme: "apvma", registrationNumber: "53576" };
  try {
    // No OpenAI key: this path must not depend on enrichment configuration.
    Deno.env.get = (key: string) => ({ SUPABASE_URL: "https://catalogue.test",
      SUPABASE_SERVICE_ROLE_KEY: "mock-service", SUPABASE_ANON_KEY: "mock-anon" } as Record<string, string>)[key];
    Deno.serve = ((handler: Handler) => { captured = handler; return {}; }) as unknown as typeof Deno.serve;
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      calls.push(url.pathname);
      assertEquals(url.origin, "https://catalogue.test", "no external discovery, AI, PDF or parsing");
      assert(init?.signal instanceof AbortSignal, "all preview network work is bounded");
      const headers = new Headers(init?.headers);
      if (url.pathname === "/auth/v1/user") {
        assertEquals(init?.method ?? "GET", "GET");
        assertEquals(headers.get("Authorization"), "Bearer mock-user");
        return Response.json(authenticated ? { id: "mock-auth-user" } : {}, { status: authenticated ? 200 : 401 });
      }
      if (url.pathname === "/rest/v1/rpc/is_system_admin") {
        assertEquals(init?.method, "POST", "only POST allowed is read-only authoritative admin check");
        assertEquals(headers.get("Authorization"), "Bearer mock-user");
        assertEquals(headers.get("apikey"), "mock-anon");
        assertEquals(init?.body, "{}");
        return Response.json(admin);
      }
      assertEquals(url.pathname, "/rest/v1/master_chemicals", "no cache, preview storage or writes");
      assertEquals(init?.method ?? "GET", "GET");
      assertEquals(url.searchParams.get("id"), `eq.${candidate.id}`);
      assertEquals(url.searchParams.get("review_status"), `eq.${expectedStatus}`);
      assertEquals(url.searchParams.get("limit"), "1");
      if (dbUnavailable) throw new DOMException("mock read unavailable", "TimeoutError");
      return Response.json(row ? [row] : []);
    }) as typeof fetch;
    await import("./index.ts");
    const handler = captured as Handler | null;
    assert(handler);
    const request = (patch: Record<string, unknown> = {}, withAuth = true) => handler(new Request("https://function.test/chemical-info-lookup", {
      method: "POST", headers: { "content-type": "application/json", ...(withAuth ? { Authorization: "Bearer mock-user" } : {}) },
      body: JSON.stringify({ ...body, ...patch }),
    }));

    await t.step("ordinary Master serving remains approved-only and cannot return this candidate", async () => {
      const queries: string[] = [];
      const result = await fetchApprovedMaster(async (query) => {
        queries.push(query);
        assert(query.includes("review_status=eq.approved"));
        return candidate.review_status === "approved" ? [candidate] : [];
      }, candidate.registered_product_name, "AU", "53576", "apvma");
      assertEquals(result, null);
      assert(queries.length > 0);
    });
    await t.step("missing bearer rejected before any network request", async () => {
      calls.length = 0;
      assertEquals((await request({}, false)).status, 401);
      assertEquals(calls, []);
    });
    await t.step("invalid session rejected before admin or Master read", async () => {
      calls.length = 0;
      authenticated = false;
      assertEquals((await request()).status, 401);
      assertEquals(calls, ["/auth/v1/user"]);
      authenticated = true;
    });
    await t.step("non-admin and non-boolean admin result rejected before Master read", async () => {
      for (const denied of [false, "true", null]) {
        calls.length = 0;
        admin = denied;
        assertEquals((await request()).status, 403);
        assertEquals(calls, ["/auth/v1/user", "/rest/v1/rpc/is_system_admin"]);
      }
      admin = true;
    });
    await t.step("missing exact ID rejected", async () => {
      for (const patch of [{ master_chemical_id: undefined }, { master_chemical_id: "not-an-id" }]) {
        calls.length = 0;
        assertEquals((await request(patch)).status, 400);
        assert(!calls.includes("/rest/v1/master_chemicals"));
      }
    });
    await t.step("missing or unknown jurisdiction never defaults to Australia or blocks exact identity", async () => {
      for (const country of ["", "unrecognised country"]) {
        const response = await request({ country });
        assertEquals(response.status, 200);
        assertEquals((await response.json()).jurisdiction.resolved_country_code, null);
      }
    });
    await t.step("returned Master ID mismatch rejected", async () => {
      row = { ...candidate, id: "00000000-0000-0000-0000-000000000000" };
      assertEquals((await request()).status, 409);
      row = structuredClone(candidate);
    });
    await t.step("registration key, country, scheme and number mismatches rejected", async () => {
      for (const patch of [{ registration_identity_key: "AU:apvma:99999" }, { registration_country: "NZ" },
        { registration_scheme: "wrong" }, { registration_number: "99999" }]) {
        row = { ...candidate, ...patch };
        assertEquals((await request()).status, 409);
      }
      row = structuredClone(candidate);
      assertEquals((await request({ registrationNumber: "99999" })).status, 409);
    });
    // Disposable international contract rows, not claims about actual catalogue products.
    const countries = [
      { country: "AU", scheme: "apvma", number: "53576" },
      { country: "NZ", scheme: "acvm", number: "P12345" },
      { country: "France", code: "FR", scheme: null, number: null },
      { country: "US", scheme: "epa", number: "123-456" },
      { country: "South Africa", code: "ZA", scheme: null, number: null },
    ];
    for (const entry of countries) {
      for (const status of ["candidate", "approved"] as const) {
        await t.step(`${entry.country} ${status}: exact ID hydration with optional registration`, async () => {
          const code = entry.code ?? entry.country;
          expectedStatus = status;
          row = { ...structuredClone(candidate), review_status: status, registration_country: code,
            registration_scheme: entry.scheme, registration_number: entry.number,
            registration_identity_key: entry.scheme ? `${code}:${entry.scheme}:${entry.number}` : null };
          const snapshot = structuredClone(row);
          const patch = { action: status === "candidate" ? "structured_master_preview" : "structured",
            country: entry.country, registrationScheme: entry.scheme, registrationNumber: entry.number };
          calls.length = 0;
          const response = await request(patch);
          assertEquals(response.status, 200);
          const served = await response.json();
          assertEquals(served.master.master_chemical_id, candidate.id);
          assertEquals(served.jurisdiction.resolved_country_code, code);
          assertEquals(served.registration.scheme, entry.scheme);
          assertEquals(served.registration.registration_number, entry.number);
          assertEquals(served.master.registration_identity_key, row.registration_identity_key);
          assertEquals(served.master.catalogue_status, status);
          assertEquals([served.default_rate_options.per_hectare.length, served.default_rate_options.per_100_litres.length], [9, 8]);
          assertEquals(calls, status === "candidate"
            ? ["/auth/v1/user", "/rest/v1/rpc/is_system_admin", "/rest/v1/master_chemicals"]
            : ["/rest/v1/master_chemicals"]);
          assertEquals(row, snapshot);
          // Omitting either/both registration hints must not block even registered products.
          for (const omissions of [{ registrationScheme: undefined }, { registrationNumber: undefined },
            { registrationScheme: undefined, registrationNumber: undefined }]) {
            assertEquals((await request({ ...patch, ...omissions })).status, 200);
          }
          assertEquals((await request({ ...patch, registrationNumber: "WRONG" })).status, 409);
          assertEquals((await request({ ...patch, registrationScheme: "wrong" })).status, 409);
          assertEquals((await request({ ...patch, country: code === "AU" ? "FR" : "AU" })).status, 409);
          row.id = "00000000-0000-0000-0000-000000000000";
          assertEquals((await request(patch)).status, 409);
          row = { ...snapshot, review_status: status === "candidate" ? "approved" : "candidate" };
          assertEquals((await request(patch)).status, 409);
          expectedStatus = "candidate";
          row = structuredClone(candidate);
        });
      }
    }
    for (const category of ["fertiliser", "biostimulant"]) {
      for (const status of ["candidate", "approved"] as const) {
        await t.step(`unregistered ${category} ${status}: no invented scheme, rates or label`, async () => {
          expectedStatus = status;
          row = { ...structuredClone(candidate), registered_product_name: `Reviewed ${category}`,
            product_category: category, review_status: status, registration_country: null,
            registration_scheme: null, registration_number: null, registration_identity_key: null,
            registered_uses: [], viticulture_rates: { per_hectare: [], per_100_litres: [] },
            verification_unresolved_fields: [], verification_sources: [],
            label_reference: null, manufacturer_label_url: null, regulator_label_url: null };
          const patch = { action: status === "candidate" ? "structured_master_preview" : "structured",
            country: "Italy", registrationScheme: undefined, registrationNumber: undefined };
          const response = await request(patch);
          assertEquals(response.status, 200);
          const served = await response.json();
          assertEquals(served.master.master_chemical_id, candidate.id);
          assertEquals(served.product_category, category);
          assertEquals(served.registration.scheme, null);
          assertEquals(served.registration.registration_number, null);
          assertEquals(served.jurisdiction.resolved_country_code, "IT");
          assertEquals(served.default_rate_options.per_hectare, []);
          assertEquals(served.default_rate_options.per_100_litres, []);
          expectedStatus = "candidate";
          row = structuredClone(candidate);
        });
      }
    }
    await t.step("canonical country codes beyond AU/NZ need no register adapter", async () => {
      for (const country of ["GB", "IT", "ES", "CL", "AR", "CA", "PT"]) {
        row = { ...structuredClone(candidate), registration_country: country, registration_scheme: null,
          registration_number: null, registration_identity_key: null };
        assertEquals((await request({ country, registrationScheme: undefined, registrationNumber: undefined })).status, 200);
      }
      row = structuredClone(candidate);
    });
    await t.step("approved exact read failures never substitute discovery or candidates", async () => {
      expectedStatus = "approved";
      const patch = { action: "structured" };
      row = null;
      assertEquals((await request(patch)).status, 404);
      row = { ...structuredClone(candidate), review_status: "approved" };
      row.verification_unresolved_fields.push("RATES:GRAPEVINE:Phalaris");
      assertEquals((await request(patch)).status, 503);
      dbUnavailable = true;
      const response = await request(patch);
      assertEquals(response.status, 503);
      assertEquals((await response.json()).code, "catalogue_hydration_unavailable");
      dbUnavailable = false;
      expectedStatus = "candidate";
      row = structuredClone(candidate);
    });
    await t.step("non-candidate returned by DB rejected", async () => {
      row = { ...candidate, review_status: "approved" };
      assertEquals((await request()).status, 409);
      row = structuredClone(candidate);
    });
    await t.step("missing or incomplete candidate never falls through to enrichment", async () => {
      row = null;
      assertEquals((await request()).status, 404);
      row = structuredClone(candidate);
      row.verification_unresolved_fields.push("RATES:GRAPEVINE:Phalaris");
      calls.length = 0;
      assertEquals((await request()).status, 503);
      assertEquals(calls, ["/auth/v1/user", "/rest/v1/rpc/is_system_admin", "/rest/v1/master_chemicals"]);
      row = structuredClone(candidate);
    });
    await t.step("database failure returns concise failure without enrichment fallback", async () => {
      calls.length = 0;
      dbUnavailable = true;
      const response = await request();
      assertEquals(response.status, 503);
      assertEquals((await response.json()).code, "catalogue_preview_unavailable");
      assertEquals(calls, ["/auth/v1/user", "/rest/v1/rpc/is_system_admin", "/rest/v1/master_chemicals"]);
      dbUnavailable = false;
    });
    await t.step("candidate canonical options, strict vineyard eligibility, unchanged IDs and grouped output", async () => {
      calls.length = 0;
      const started = performance.now();
      const response = await request();
      const elapsed = performance.now() - started;
      assertEquals(response.status, 200);
      const served = await response.json();
      assertEquals(calls, ["/auth/v1/user", "/rest/v1/rpc/is_system_admin", "/rest/v1/master_chemicals"]);
      assertEquals(served.admin_preview, { read_only: true, catalogue_status: "candidate", approved_for_customer_use: false });
      assertEquals(served.master.master_chemical_id, candidate.id);
      assertEquals(served.master.master_revision, 2);
      assertEquals(served.master.catalogue_status, "candidate");
      assertEquals(served.master.registration_identity_key, "AU:apvma:53576");
      assertEquals(served.registered_uses, candidate.registered_uses);
      assertEquals(served.viticulture_rates, candidate.viticulture_rates);
      const options = served.default_rate_options;
      assertEquals([options.per_hectare.length, options.per_100_litres.length], [9, 8]);
      const vineyard = candidate.registered_uses.filter((use: any) => isGrapevineCrop(use.crop));
      assertEquals(vineyard.length, 70);
      const all = [...options.per_hectare, ...options.per_100_litres];
      const vineyardDirections = new Set(vineyard.map((use: any) => use.direction_id));
      for (const option of all) {
        assert(option.crops.every(isGrapevineCrop));
        assert(option.direction_ids.every((id: string) => vineyardDirections.has(id)));
        assert(!option.conditions.some((value: string) => /Wiper|Knapsack|Cut stump|LOW VOLUME|Controlled droplet/i.test(value)));
        assert(option.conditions.length > 0, "supporting conditions remain available for display");
      }
      const phalaris = options.per_100_litres.find((option: any) => option.option_key === "default_option_v1_5f58b1d9f422213e1ecf8632036c1356");
      assert(phalaris);
      assertEquals(phalaris.rate_ids, ["rate_v1_4efec198ead373a3286939ced245fadf"]);
      assertEquals(phalaris.direction_ids, ["direction_v1_1363f3205ca7b639cd5f970a03d91785"]);
      assertEquals([phalaris.basis, phalaris.unit, phalaris.min_value, phalaris.max_value], ["per_100_litres", "mL", 500, 1000]);
      assertEquals(phalaris.targets, ["Phalaris"]);
      assertEquals(phalaris.conditions, ["Handgun"]);
      assertEquals(validateDefaultRates({ version: 1, per_hectare: null, per_100_litres: { ...phalaris, source: "operator" } }).violations, []);
      assert(all.some((option: any) => option.targets.length > 3 && option.rate_ids.length > 3));
      console.log(JSON.stringify({ mocked_preview_ms: Number(elapsed.toFixed(2)), raw_vineyard_directions: vineyard.length,
        raw_flattened_rates: candidate.viticulture_rates.per_hectare.length + candidate.viticulture_rates.per_100_litres.length,
        grouped_counts: { per_hectare: options.per_hectare.length, per_100_litres: options.per_100_litres.length },
        grouped_examples: all.map((option: any) => ({ basis: option.basis, value: option.value,
          min: option.min_value, max: option.max_value, unit: option.unit, conditions: option.conditions,
          targets: option.targets.slice(0, 3), more: Math.max(0, option.targets.length - 3) })) }));
      assertEquals(row, before);
      assertEquals(candidate, before);
    });
  } finally {
    Deno.serve = originalServe;
    Deno.env.get = originalGet;
    globalThis.fetch = originalFetch;
  }
});
