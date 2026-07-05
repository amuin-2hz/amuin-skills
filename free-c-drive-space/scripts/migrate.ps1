<#
.SYNOPSIS
    Migrate a directory from C drive to another drive via junction.
    Full pipeline: copy → verify → delete → junction.
#>
param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Target,
    [switch] $Force,          # Skip confirmation prompts
    [switch] $DryRun          # Show what would happen without doing it
)

$ErrorActionPreference = 'Stop'
$Source = $Source.TrimEnd('\')
$Target = $Target.TrimEnd('\')

# ── Preflight ──
if (-not (Test-Path $Source)) { Write-Error "Source not found: $Source"; exit 1 }
if (Test-Path $Target)         { Write-Error "Target already exists: $Target — remove it first"; exit 2 }
if ((Get-Item $Source).LinkType -eq 'Junction') { Write-Error "Source is already a junction — nothing to migrate"; exit 3 }

$srcSize = [math]::Round(((Get-ChildItem $Source -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum / 1GB), 1)

Write-Host "Source : $Source ($srcSize GB)" -ForegroundColor Yellow
Write-Host "Target : $Target"               -ForegroundColor Yellow

# ── Check target drive space ──
$targetDrive = [System.IO.Path]::GetPathRoot($Target).TrimEnd('\')
try {
    $free = [math]::Round(((Get-PSDrive -Name $targetDrive[0]).Free / 1GB), 1)
    if ($free -lt $srcSize + 1) { Write-Error "Target drive only has ${free}GB free — need at least $($srcSize+1)GB"; exit 4 }
    Write-Host "Target drive free: ${free}GB" -ForegroundColor Green
} catch {}

if ($DryRun) { Write-Host "DRY RUN — nothing executed." -ForegroundColor Cyan; exit 0 }
if (-not $Force) {
    $confirm = Read-Host "Proceed with migration? (yes/no)"
    if ($confirm -ne 'yes') { Write-Host "Aborted."; exit 0 }
}

# ── Step 1: Copy ──
Write-Host "`n[1/4] Copying..." -ForegroundColor Cyan
$parent = Split-Path $Target -Parent
New-Item -ItemType Directory -Path $parent -Force | Out-Null

# Choose strategy: robocopy for large transfers, Copy-Item for small ones
if ($srcSize -gt 10) {
    robocopy $Source $Target /E /COPY:DAT /R:3 /W:5 /NP /NDL /NFL 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Write-Error "robocopy failed (exit $rc)"; exit 5 }
    Write-Host "  robocopy done (exit $rc)" -ForegroundColor Green
} else {
    Copy-Item "$Source\*" $Target -Recurse -Force -ErrorAction Stop
    Write-Host "  Copy-Item done" -ForegroundColor Green
}

# ── Step 2: Verify ──
Write-Host "[2/4] Verifying..." -ForegroundColor Cyan
$srcCount = (Get-ChildItem $Source -Recurse -File).Count
$dstCount = (Get-ChildItem $Target -Recurse -File).Count
if ($srcCount -ne $dstCount) {
    Write-Error "FILE COUNT MISMATCH: Source=$srcCount, Target=$dstCount — ABORTING (original NOT deleted)"
    exit 6
}
Write-Host "  File count match: $srcCount files" -ForegroundColor Green

# ── Step 3: Delete ──
Write-Host "[3/4] Deleting original..." -ForegroundColor Cyan
Remove-Item $Source -Recurse -Force
Write-Host "  Deleted: $Source" -ForegroundColor Green

# ── Step 4: Junction ──
Write-Host "[4/4] Creating junction..." -ForegroundColor Cyan
New-Item -ItemType Junction -Path $Source -Target $Target -Force | Out-Null
Write-Host "  Junction: $Source -> $Target" -ForegroundColor Green

# ── Final verification ──
$j = Get-Item $Source -Force
if ($j.LinkType -ne 'Junction') {
    Write-Error "CRITICAL: Junction verification failed — created item is not a junction"
    exit 7
}
Write-Host "`n✓ Migration complete. C drive freed: $srcSize GB" -ForegroundColor Green
