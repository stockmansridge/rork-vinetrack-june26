# =============================================================================
# deploy-edge-functions.ps1
# =============================================================================
# Deploys Supabase Edge Functions to the VineTrack iOS Supabase project.
#
# Prerequisites:
#   - Supabase CLI installed
#       Option A (npm):   npm install -g supabase
#       Option B (Scoop): scoop bucket add supabase https://github.com/supabase/scoop-bucket.git
#                         scoop install supabase
#       Option C: See https://supabase.com/docs/guides/cli/getting-started
#   - Run: supabase login
#   - Run from the repository root:
#       .\scripts\deploy-edge-functions.ps1
#   - You must have access to the Supabase project tbafuqwruefgkbyxrxyb.
#
# What this script does:
#   - Deploys the davis-proxy edge function to project tbafuqwruefgkbyxrxyb
#   - Optionally lists deployed functions afterwards
#
# Security:
#   - This script does NOT contain or require any service-role keys, anon keys,
#     or other secrets. It relies entirely on `supabase login` for auth.
#   - Do NOT add credentials to this file.
# =============================================================================

[CmdletBinding()]
param(
    [string]$ProjectRef = "tbafuqwruefgkbyxrxyb",
    [string[]]$Functions = @("davis-proxy", "willyweather-proxy", "open-meteo-proxy", "wunderground-proxy", "weather-current", "weather-nearby-stations", "chemical-info-lookup", "tractor-fuel-lookup"),
    [switch]$ListAfter = $true,
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"

function Write-Section($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

# ---- Pre-flight checks ------------------------------------------------------
Write-Section "Pre-flight checks"

$supabase = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $supabase) {
    Write-Host "Supabase CLI not found on PATH." -ForegroundColor Red
    Write-Host "Install one of:"
    Write-Host "  npm install -g supabase"
    Write-Host "  scoop install supabase"
    Write-Host "  https://supabase.com/docs/guides/cli/getting-started"
    exit 1
}

Write-Host "Supabase CLI: $($supabase.Source)"
& supabase --version

if (-not (Test-Path "supabase/functions")) {
    Write-Host "supabase/functions not found. Run this script from the repo root." -ForegroundColor Red
    exit 1
}

# ---- Deploy ------------------------------------------------------------------
foreach ($fn in $Functions) {
    Write-Section "Deploying $fn -> $ProjectRef"

    $fnPath = Join-Path "supabase/functions" $fn
    if (-not (Test-Path $fnPath)) {
        Write-Host "Function source not found at $fnPath" -ForegroundColor Red
        exit 1
    }

    & supabase functions deploy $fn --project-ref $ProjectRef
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Deployment failed for $fn" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "Deployed: $fn" -ForegroundColor Green
}

# ---- List --------------------------------------------------------------------
if ($ListAfter) {
    Write-Section "Functions on $ProjectRef"
    & supabase functions list --project-ref $ProjectRef
}

# ---- Verification hint -------------------------------------------------------
if (-not $SkipVerify) {
    Write-Section "Verification"
    Write-Host "Run:"
    Write-Host "  curl.exe -i https://$ProjectRef.supabase.co/functions/v1/willyweather-proxy"
    Write-Host ""
    Write-Host "Expected:"
    Write-Host "  401 / 405 / other auth or method error = function IS deployed (good)"
    Write-Host "  404 NOT_FOUND                          = still NOT deployed (bad)"
    Write-Host ""
    Write-Host "Then test from the Lovable portal:"
    Write-Host "  Setup -> Weather -> Test saved credentials"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
