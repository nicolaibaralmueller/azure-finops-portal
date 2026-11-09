#requires -Version 7.2
<#
.SYNOPSIS
    Runs the offline test suite: a PowerShell parse check over the Function App, Setup and
    Tools scripts, then every Tests/*.Tests.ps1 file. Nothing here calls Azure or an AI provider.

.EXAMPLE
    pwsh ./Tests/Invoke-OfflineTests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = 0

Write-Host "==> Parse check" -ForegroundColor Cyan
$files = @(Get-ChildItem -Path (Join-Path $root 'src/function-app'), (Join-Path $root 'Setup'), (Join-Path $root 'Tools'), (Join-Path $root 'Tests') -Recurse -Include *.ps1, *.psm1) +
         @(Get-Item (Join-Path $root 'deploy.ps1'))
foreach ($f in $files) {
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
    foreach ($e in @($errs)) { $failed++; Write-Host "  $($f.Name):$($e.Extent.StartLineNumber) $($e.Message)" -ForegroundColor Red }
}
Write-Host "  $($files.Count) file(s) parsed."

# Each test file runs in its own process: they replace global functions with stubs.
foreach ($t in @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name)) {
    Write-Host "==> $($t.Name)" -ForegroundColor Cyan
    & pwsh -NoProfile -File $t.FullName
    if ($LASTEXITCODE -ne 0) { $failed++ }
}

# The portal's static server is plain Node, tested with Node's built-in runner.
$nodeTests = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.test.mjs' | Sort-Object Name)
if ($nodeTests.Count) {
    if (Get-Command node -ErrorAction SilentlyContinue) {
        Write-Host "==> node --test ($($nodeTests.Count) file(s))" -ForegroundColor Cyan
        & node --test @($nodeTests.FullName)
        if ($LASTEXITCODE -ne 0) { $failed++ }
    } else {
        Write-Host "==> node not found — skipping $($nodeTests.Count) Node test file(s)" -ForegroundColor Yellow
    }
}

if ($failed) {
    Write-Host "Offline tests FAILED ($failed problem(s))." -ForegroundColor Red
    exit 1
}
Write-Host "Offline tests passed." -ForegroundColor Green
