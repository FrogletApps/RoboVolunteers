<#
.SYNOPSIS
  Builds RoboVolunteers Flutter app and/or Auth OTP Cloudflare Worker with automatic date-based version (YYYY.M.D) and Git commit count build number.
.PARAMETER Target
  The build target (e.g. web, worker, server, apk, appbundle, windows, ipa, all). Default: web.
.PARAMETER ExtraArgs
  Additional arguments passed to flutter build.
.EXAMPLE
  .\scripts\build.ps1 web
  .\scripts\build.ps1 worker
  .\scripts\build.ps1 all
  .\scripts\build.ps1 apk
#>
param (
    [string]$Target = "web",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

# Get current date formatted as YYYY.M.D (e.g., 2026.11.3)
$today = Get-Date
$versionName = "$($today.Year).$($today.Month).$($today.Day)"

# Get commit count from git
try {
    $buildNumber = (git rev-list --count HEAD).Trim()
} catch {
    $buildNumber = "1"
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Building RoboVolunteers ($Target)" -ForegroundColor Cyan
Write-Host " Version Name: $versionName" -ForegroundColor Yellow
Write-Host " Build Number: $buildNumber" -ForegroundColor Yellow
Write-Host " Full Version: $versionName+$buildNumber" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan

function Build-Worker {
    Write-Host "`n>>> Building & Testing Auth OTP Worker..." -ForegroundColor Cyan
    $workerDir = Join-Path $PSScriptRoot "..\workers\auth-otp"
    Push-Location $workerDir
    try {
        if (-not (Test-Path (Join-Path $workerDir "node_modules"))) {
            Write-Host "Installing worker dependencies (npm install)..." -ForegroundColor Yellow
            npm install
            if ($LASTEXITCODE -ne 0) { throw "npm install failed in worker directory" }
        }
        Write-Host "Running worker typecheck..." -ForegroundColor Gray
        npm run typecheck
        if ($LASTEXITCODE -ne 0) { throw "Worker typecheck failed" }

        Write-Host "Running worker unit tests..." -ForegroundColor Gray
        npm test
        if ($LASTEXITCODE -ne 0) { throw "Worker unit tests failed" }

        Write-Host ">>> Auth OTP Worker verification & tests completed successfully." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

function Build-Flutter([string]$flutterTarget) {
    Write-Host "`n>>> Building Flutter Client ($flutterTarget)..." -ForegroundColor Cyan
    $appDir = Join-Path $PSScriptRoot "..\app"
    Push-Location $appDir
    try {
        if (-not $env:GRADLE_OPTS -or $env:GRADLE_OPTS -notmatch "--enable-native-access") {
            $env:GRADLE_OPTS = "$($env:GRADLE_OPTS) --enable-native-access=ALL-UNNAMED".Trim()
        }

        $buildArgs = @($flutterTarget, "--build-name=$versionName", "--build-number=$buildNumber")

        # For web, default to --wasm unless explicitly overridden with --wasm or --no-wasm
        if ($flutterTarget -eq "web" -and ($ExtraArgs -notcontains "--wasm") -and ($ExtraArgs -notcontains "--no-wasm")) {
            $buildArgs += "--wasm"
        }

        # Wire Firebase API key from local firebase.env.json or FIREBASE_API_KEY env var
        $hasFirebaseDefine = $false
        if ($ExtraArgs) {
            foreach ($arg in $ExtraArgs) {
                if ($arg -like "--dart-define-from-file*" -or $arg -like "*FIREBASE_API_KEY=*") {
                    $hasFirebaseDefine = $true
                    break
                }
            }
        }

        if (-not $hasFirebaseDefine) {
            $appEnvFile = Join-Path $appDir "firebase.env.json"
            $rootEnvFile = Join-Path $PSScriptRoot "..\firebase.env.json"
            if (Test-Path $appEnvFile) {
                Write-Host "Using Firebase config from app/firebase.env.json" -ForegroundColor Gray
                $buildArgs += "--dart-define-from-file=$appEnvFile"
            } elseif (Test-Path $rootEnvFile) {
                Write-Host "Using Firebase config from firebase.env.json" -ForegroundColor Gray
                $buildArgs += "--dart-define-from-file=$rootEnvFile"
            } elseif (-not [string]::IsNullOrWhiteSpace($env:FIREBASE_API_KEY)) {
                Write-Host "Using FIREBASE_API_KEY from environment" -ForegroundColor Gray
                $buildArgs += "--dart-define=FIREBASE_API_KEY=$($env:FIREBASE_API_KEY)"
            } else {
                throw "Missing Firebase API key. Copy app/firebase.env.example.json to app/firebase.env.json and set FIREBASE_API_KEY, or set the FIREBASE_API_KEY environment variable."
            }
        }

        if ($ExtraArgs) {
            $buildArgs += $ExtraArgs
        }

        flutter build @buildArgs
        if ($LASTEXITCODE -ne 0) { throw "Flutter build failed for target '$flutterTarget'" }
        Write-Host ">>> Flutter client ($flutterTarget) build completed successfully." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

switch ($Target.ToLower()) {
    { $_ -in "worker", "server" } {
        Build-Worker
    }
    "all" {
        Build-Worker
        Build-Flutter "web"
    }
    default {
        Build-Flutter $Target
    }
}
