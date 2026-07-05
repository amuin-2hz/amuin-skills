<#
.SYNOPSIS
    List and restore registry backups created by clean.ps1.
    Lists snapshots with -List; restores a specific snapshot with -Restore.
#>
param(
    [switch] $List,
    [string] $Restore
)

$ErrorActionPreference = 'Stop'
$backupRoot = "$env:USERPROFILE\Amuin\backups\clean-junk-entries"

if (-not (Test-Path $backupRoot)) {
    Write-Host "  No backups found at $backupRoot" -ForegroundColor Yellow
    exit 0
}

if ($List -or (-not $List -and -not $Restore)) {
    # List mode (default when no args)
    Write-Host "`n  Registry Backups`n" -ForegroundColor Cyan

    $snapshots = Get-ChildItem $backupRoot -Directory | Sort-Object Name -Descending

    if ($snapshots.Count -eq 0) {
        Write-Host "  No snapshots found." -ForegroundColor DarkGray
        exit 0
    }

    $header = "{0,-22} {1,8} {2,8} {3}" -f 'TIMESTAMP', 'KEYS', 'REGS', 'PATH'
    Write-Host $header
    Write-Host ('-' * 70)

    foreach ($snap in $snapshots) {
        $manifestPath = Join-Path $snap.FullName 'manifest.json'
        $keyCount = 0
        $regCount = (Get-ChildItem $snap.FullName -Filter '*.reg' -ErrorAction SilentlyContinue).Count
        if (Test-Path $manifestPath) {
            try {
                $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
                $keyCount = $m.deleted
            } catch {}
        }
        Write-Host ("{0,-22} {1,8} {2,8} {3}" -f $snap.Name, $keyCount, $regCount, $snap.FullName)
    }
    Write-Host ('-' * 70)

    Write-Host "`n  To restore: powershell -File scripts/restore.ps1 -Restore '<timestamp>'" -ForegroundColor Cyan
    exit 0
}

if ($Restore) {
    # Restore mode
    $restoreDir = Join-Path $backupRoot $Restore
    if (-not (Test-Path $restoreDir)) {
        Write-Host "  [ERROR] Snapshot not found: $restoreDir" -ForegroundColor Red
        Write-Host "  Use -List to see available snapshots." -ForegroundColor Yellow
        exit 1
    }

    $regFiles = Get-ChildItem $restoreDir -Filter '*.reg' -ErrorAction SilentlyContinue
    if ($regFiles.Count -eq 0) {
        Write-Host "  No .reg files found in $restoreDir" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "`n  Restoring $($regFiles.Count) registry keys from: $Restore`n" -ForegroundColor Cyan

    $success = 0
    $failures = 0

    foreach ($rf in $regFiles) {
        Write-Host "  Importing: $($rf.Name)" -ForegroundColor White
        try {
            $result = reg import "`"$($rf.FullName)`"" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    [OK]  Imported" -ForegroundColor Green
                $success++
            } else {
                Write-Host "    [FAIL] $result" -ForegroundColor Red
                $failures++
            }
        } catch {
            Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red
            $failures++
        }
    }

    Write-Host "`n  ───────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Imported: $success" -ForegroundColor Green
    Write-Host "  Failed  : $failures" -ForegroundColor $(if ($failures -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Host ""

    if ($failures -gt 0) { exit 1 } else { exit 0 }
}
