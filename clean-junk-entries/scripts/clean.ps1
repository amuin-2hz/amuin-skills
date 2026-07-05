<#
.SYNOPSIS
    Safely delete registry keys: export .reg backup → delete → verify.
    Each key backed up before deletion. Batch restore supported.
#>
param(
    [Parameter(Mandatory)]
    [string[]] $Keys,

    [switch] $WhatIf,
    [switch] $AlsoDeleteCLSID   # If a key contains a CLSID in its path, also delete HKCR:\CLSID\{...}
)

$ErrorActionPreference = 'Continue'

# ── Admin check (skip for dry-run) ──
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIf) {
    Write-Host "  [INFO] Admin rights required. Requesting elevation..." -ForegroundColor Yellow

    # Rebuild argument list for self-elevation
    $argList = @()
    $argList += '-NoProfile'
    $argList += '-File'
    $argList += "`"$PSCommandPath`""
    foreach ($k in $Keys) {
        $argList += "-Keys"
        $argList += "`"$k`""
    }
    if ($WhatIf)   { $argList += '-WhatIf' }
    if ($AlsoDeleteCLSID) { $argList += '-AlsoDeleteCLSID' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = $argList -join ' '
    $psi.Verb = 'RunAs'
    $psi.UseShellExecute = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        exit $proc.ExitCode
    } catch {
        Write-Host "  [ERROR] Failed to elevate: $_" -ForegroundColor Red
        Write-Host "  Run PowerShell as Administrator and try again." -ForegroundColor Yellow
        exit 1
    }
}

# ── Create backup directory ──
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$backupRoot = "$env:USERPROFILE\Amuin\backups\clean-junk-entries"
$backupDir = Join-Path $backupRoot $timestamp

if ($WhatIf) {
    Write-Host "`n  DRY RUN — nothing will be deleted.`n" -ForegroundColor Cyan
}

if (-not $WhatIf) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

Write-Host "`n  Cleaning $($Keys.Count) registry key(s)..." -ForegroundColor Cyan
Write-Host "  Mode    : $(if ($WhatIf) { 'DRY RUN' } else { 'LIVE' })"
Write-Host "  Backup  : $backupDir`n"

$results = @()
$deleted = 0
$failed = 0
$manifestEntries = @()

foreach ($key in $Keys) {
    $regKey = $key -replace '^Registry::', ''

    # Also collect associated CLSID if applicable
    $clsidKeys = @()
    if ($AlsoDeleteCLSID) {
        if ($regKey -match '(\{[A-Fa-f0-9\-]+\})') {
            $clsidKeys += "HKCR:\CLSID\$($Matches[1])"
        }
        # Check if the key itself has a (default) value that is a CLSID
        try {
            $defVal = (Get-ItemProperty $regKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
            if ($defVal -and $defVal -match '^\{[A-Fa-f0-9\-]+\}$') {
                $clsidKeys += "HKCR:\CLSID\$defVal"
            }
        } catch {}
    }

    $allTargets = @($regKey) + $clsidKeys

    foreach ($target in $allTargets) {
        if (-not (Test-Path $target)) {
            $results += [PSCustomObject]@{ key = $target; status = 'already_gone'; backup_reg = ''; error = '' }
            continue
        }

        # ── Export backup ──
        $safeName = $target -replace '[\\:\*\?\"<>|]', '_' -replace '^_+', ''
        $backupFile = Join-Path $backupDir "$safeName.reg"

        if (-not $WhatIf) {
            try {
                $exportArgs = "export `"$target`" `"$backupFile`" /y"
                $result = reg $exportArgs 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $results += [PSCustomObject]@{ key = $target; status = 'backup_failed'; backup_reg = ''; error = "reg export failed: $result" }
                    $failed++
                    continue
                }
            } catch {
                $results += [PSCustomObject]@{ key = $target; status = 'backup_failed'; backup_reg = ''; error = $_.Exception.Message }
                $failed++
                continue
            }

            # ── Delete ──
            try {
                Remove-Item $target -Recurse -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 100
                if (Test-Path $target) {
                    $results += [PSCustomObject]@{ key = $target; status = 'delete_failed'; backup_reg = $backupFile; error = 'Key still exists after delete attempt' }
                    $failed++
                    continue
                }
            } catch {
                $results += [PSCustomObject]@{ key = $target; status = 'delete_failed'; backup_reg = $backupFile; error = $_.Exception.Message }
                $failed++
                continue
            }

            $deleted++
            $results += [PSCustomObject]@{ key = $target; status = 'deleted'; backup_reg = $backupFile; error = '' }
            Write-Host "  [OK]  $target" -ForegroundColor Green

            $manifestEntries += [PSCustomObject]@{
                key        = $target
                backup_reg = $safeName + '.reg'
                timestamp  = $timestamp
            }
        } else {
            Write-Host "  [DRY] $target" -ForegroundColor DarkGray
            $results += [PSCustomObject]@{ key = $target; status = 'would_delete'; backup_reg = ''; error = '' }
        }
    }
}

# ── Write manifest ──
$manifest = [PSCustomObject]@{
    timestamp    = $timestamp
    total_keys   = $Keys.Count
    deleted      = $deleted
    failed       = $failed
    entries      = $manifestEntries
}

if (-not $WhatIf) {
    $manifestPath = Join-Path $backupDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 4 | Out-File $manifestPath -Encoding UTF8
}

# ── Write restore helper ──
if (-not $WhatIf) {
    $restoreScript = Join-Path $backupDir 'restore.cmd'
    @"
@echo off
echo Restoring registry keys from backup: $timestamp
echo.
for %%%%f in ("$backupDir\*.reg") do (
    echo Importing: %%%%~nxf
    reg import "%%%%f"
)
echo.
echo Restore complete. Press any key to exit.
pause >nul
"@ | Out-File $restoreScript -Encoding ASCII
}

# ── Report ──
Write-Host "`n  ───────────────────────────" -ForegroundColor DarkGray
Write-Host "  Deleted : $deleted"  -ForegroundColor Green
Write-Host "  Failed  : $failed"   -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'DarkGray' })
Write-Host "  Backup  : $backupDir" -ForegroundColor Cyan
Write-Host "  Restore : Run restore.cmd in the backup folder" -ForegroundColor Cyan
Write-Host ""

# JSON output for agent
$output = [PSCustomObject]@{
    results       = $results
    backup_dir    = $backupDir
    total_deleted = $deleted
    total_failed  = $failed
}
Write-Output ($output | ConvertTo-Json -Depth 3 -Compress)

if ($failed -gt 0) { exit 1 } else { exit 0 }
