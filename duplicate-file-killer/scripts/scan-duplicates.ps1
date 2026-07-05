<#
.SYNOPSIS
    Scan directories for duplicate files via size grouping + SHA256 hashing.
    Output JSON of duplicate groups to stdout.
#>
param(
    [Parameter(Mandatory)]
    [string[]] $Paths,

    [int]    $MinSizeMB = 1,
    [switch] $IncludeHidden
)

$ErrorActionPreference = 'Stop'
$minSizeBytes = $MinSizeMB * 1MB

Write-Host "`n  Scanning..." -ForegroundColor Cyan
Write-Host "  Paths: $($Paths -join ', ')"
Write-Host "  Min size: $MinSizeMB MB`n"

# ── Collect files ──
$bySize = @{}   # size_bytes -> [fileinfo]
$totalScanned = 0
$skippedJunctions = 0
$skippedSmall = 0
$skippedSystem = 0

$systemRoots = @(
    "$env:SystemRoot",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}",
    "$env:SystemRoot\System32"
) | Where-Object { $_ }

foreach ($root in $Paths) {
    if (-not (Test-Path $root)) {
        Write-Host "  [SKIP] Not found: $root" -ForegroundColor DarkGray
        continue
    }

    # Check if root is in a system directory
    $isSystemPath = $false
    foreach ($sr in $systemRoots) {
        if ($root.StartsWith($sr, [StringComparison]::OrdinalIgnoreCase)) {
            $isSystemPath = $true
            break
        }
    }
    if ($isSystemPath) {
        Write-Host "  [SKIP] System directory (use -IncludeSystemPath to override): $root" -ForegroundColor DarkGray
        $skippedSystem++
        continue
    }

    Write-Host "  Scanning: $root" -ForegroundColor White
    $files = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue

    foreach ($f in $files) {
        $totalScanned++

        # Skip junctions/symlinks
        if ($f.LinkType) {
            $skippedJunctions++
            continue
        }

        # Skip hidden/system unless requested
        if (-not $IncludeHidden -and ($f.Attributes -band ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System))) {
            continue
        }

        # Skip below threshold
        if ($f.Length -lt $minSizeBytes) {
            $skippedSmall++
            continue
        }

        # Skip online-only cloud placeholders (OneDrive, etc.)
        if ($f.Attributes -band 0x00080000) {  # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
            continue
        }

        $size = $f.Length
        if (-not $bySize.ContainsKey($size)) {
            $bySize[$size] = [System.Collections.ArrayList]::new()
        }
        [void]$bySize[$size].Add($f)
    }
}

Write-Host "`n  Files scanned  : $totalScanned" -ForegroundColor Cyan
Write-Host "  Skipped (small) : $skippedSmall"   -ForegroundColor DarkGray
Write-Host "  Skipped (junc)  : $skippedJunctions" -ForegroundColor DarkGray
Write-Host "  Size groups     : $($bySize.Count)`n"

# ── Find duplicate candidates (size groups with 2+ files) ──
$candidateGroups = @($bySize.GetEnumerator() | Where-Object { $_.Value.Count -ge 2 })
Write-Host "  Candidates      : $($candidateGroups.Count) groups with >=2 files" -ForegroundColor Cyan

if ($candidateGroups.Count -eq 0) {
    Write-Host "`n  No duplicate candidates found." -ForegroundColor Green
    $result = [PSCustomObject]@{
        total_files_scanned = $totalScanned
        duplicate_groups    = 0
        total_wasted_bytes  = 0
        groups              = @()
    }
    Write-Output ($result | ConvertTo-Json -Depth 5 -Compress)
    exit 0
}

# ── Hash same-size groups ──
Write-Host "  Hashing candidates..." -ForegroundColor Cyan
$sha = [System.Security.Cryptography.SHA256]::Create()
$hashGroups = @{}   # hash_string -> [files]

$processed = 0
foreach ($group in $candidateGroups) {
    $processed++
    $sizeKey = $group.Key
    $fileList = $group.Value

    if ($processed % 10 -eq 0 -or $processed -eq 1) {
        Write-Host "    [$processed / $($candidateGroups.Count)] size=$sizeKey files=$($fileList.Count)" -ForegroundColor DarkGray
    }

    # Group files in this size-bucket by hash
    $localHashes = @{}
    foreach ($f in $fileList) {
        try {
            $stream = [System.IO.File]::OpenRead($f.FullName)
            $hashBytes = $sha.ComputeHash($stream)
            $stream.Close()
            $hashStr = [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()

            if (-not $localHashes.ContainsKey($hashStr)) {
                $localHashes[$hashStr] = [System.Collections.ArrayList]::new()
            }
            [void]$localHashes[$hashStr].Add($f)
        } catch {
            Write-Host "    [WARN] Cannot hash: $($f.FullName) — $_" -ForegroundColor Yellow
        }
    }

    # Keep only groups with 2+ identical files
    foreach ($kv in $localHashes.GetEnumerator()) {
        if ($kv.Value.Count -ge 2) {
            $hashGroups[$kv.Key] = $kv.Value
        }
    }
}

$sha.Dispose()

# ── Detect hardlinks ──
function Get-Inode($path) {
    try {
        $f = [System.IO.FileInfo]::new($path)
        # Use nFileIndexHigh/nFileIndexLow via GetFileInformationByHandle
        $handle = [System.IO.File]::OpenRead($path).SafeFileHandle
        $result = New-Object byte[] 80
        $ok = GetFileInformationByHandle($handle, $result)
        $handle.Close()
        if ($ok) {
            $high = [BitConverter]::ToUInt64($result, 40)
            $low  = [BitConverter]::ToUInt64($result, 48)
            return "$high-$low-$($f.DirectoryName.ToLower())"  # inode + volume
        }
    } catch {}
    return $null
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetFileInformationByHandle(
        Microsoft.Win32.SafeHandles.SafeFileHandle hFile,
        byte[] lpFileInformation);
}
'@ -ErrorAction SilentlyContinue

function GetFileInformationByHandle($handle, [byte[]] $result) {
    return [Win32]::GetFileInformationByHandle($handle, $result)
}

# ── Build output ──
$groups = [System.Collections.ArrayList]::new()
$totalWasted = 0L

foreach ($kv in $hashGroups.GetEnumerator()) {
    $hash = $kv.Key
    $files = $kv.Value
    $size = $files[0].Length

    # Detect hardlinks within group
    $inodes = @{}
    $filesOut = @()
    foreach ($f in $files) {
        $ino = Get-Inode $f.FullName
        $isHardlink = $false
        if ($ino) {
            if ($inodes.ContainsKey($ino)) {
                $isHardlink = $true
            } else {
                $inodes[$ino] = $true
            }
        }
        $filesOut += [PSCustomObject]@{
            path         = $f.FullName
            modified     = $f.LastWriteTimeUtc.ToString('o')
            is_hardlink  = $isHardlink
        }
    }

    # Wasted = size * (distinct copies - 1), only count non-hardlinks
    $realCopies = ($filesOut | Where-Object { -not $_.is_hardlink }).Count
    $wasted = if ($realCopies -ge 2) { $size * ($realCopies - 1) } else { 0 }
    $totalWasted += $wasted

    [void]$groups.Add([PSCustomObject]@{
        hash       = $hash
        size_bytes = $size
        files      = $filesOut
    })
}

$result = [PSCustomObject]@{
    total_files_scanned = $totalScanned
    duplicate_groups    = $groups.Count
    total_wasted_bytes  = $totalWasted
    groups              = $groups | Sort-Object { -$_.size_bytes * $_.files.Count }
}

Write-Host "`n  Duplicates found: $($groups.Count) groups, wasted $([math]::Round($totalWasted / 1MB, 1)) MB`n" -ForegroundColor $(if ($groups.Count -gt 0) { 'Yellow' } else { 'Green' })

Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
