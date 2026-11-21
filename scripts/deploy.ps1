<#
.SYNOPSIS
  Builds the RoboVolunteers Flutter Web app and/or Auth OTP Worker, then deploys to Cloudflare Workers with Static Assets.
.PARAMETER SkipBuild
  Skips all builds and deploys directly using existing artifacts.
.PARAMETER SkipWebBuild
  Skips the Flutter web build (uses existing app/build/web).
.PARAMETER SkipWorkerCheck
  Skips worker typecheck and unit tests.
.PARAMETER DeployWorker
  Also deploys the Auth OTP Cloudflare Worker (workers/auth-otp).
.PARAMETER DeployFirestore
  Deploys Cloud Firestore Security Rules and Indexes using firebase-tools.
.PARAMETER DryRun
  Runs deployment in dry-run mode without publishing live.
.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -DryRun
  .\scripts\deploy.ps1 -DeployWorker
  .\scripts\deploy.ps1 -DeployWorker -DeployFirestore
  .\scripts\deploy.ps1 -SkipWebBuild
#>
param (
    [switch]$SkipBuild,
    [switch]$SkipWebBuild,
    [switch]$SkipWorkerCheck,
    [switch]$DeployWorker,
    [switch]$DeployFirestore,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$rootDir = Join-Path $PSScriptRoot ".."
$workerDir = Join-Path $rootDir "workers\auth-otp"

# Step 1: Worker verification / test
if (-not $SkipBuild -and -not $SkipWorkerCheck) {
    Write-Host ">>> Step 1/3: Verifying & Testing Auth OTP Worker..." -ForegroundColor Cyan
    & "$PSScriptRoot\build.ps1" worker
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Worker verification failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} else {
    Write-Host ">>> Step 1/3: Skipping worker check..." -ForegroundColor Yellow
}

# Optional: Deploy Worker if requested
if ($DeployWorker) {
    Write-Host "`n>>> Deploying Auth OTP Worker to Cloudflare..." -ForegroundColor Cyan
    Push-Location $workerDir
    try {
        $workerDeployArgs = @("deploy")
        if ($DryRun) { $workerDeployArgs += "--dry-run" }
        npx wrangler @workerDeployArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Auth OTP Worker deployment failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
}

# Step 2: Flutter Web PWA build
if (-not $SkipBuild -and -not $SkipWebBuild) {
    Write-Host "`n>>> Step 2/3: Building Flutter Web PWA (WASM + CanvasKit fallback)..." -ForegroundColor Cyan
    & "$PSScriptRoot\build.ps1" web
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Flutter web build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} else {
    Write-Host "`n>>> Step 2/3: Skipping web build (using existing app/build/web)..." -ForegroundColor Yellow
}

# Step 3: Cloudflare deployment (Web Static Assets)
Write-Host "`n>>> Step 3/3: Deploying Web Assets to Cloudflare..." -ForegroundColor Cyan
Push-Location $rootDir
try {
    $deployArgs = @("deploy", "--config", "wrangler.jsonc")
    if ($DryRun) { $deployArgs += "--dry-run" }
    npx wrangler @deployArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Cloudflare web deployment failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

# Step 4 (Optional): Firebase Firestore Rules & Indexes
if ($DeployFirestore) {
    Write-Host "`n>>> Step 4: Deploying Cloud Firestore Rules & Indexes to Firebase..." -ForegroundColor Cyan
    Push-Location $rootDir
    try {
        npx -y firebase-tools@latest deploy --only firestore
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Firebase Firestore deployment failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Deployment completed successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
