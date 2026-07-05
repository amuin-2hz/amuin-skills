<#
.SYNOPSIS
    Diagnose and fix stubborn files/folders that refuse to delete on Windows.
    Run without -Force to diagnose only. Use -Force to attempt deletion.
#>
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string] $Path,

    [switch] $Force        # Actually delete (without = diagnose only)
)

$ErrorActionPreference = 'Stop'
$Path = $Path.Trim()

# ── Helpers ──
function Test-IsJunction($p) {
    try { return (Get-Item $p -Force -ErrorAction Stop).LinkType -eq 'Junction' }
    catch { return $false }
}

function Test-IsReservedName($name) {
    $reserved = @('CON','PRN','AUX','NUL',
                  'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
                  'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
    return $base -in $reserved
}

function Test-HasTrailingSpaceOrDot($p) {
    $name = Split-Path $p -Leaf
    return ($name[-1] -eq ' ' -or $name[-1] -eq '.')
}

function Test-IsPathTooLong($p) {
    return ($p.Length -gt 258)
}

function Find-LockingProcess($p) {
    try {
        $handle = Join-Path $PSScriptRoot 'handle64.exe'
        if (-not (Test-Path $handle)) { return $null }
        $result = & $handle -nobanner -accepteula $p 2>$null
        if ($LASTEXITCODE -eq 0 -and $result) {
            return [regex]::Matches($result, 'pid:\s*(\d+)') | ForEach-Object { $_.Groups[1].Value }
        }
    } catch {}
    return $null
}

# ── Diagnosis ──
Write-Host "`n  Stubborn File Diagnosis" -ForegroundColor Cyan
Write-Host "  Path: $Path`n" -ForegroundColor White

$issues = @()
$level  = @()  # 'info' | 'warn' | 'error'

# 1. Does it exist?
$exists = Test-Path $Path
if (-not $exists) {
    Write-Host "  [OK]  File does not exist (already gone?)" -ForegroundColor Green
    exit 0
}

# 2. Attributes
try {
    $item = Get-Item $Path -Force -ErrorAction Stop
    Write-Host "  [INFO] Type  : $($item.Attributes)" -ForegroundColor DarkGray
    Write-Host "  [INFO] Mode  : $($item.Mode)" -ForegroundColor DarkGray

    if ($item.Attributes -match 'ReadOnly') {
        $issues += 'Read-only attribute set'
        $level  += 'warn'
    }
    if ($item.Attributes -match 'Hidden') {
        $issues += 'Hidden attribute set (not a blocker, but noted)'
        $level  += 'info'
    }
} catch {
    Write-Host "  [WARN] Cannot read attributes: $_" -ForegroundColor Yellow
    $issues += "Cannot read file attributes (corrupted?)"
    $level  += 'warn'
}

# 3. Junction check
if (Test-IsJunction $Path) {
    $target = (Get-Item $Path -Force).Target | Select-Object -First 1
    $targetExists = Test-Path $target
    if (-not $targetExists) {
        $issues += "Broken junction (target missing: $target)"
        $level  += 'warn'
        Write-Host "  [WARN] Broken junction -> $target (missing)" -ForegroundColor Yellow
    } else {
        # Check for cyclic junction by quick inspection
        if ($target -eq $Path) {
            $issues += 'Cyclic junction (points to itself)'
            $level  += 'error'
            Write-Host "  [ERR]  Cyclic junction! Points to itself." -ForegroundColor Red
        } else {
            Write-Host "  [INFO] Junction -> $target" -ForegroundColor DarkGray
        }
    }
}

# 4. Reserved name
$leaf = Split-Path $Path -Leaf
if (Test-IsReservedName $leaf) {
    $issues += "Reserved Windows name: $leaf (CON, PRN, NUL, etc.)"
    $level  += 'error'
    Write-Host "  [ERR]  Reserved name: $leaf" -ForegroundColor Red
}

# 5. Trailing space/dot
if (Test-HasTrailingSpaceOrDot $Path) {
    $issues += 'Filename ends with space or dot (Windows Explorer blocks this)'
    $level  += 'error'
    Write-Host "  [ERR]  Trailing space or dot in name" -ForegroundColor Red
}

# 6. Path too long
if (Test-IsPathTooLong $Path) {
    $issues += 'Path exceeds 260 characters (MAX_PATH limit)'
    $level  += 'error'
    Write-Host "  [ERR]  Path too long ($($Path.Length) chars)" -ForegroundColor Red
}

# 7. Permission check (write test in parent directory)
$parentDir = if (Test-Path $Path -PathType Container) { $Path } else { Split-Path $Path -Parent }
if ($parentDir) {
    try {
        $testFile = Join-Path $parentDir '_amuin_delete_test_.tmp'
        Set-Content $testFile 'test' -ErrorAction Stop
        Remove-Item $testFile -ErrorAction SilentlyContinue
    } catch {
        $issues += 'Permission denied (cannot write to parent directory)'
        $level  += 'error'
        Write-Host "  [ERR]  Permission denied on parent dir" -ForegroundColor Red
    }
}

# 8. Locked by process
$pids = Find-LockingProcess $Path
if ($pids) {
    foreach ($pid in $pids) {
        try {
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc) {
                $issues += "Locked by process: $($proc.ProcessName) (PID $pid)"
                $level  += 'error'
                Write-Host "  [ERR]  Locked by $($proc.ProcessName) (PID $pid)" -ForegroundColor Red
            }
        } catch {}
    }
}

# ── Summary ──
Write-Host ""
if ($issues.Count -eq 0) {
    Write-Host "  No issues detected. Try deleting with:" -ForegroundColor Green
    Write-Host "    Remove-Item -Path '$Path' -Recurse -Force" -ForegroundColor White
} else {
    Write-Host "  Issues found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $issues.Count; $i++) {
        $color = if ($level[$i] -eq 'error') { 'Red' } else { 'Yellow' }
        Write-Host "    $($i+1). [$($level[$i])] $($issues[$i])" -ForegroundColor $color
    }
}

# ── Fix ──
if (-not $Force) {
    Write-Host "`n  Run with -Force to attempt deletion." -ForegroundColor Cyan
    Write-Host "  powershell -File scripts/fix.ps1 -Path '<path>' -Force" -ForegroundColor White
    exit 0
}

Write-Host "`n  Attempting deletion..." -ForegroundColor Cyan

# Try each weapon in escalating order
$deleted = $false

# Weapon 1: Simple force delete
try {
    Remove-Item $Path -Recurse -Force -ErrorAction Stop
    $deleted = $true
    Write-Host "  [OK] Standard delete worked" -ForegroundColor Green
} catch {}

# Weapon 2: Strip read-only/hidden then retry
if (-not $deleted) {
    try {
        $item = Get-Item $Path -Force
        $item.Attributes = 'Normal'
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
        $deleted = $true
        Write-Host "  [OK] Deleted after stripping attributes" -ForegroundColor Green
    } catch {}
}

# Weapon 3: Long path prefix (\\?\)
if (-not $deleted) {
    try {
        $longPath = "\\?\$Path"
        if (Test-Path -LiteralPath $longPath) {
            $isDir = (Get-Item -LiteralPath $longPath -Force) -is [System.IO.DirectoryInfo]
            if ($isDir) {
                # Use cmd rmdir for long paths (more reliable)
                cmd /c "rmdir /s /q `"\\?\$Path`"" 2>$null
            } else {
                [System.IO.File]::Delete($longPath)
            }
            if (-not (Test-Path $Path)) {
                $deleted = $true
                Write-Host "  [OK] Deleted via long path prefix (\\?\)" -ForegroundColor Green
            }
        }
    } catch {}
}

# Weapon 4: cmd rmdir for junctions / special cases
if (-not $deleted) {
    try {
        # rmdir without /s for junction points (important: no recursive flag!)
        if (Test-IsJunction $Path) {
            cmd /c "rmdir `"$Path`"" 2>$null
        } else {
            cmd /c "rmdir /s /q `"$Path`"" 2>$null
        }
        if (-not (Test-Path $Path)) {
            $deleted = $true
            Write-Host "  [OK] Deleted via cmd rmdir" -ForegroundColor Green
        }
    } catch {}
}

# Weapon 5: takeown + icacls then retry (needs admin)
if (-not $deleted) {
    try {
        takeown /F "$Path" /R /D Y 2>$null | Out-Null
        icacls "$Path" /grant "${env:USERNAME}:F" /T /Q 2>$null | Out-Null
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
        $deleted = $true
        Write-Host "  [OK] Deleted after taking ownership" -ForegroundColor Green
    } catch {}
}

# Final check
if (Test-Path $Path) {
    Write-Host "`n  [FAIL] Could not delete: $Path" -ForegroundColor Red
    Write-Host "  Try restarting in Safe Mode, or check for kernel-level locks." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "`n  [OK] Successfully deleted!" -ForegroundColor Green
    exit 0
}
