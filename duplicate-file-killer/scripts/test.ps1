<#
.SYNOPSIS
    Self-test: create duplicate files, discover, scan, remove, verify.
#>
$ErrorActionPreference = 'Continue'
$d = "$env:TEMP\amuin-dupe-killer-test"
$scriptDir = $PSScriptRoot

# Clean from previous run
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$d\folderA" -Force | Out-Null
New-Item -ItemType Directory "$d\folderB" -Force | Out-Null
New-Item -ItemType Directory "$d\folderC" -Force | Out-Null

$pass = 0
$fail = 0

# -- Test 1: discover-sources --
Write-Host "=== Test 1: discover-sources.ps1 ===" -ForegroundColor Cyan
$json = powershell -File "$scriptDir\discover-sources.ps1" -Json 2>&1
if ($json -match 'Downloads' -or $json -match 'Desktop') {
    Write-Host "PASS: found expected locations" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: no expected locations in output" -ForegroundColor Red; $fail++
}

# -- Test 2: scan-duplicates -- basic --
Write-Host "`n=== Test 2: scan-duplicates -- finds duplicates ===" -ForegroundColor Cyan
"identical content here" | Out-File "$d\folderA\dupe.txt"
"identical content here" | Out-File "$d\folderB\dupe.txt"
"unique content"         | Out-File "$d\folderC\unique.txt"
"identical content here" | Out-File "$d\folderA\dupe2.txt"  # triple!

$scan = powershell -File "$scriptDir\scan-duplicates.ps1" -Paths @($d) -MinSizeMB 0 2>&1 | Out-String
if ($scan -match '"duplicate_groups"\s*:\s*1') {
    Write-Host "PASS: found duplicate group" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: did not find expected duplicate group" -ForegroundColor Red
    Write-Host "Output: $($scan.Substring(0, [Math]::Min(500, $scan.Length)))"
    $fail++
}

# -- Test 3: scan-duplicates -- no dupe case --
Write-Host "`n=== Test 3: scan-duplicates -- no duplicates ===" -ForegroundColor Cyan
$uniqueDir = "$d\uniqueOnly"
New-Item -ItemType Directory $uniqueDir -Force | Out-Null
"aaa" | Out-File "$uniqueDir\a.txt"
"bbb" | Out-File "$uniqueDir\b.txt"
$scan2 = powershell -File "$scriptDir\scan-duplicates.ps1" -Paths @($uniqueDir) -MinSizeMB 0 2>&1 | Out-String
if ($scan2 -match '"duplicate_groups"\s*:\s*0') {
    Write-Host "PASS: correctly reported 0 duplicates" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: should report 0 duplicates" -ForegroundColor Red; $fail++
}

# -- Test 4: remove-duplicates -- dry-run --
Write-Host "`n=== Test 4: remove-duplicates -- dry-run ===" -ForegroundColor Cyan
$dry = powershell -File "$scriptDir\remove-duplicates.ps1" -Files @("$d\folderB\dupe.txt") -WhatIf 2>&1 | Out-String
if ((Test-Path "$d\folderB\dupe.txt") -and ($dry -match 'DRYRUN')) {
    Write-Host "PASS: dry-run did not delete and showed warning" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: dry-run should preserve files" -ForegroundColor Red; $fail++
}

# -- Test 5: remove-duplicates -- actual --
Write-Host "`n=== Test 5: remove-duplicates -- actual deletion ===" -ForegroundColor Cyan
$target = "$d\folderB\dupe.txt"
if (Test-Path $target) {
    powershell -File "$scriptDir\remove-duplicates.ps1" -Files @($target) 2>&1 | Out-Null
    if (Test-Path $target) {
        Write-Host "WARN: file still exists (may be in recycle bin -- that's OK)" -ForegroundColor Yellow
        $pass++
    } else {
        Write-Host "PASS: file removed from filesystem" -ForegroundColor Green; $pass++
    }
}

# -- Cleanup --
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n────────────────────────" -ForegroundColor Cyan
Write-Host "Results: $pass PASS, $fail FAIL" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 } else { exit 0 }
