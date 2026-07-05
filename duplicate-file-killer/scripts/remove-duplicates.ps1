<#
.SYNOPSIS
    Move files to Recycle Bin (or delete permanently with -Permanent).
    Reports results per-file. Safe by default.
#>
param(
    [Parameter(Mandatory)]
    [string[]] $Files,

    [switch] $WhatIf,
    [switch] $Permanent
)

$ErrorActionPreference = 'Continue'

if ($WhatIf) {
    Write-Host "`n  DRY RUN — nothing will be deleted.`n" -ForegroundColor Cyan
}

# ── Recycle Bin via Shell.Application COM ──
function Move-ToRecycleBin($path) {
    if ($WhatIf) {
        Write-Host "    [DRYRUN] Would recycle: $path" -ForegroundColor DarkGray
        return @{ success = $true; method = 'recycle-bin' }
    }
    try {
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.NameSpace(0).ParseName($path)  # 0 = desktop (recycle bin namespace)
        if ($item) {
            $item.InvokeVerb('delete')
            Start-Sleep -Milliseconds 200
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
            if (-not (Test-Path $path)) {
                return @{ success = $true; method = 'recycle-bin' }
            }
        }
    } catch {}
    return @{ success = $false; method = 'recycle-bin'; error = 'Shell COM failed' }
}

function Remove-Permanent($path) {
    if ($WhatIf) {
        Write-Host "    [DRYRUN] Would permanently delete: $path" -ForegroundColor Yellow
        return @{ success = $true; method = 'permanent' }
    }
    try {
        Remove-Item $path -Force -Recurse -ErrorAction Stop
        return @{ success = $true; method = 'permanent' }
    } catch {
        return @{ success = $false; method = 'permanent'; error = $_.Exception.Message }
    }
}

Write-Host "`n  Removing $($Files.Count) file(s)..." -ForegroundColor Cyan
$mode = if ($Permanent) { 'PERMANENT' } else { 'RECYCLE BIN' }
Write-Host "  Mode: $mode`n"

$results = @()
$freed = 0L
$deleted = 0
$failed = 0

foreach ($f in $Files) {
    if (-not (Test-Path $f)) {
        Write-Host "  [SKIP] Already gone: $f" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{ Path=$f; Status='already_gone'; FreedBytes=0; Error='' }
        continue
    }

    $size = try { (Get-Item $f).Length } catch { 0 }
    $result = if ($Permanent) { Remove-Permanent $f } else { Move-ToRecycleBin $f }

    if ($result.success) {
        $deleted++
        $freed += $size
        Write-Host "  [OK]   $f" -ForegroundColor Green
        $results += [PSCustomObject]@{ Path=$f; Status='deleted'; FreedBytes=$size; Error='' }
    } else {
        $failed++
        Write-Host "  [FAIL] $f — $($result.error)" -ForegroundColor Red
        $results += [PSCustomObject]@{ Path=$f; Status='failed'; FreedBytes=0; Error=$result.error }
    }
}

Write-Host "`n  ───────────────────────────" -ForegroundColor DarkGray
Write-Host "  Deleted : $deleted" -ForegroundColor Green
Write-Host "  Failed  : $failed"  -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'DarkGray' })
Write-Host "  Freed   : $([math]::Round($freed / 1MB, 1)) MB" -ForegroundColor Yellow
if (-not $Permanent -and -not $WhatIf) {
    Write-Host "  ℹ Files are in Recycle Bin — empty it to permanently free space." -ForegroundColor Cyan
}
Write-Host ""
if ($failed -gt 0) { exit 1 } else { exit 0 }

# Output JSON for agent consumption
$results | ConvertTo-Json -Depth 2 -Compress
