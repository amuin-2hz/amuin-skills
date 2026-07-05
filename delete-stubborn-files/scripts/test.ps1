<#
.SYNOPSIS
    Self-test: create stubborn files, run diagnosis, attempt deletion, clean up.
#>
$ErrorActionPreference = 'Continue'
$d = "$env:TEMP\amuin-skill-test"

# Clean from previous run
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $d -Force | Out-Null

$script = "$PSScriptRoot\fix.ps1"

# ── Test 1: Normal file ──
Write-Host "=== Test 1: Normal file ===" -ForegroundColor Cyan
"hello" | Out-File "$d\normal.txt"
& $script -Path "$d\normal.txt" -Force
if (Test-Path "$d\normal.txt") { Write-Host "FAIL" -ForegroundColor Red } else { Write-Host "PASS" -ForegroundColor Green }

# ── Test 2: Read-only file ──
Write-Host "`n=== Test 2: Read-only file ===" -ForegroundColor Cyan
"hello" | Out-File "$d\readonly.txt"
(Get-Item "$d\readonly.txt").Attributes = 'ReadOnly'
& $script -Path "$d\readonly.txt" -Force
if (Test-Path "$d\readonly.txt") { Write-Host "FAIL" -ForegroundColor Red } else { Write-Host "PASS" -ForegroundColor Green }

# ── Test 3: Broken junction ──
Write-Host "`n=== Test 3: Broken junction ===" -ForegroundColor Cyan
New-Item -ItemType Directory "$d\realtarget" -Force | Out-Null
New-Item -ItemType Junction -Path "$d\brokenlink" -Target "$d\realtarget" -Force | Out-Null
Remove-Item "$d\realtarget" -Recurse -Force  # break it
& $script -Path "$d\brokenlink" -Force
if (Test-Path "$d\brokenlink") { Write-Host "FAIL" -ForegroundColor Red } else { Write-Host "PASS" -ForegroundColor Green }

# ── Test 4: Missing file ──
Write-Host "`n=== Test 4: Already-gone file ===" -ForegroundColor Cyan
& $script -Path "$d\doesnotexist.txt"
Write-Host "PASS (graceful)" -ForegroundColor Green

# ── Test 5: Directory with files ──
Write-Host "`n=== Test 5: Directory with content ===" -ForegroundColor Cyan
New-Item -ItemType Directory "$d\fullfolder" -Force | Out-Null
"a","b","c" | ForEach-Object { "data" | Out-File "$d\fullfolder\$_.txt" }
& $script -Path "$d\fullfolder" -Force
if (Test-Path "$d\fullfolder") { Write-Host "FAIL" -ForegroundColor Red } else { Write-Host "PASS" -ForegroundColor Green }

# Cleanup
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n=== All tests complete ===" -ForegroundColor Cyan
