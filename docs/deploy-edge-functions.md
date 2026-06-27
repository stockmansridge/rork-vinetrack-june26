# Deploying Supabase Edge Functions (Windows-friendly)

This project's iOS Supabase project ref is **`tbafuqwruefgkbyxrxyb`**.
The Lovable portal calls the `davis-proxy` Edge Function on this project, so
the function must be deployed there for "Test saved credentials" to work.

You do **not** need a Mac. The PowerShell script below works on Windows.

## Deployment policy

Deployment is **manual via the PowerShell script** for now. We are intentionally
**not** using a GitHub Actions workflow yet, because that would require storing
Supabase deploy credentials in GitHub Secrets — an extra credential surface we
want to avoid until the manual flow is proven stable.

Preferred flow:

```powershell
npm install -g supabase
supabase login
.\scripts\deploy-edge-functions.ps1
```

A CI workflow can be added later once this is stable.

## 1. Install the Supabase CLI on Windows

Pick one option.

### Option A — npm (simplest)

```powershell
npm install -g supabase
supabase --version
```

### Option B — Scoop

```powershell
scoop bucket add supabase https://github.com/supabase/scoop-bucket.git
scoop install supabase
supabase --version
```

### Option C — Official instructions

See <https://supabase.com/docs/guides/cli/getting-started> for the latest
Windows install options (including standalone binary).

> Do **not** use `brew` on Windows. The PowerShell script does not require it.

## 2. Log in

```powershell
supabase login
```

This opens a browser for auth. No keys are stored in the repo.

You must have access to the Supabase project `tbafuqwruefgkbyxrxyb`. If you
don't, ask the iOS / Rork team to grant access or run the deploy themselves.

## 3. Deploy

From the repo root in PowerShell:

```powershell
.\scripts\deploy-edge-functions.ps1
```

This will:

1. Check that the Supabase CLI is on `PATH`.
2. Deploy `davis-proxy` to project `tbafuqwruefgkbyxrxyb`.
3. List the deployed functions.

### Optional flags

```powershell
# Deploy a different/extra function
.\scripts\deploy-edge-functions.ps1 -Functions davis-proxy,other-fn

# Skip the post-deploy `functions list`
.\scripts\deploy-edge-functions.ps1 -ListAfter:$false

# Override project ref (rarely needed)
.\scripts\deploy-edge-functions.ps1 -ProjectRef tbafuqwruefgkbyxrxyb
```

### Mac / Linux equivalent

```bash
./scripts/deploy-edge-functions.sh
```

## 4. Verify deployment

```powershell
curl.exe -i https://tbafuqwruefgkbyxrxyb.supabase.co/functions/v1/davis-proxy
```

Interpretation:

| Response | Meaning |
| --- | --- |
| `401 Unauthorized` | **Deployed** (expected — request needs auth). |
| `405 Method Not Allowed` | **Deployed** (wrong HTTP method on bare GET). |
| Other auth/method error | **Deployed** — function exists. |
| `404 NOT_FOUND` / `FUNCTION_NOT_FOUND` | **Not deployed.** `davis-proxy` is missing — re-run the script. |

Rule of thumb:

- **404 NOT_FOUND** → `davis-proxy` is **not** deployed.
- **401 / 405 / any auth or method error** → the function **exists** and is deployed.

After a successful deploy, test in the Lovable portal:
**Setup → Weather → Test saved credentials**.

## 5. Test from the Lovable portal

1. Open the portal.
2. Setup → Weather → Davis WeatherLink.
3. Click **Test saved credentials**.

Expected:

- Deployed + valid credentials → success message, `last_test_status = ok`.
- Deployed + invalid credentials → Davis-specific invalid-credentials error.
- Not deployed → "Failed to send a request to the Edge Function" (re-deploy).

## Security notes

- No service-role key, anon key, or secret is stored in `scripts/` or `docs/`.
- Auth is handled entirely by `supabase login`.
- Do not paste credentials into the script or commit them to the repo.
- Only the function code is deployed; secrets stay in Supabase project settings.
