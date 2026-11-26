<#
.SYNOPSIS
  Builds the RoboVolunteers Flutter Web app and/or Auth OTP Worker, deploys to Cloudflare Workers with Static Assets, and deploys Cloud Firestore Security Rules & Indexes.
.PARAMETER Env
  Target deployment environment: live (default) or test.
.PARAMETER SkipBuild
  Skips all builds and deploys directly using existing artifacts.
.PARAMETER SkipWebBuild
  Skips the Flutter web build (uses existing app/build/web).
.PARAMETER SkipWorkerCheck
  Skips worker typecheck and unit tests.
.PARAMETER DeployWorker
  Also deploys the Auth OTP Cloudflare Worker (workers/auth-otp).
.PARAMETER DeployFirestore
  Explicitly enables deploying Cloud Firestore Security Rules and Indexes (enabled by default).
.PARAMETER SkipFirestore
  Skips deploying Cloud Firestore Security Rules and Indexes.
.PARAMETER DryRun
  Runs deployment in dry-run mode without publishing live.
.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -Env live -DeployWorker
  .\scripts\deploy.ps1 -Env test -DeployWorker
  .\scripts\deploy.ps1 -DryRun
  .\scripts\deploy.ps1 -DeployWorker
  .\scripts\deploy.ps1 -SkipFirestore
  .\scripts\deploy.ps1 -SkipWebBuild
#>
param (
    [ValidateSet("live", "test")]
    [string]$Env = "live",
    [switch]$SkipBuild,
    [switch]$SkipWebBuild,
    [switch]$SkipWorkerCheck,
    [switch]$DeployWorker,
    [switch]$DeployFirestore,
    [switch]$SkipFirestore,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$rootDir = Join-Path $PSScriptRoot ".."
$workerDir = Join-Path $rootDir "workers\auth-otp"
$firebaseProjectAlias = if ($Env -eq "test") { "test" } else { "default" }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Deploying RoboVolunteers [$Env]" -ForegroundColor Cyan
if ($Env -eq "test") {
    Write-Host " Web Worker:   robovolunteers-test (test.robovolunteers.link)" -ForegroundColor Yellow
    Write-Host " Auth Worker:  robovolunteers-auth-otp-test" -ForegroundColor Yellow
    Write-Host " Firebase:     $firebaseProjectAlias (robovolunteers-test)" -ForegroundColor Yellow
} else {
    Write-Host " Web Worker:   roboref-volunteer-hub (robovolunteers.link)" -ForegroundColor Yellow
    Write-Host " Auth Worker:  roboref-volunteer-auth-otp" -ForegroundColor Yellow
    Write-Host " Firebase:     $firebaseProjectAlias (volunteer-wrangler)" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan

# Step 1: Worker verification / test
if (-not $SkipBuild -and -not $SkipWorkerCheck) {
    Write-Host ">>> Step 1/4: Verifying & Testing Auth OTP Worker..." -ForegroundColor Cyan
    & "$PSScriptRoot\build.ps1" -Target worker -Env $Env
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Worker verification failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} else {
    Write-Host ">>> Step 1/4: Skipping worker check..." -ForegroundColor Yellow
}

# Optional: Deploy Worker if requested
if ($DeployWorker) {
    Write-Host "`n>>> Deploying Auth OTP Worker [$Env] to Cloudflare..." -ForegroundColor Cyan
    Push-Location $workerDir
    try {
        $workerDeployArgs = @("deploy")
        if ($Env -eq "test") { $workerDeployArgs += @("--env", "test") }
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
    Write-Host "`n>>> Step 2/4: Building Flutter Web PWA [$Env] (WASM + CanvasKit fallback)..." -ForegroundColor Cyan
    & "$PSScriptRoot\build.ps1" -Target web -Env $Env
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Flutter web build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} else {
    Write-Host "`n>>> Step 2/4: Skipping web build (using existing app/build/web)..." -ForegroundColor Yellow
}

# Step 3: Cloudflare deployment (Web Static Assets)
Write-Host "`n>>> Step 3/4: Deploying Web Assets [$Env] to Cloudflare..." -ForegroundColor Cyan
Push-Location $rootDir
try {
    $deployArgs = @("deploy", "--config", "wrangler.jsonc")
    if ($Env -eq "test") { $deployArgs += @("--env", "test") }
    if ($DryRun) { $deployArgs += "--dry-run" }
    npx wrangler @deployArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Cloudflare web deployment failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

# Step 4: Firebase Firestore Rules & Indexes (enabled by default; pass -SkipFirestore to skip)
if (-not $SkipFirestore -or $DeployFirestore) {
    Write-Host "`n>>> Step 4/4: Deploying Cloud Firestore Rules & Indexes to Firebase ($firebaseProjectAlias)..." -ForegroundColor Cyan
    Push-Location $rootDir
    try {
        $firestoreDeployArgs = @("-y", "firebase-tools@latest", "deploy", "--only", "firestore", "--project", $firebaseProjectAlias)
        if ($DryRun) { $firestoreDeployArgs += "--dry-run" }
        npx @firestoreDeployArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Firebase Firestore deployment failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "`n>>> Step 4/4: Skipping Cloud Firestore Rules & Indexes deployment..." -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Deployment [$Env] completed successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
