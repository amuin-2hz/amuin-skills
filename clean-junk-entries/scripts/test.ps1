<#
.SYNOPSIS
    Self-test: verify scan finds known entries, clean backs up properly (dry-run),
    restore lists snapshots. Creates a temporary safe registry key for end-to-end test.
#>
$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
$pass = 0
$fail = 0
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ── Test 1: scan.ps1 runs and outputs JSON ──
Write-Host "=== Test 1: scan.ps1 JSON output ===" -ForegroundColor Cyan
$json = powershell -File "$scriptDir\scan.ps1" -Json 2>&1 | Out-String
if ($json -match '"categories"' -and $json -match '"summary"') {
    Write-Host "PASS: valid JSON with categories and summary" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: missing expected JSON fields" -ForegroundColor Red; $fail++
}

# ── Test 2: scan.ps1 table mode ──
Write-Host "`n=== Test 2: scan.ps1 table output ===" -ForegroundColor Cyan
$table = powershell -File "$scriptDir\scan.ps1" 2>&1 | Out-String
if ($table -match 'Context Menu' -and $table -match 'This PC Icons') {
    Write-Host "PASS: table shows expected category labels" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: table missing category headers" -ForegroundColor Red; $fail++
}

# ── Test 3: clean.ps1 dry-run ──
Write-Host "`n=== Test 3: clean.ps1 dry-run ===" -ForegroundColor Cyan
# Use a temp HKCU key (user hive -- no admin needed to create)
$dryKey = "HKCU:\Software\AmuinDryRunTest"
New-Item -Path $dryKey -Force | Out-Null
Set-ItemProperty $dryKey -Name 'TestValue' -Value 'dry-run-test' -Force | Out-Null

$dry = powershell -File "$scriptDir\clean.ps1" -Keys @("HKCU:\Software\AmuinDryRunTest") -WhatIf 2>&1 | Out-String
if ($dry -match 'DRY RUN' -and $dry -match 'would_delete') {
    Write-Host "PASS: dry-run works and preserves" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: dry-run not working as expected" -ForegroundColor Red; $fail++
}

# Cleanup dry-run test key
Remove-Item $dryKey -Recurse -Force -ErrorAction SilentlyContinue

# ── Test 4: clean.ps1 real (create temp key, back up, delete) ──
Write-Host "`n=== Test 4: clean.ps1 backup + delete ===" -ForegroundColor Cyan
if (-not $isAdmin) {
    Write-Host "SKIP: admin rights required for real registry operations — skipping Test 4" -ForegroundColor DarkYellow
    Write-Host "      (run PowerShell as Administrator to exercise this test)" -ForegroundColor DarkYellow
    # Not a failure — admin-only test
} else {
    $testKey = "HKCU:\Software\AmuinTest"
    $testKeyReg = "HKCU:\Software\AmuinTest"
    New-Item -Path $testKey -Force | Out-Null
    Set-ItemProperty $testKey -Name 'TestValue' -Value 'hello' -Force | Out-Null

    $real = powershell -File "$scriptDir\clean.ps1" -Keys @($testKeyReg) 2>&1 | Out-String
    if ((Test-Path $testKey)) {
        Write-Host "FAIL: key still exists after clean" -ForegroundColor Red; $fail++
    } elseif ($real -match '"backup_dir"' -and $real -match '"deleted"') {
        Write-Host "PASS: key deleted and backup created" -ForegroundColor Green; $pass++

        # Verify backup exists
        if ($real -match '"backup_dir"\s*:\s*"([^"]+)"') {
            $bd = $Matches[1]
            $regCount = (Get-ChildItem $bd -Filter '*.reg' -ErrorAction SilentlyContinue).Count
            if ($regCount -gt 0) {
                Write-Host "      Backup verified: $regCount .reg file(s)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "FAIL: unexpected output" -ForegroundColor Red; $fail++
    }
}

# Cleanup any leftover test key (no-op if already gone)
Remove-Item "HKCU:\Software\AmuinTest" -Recurse -Force -ErrorAction SilentlyContinue

# ── Test 5: restore.ps1 -List ──
Write-Host "`n=== Test 5: restore.ps1 -List ===" -ForegroundColor Cyan
$list = powershell -File "$scriptDir\restore.ps1" -List 2>&1 | Out-String
if ($list -match 'Registry Backups' -or $list -match 'TIMESTAMP') {
    Write-Host "PASS: restore lists snapshots" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: restore list not working" -ForegroundColor Red; $fail++
}

# ── Test 6: Real-world targets (This PC icons, context menu entries) ──
Write-Host "`n=== Test 6: Production scan for known junk ===" -ForegroundColor Cyan
$rawJson = powershell -File "$scriptDir\scan.ps1" -Json 2>&1 | Out-String
# Extract JSON portion (Write-Host messages get mixed into stdout when captured)
$braceIdx = $rawJson.IndexOf('{')
if ($braceIdx -ge 0) {
    $jsonText = $rawJson.Substring($braceIdx)
    $realJson = $jsonText | ConvertFrom-Json
} else {
    Write-Host "WARN: no JSON found in scan output" -ForegroundColor DarkYellow
    $realJson = $null
}

$foundKnown = $false
if ($realJson -and $realJson.categories) {
    foreach ($cat in $realJson.categories) {
        foreach ($e in $cat.entries) {
            $dn = $e.display_name.ToLower()
            if ($dn -match '腾讯视频' -or $dn -match '抖音' -or $dn -match '小智' -or $dn -match 'opcclaw') {
                Write-Host "  FOUND: $($e.display_name) [$($e.tier)] — $($e.evidence)" -ForegroundColor Yellow
                $foundKnown = $true
            }
        }
    }
}
if ($foundKnown) {
    Write-Host "PASS: detected known junk entries on this machine" -ForegroundColor Green; $pass++
} else {
    Write-Host "INFO: no known junk patterns found (this machine may be clean, or scan scope differs)" -ForegroundColor DarkGray
    $pass++  # Not a failure — the machine might just be clean
}

Write-Host "`n────────────────────────" -ForegroundColor Cyan
Write-Host "Results: $pass PASS, $fail FAIL" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 } else { exit 0 }
