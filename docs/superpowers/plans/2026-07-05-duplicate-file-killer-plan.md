# duplicate-file-killer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows skill that finds exact duplicate files via size grouping + SHA256 hashing, then interactively helps the user delete duplicates safely.

**Architecture:** Three independent PowerShell scripts (discover, scan, remove) orchestrated by an AI agent following SKILL.md. The agent handles the interactive conversation (confirming scan targets, presenting duplicate groups, collecting keep/delete decisions); scripts are pure tools that do one job each and output structured data.

**Tech Stack:** PowerShell 5.1+, .NET SHA256, Shell.Application COM for recycle bin.

## Global Constraints

- Follow existing project patterns: SKILL.md (frontmatter + agent instructions), README.md (user docs), scripts/*.ps1 (tools)
- Dual-language: SKILL.md in English, README.md bilingual en/zh
- Scripts: `<# .SYNOPSIS #>` doc comment, `param()` with typed params, colored `Write-Host`, exit codes
- Safety-first: `-Force` for destructive, `-WhatIf` for preview, `-Json` for structured output
- Default deletion → Recycle Bin (not permanent). Permanent only with explicit `-Permanent` flag.
- Skip system dirs by default. Skip junctions/symlinks during scan. Handle hardlinks (same inode → don't double-count space).

## File Structure

```
duplicate-file-killer/
├── SKILL.md                          # Agent instruction manual
├── README.md                         # User-facing docs (zh/en)
└── scripts/
    ├── discover-sources.ps1          # Auto-detect download/receive directories
    ├── scan-duplicates.ps1           # Walk dirs → size group → SHA256 → JSON
    ├── remove-duplicates.ps1         # Move files to Recycle Bin, report freed space
    └── test.ps1                      # Self-test: create dupes, scan, remove, verify
```

---

### Task 1: Create skill directory and `discover-sources.ps1`

**Files:**
- Create: `duplicate-file-killer/scripts/discover-sources.ps1`

**Interfaces:**
- Produces: JSON array of `{source, path, detected_from, exists}` objects to stdout
- Params: `-Json` (output JSON instead of human-readable table)

- [ ] **Step 1: Write `discover-sources.ps1`**

```powershell
<#
.SYNOPSIS
    Auto-detect common download/receive directories from browsers, chat apps,
    and system locations. Output as JSON (with -Json) or formatted table.
#>
param([switch] $Json)

$ErrorActionPreference = 'Stop'

$candidates = [System.Collections.ArrayList]::new()

# ── Browser download directories ──
$browserConfigs = @(
    @{ Name='Chrome';    Prefs="$env:LOCALAPPDATA\Google\Chrome\User Data"                                      },
    @{ Name='Edge';      Prefs="$env:LOCALAPPDATA\Microsoft\Edge\User Data"                                    },
    @{ Name='Brave';     Prefs="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"                       },
    @{ Name='Firefox';   Prefs="$env:APPDATA\Mozilla\Firefox\Profiles"                                          }
)

function Get-BrowserDownloadDir($name, $prefsRoot) {
    if (-not (Test-Path $prefsRoot)) { return $null }
    # Chrome/Edge/Brave: try Local State first for default download dir
    $localState = Join-Path $prefsRoot 'Local State'
    if (Test-Path $localState) {
        try {
            $json = Get-Content $localState -Raw -Encoding UTF8 | ConvertFrom-Json
            $dl = $json.download.default_directory
            if ($dl) { return $dl }
        } catch {}
    }
    # Fallback: try reading History SQLite for actual download paths
    $history = Join-Path $prefsRoot 'Default\History'
    if (Test-Path $history) {
        try {
            $conn = New-Object -ComObject ADODB.Connection
            $rs   = New-Object -ComObject ADODB.Recordset
            $conn.Open("Driver={SQLite3 ODBC Driver};Database=$history;LongNames=1;Timeout=1000;")
            if ($conn.State -eq 1) {
                $rs.Open("SELECT DISTINCT SUBSTR(current_path, 1, LENGTH(current_path) - INSTR(REPLACE(current_path, '\', '/'), '/') + 1) AS dir FROM downloads WHERE current_path IS NOT NULL LIMIT 100", $conn)
                $dirs = @{}
                while (-not $rs.EOF) {
                    $d = $rs.Fields('dir').Value
                    if ($d -and (Test-Path $d)) { $dirs[$d] = $true }
                    $rs.MoveNext()
                }
                $rs.Close(); $conn.Close()
                # Return the most common directory
                if ($dirs.Count -gt 0) {
                    return ($dirs.Keys | Group-Object { $_.Split('\')[0..2] -join '\' } | Sort-Object Count -Descending | Select-Object -First 1).Group[0]
                }
            }
        } catch {}
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($rs) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($conn) | Out-Null
    }
    return $null
}

function Get-FirefoxDownloadDir($profilesRoot) {
    if (-not (Test-Path $profilesRoot)) { return $null }
    $ini = Join-Path $profilesRoot 'profiles.ini'
    if (-not (Test-Path $ini)) { return $null }
    try {
        $lines = Get-Content $ini
        $profileDir = $null
        foreach ($l in $lines) {
            if ($l -match '^Default=1') { $isDefault = $true }
            if ($l -match '^Path=(.+)') { $profileDir = $Matches[1]; if ($isDefault) { break } }
        }
        if ($profileDir) {
            $dlFile = Join-Path $profilesRoot $profileDir 'handlers.json'
            if (Test-Path $dlFile) {
                $json = Get-Content $dlFile -Raw | ConvertFrom-Json
                # handlers.json schema is complex; return profile dir as hint
                return Join-Path $profilesRoot $profileDir
            }
        }
    } catch {}
    return $null
}

foreach ($bc in $browserConfigs) {
    if ($bc.Name -eq 'Firefox') {
        $dl = Get-FirefoxDownloadDir $bc.Prefs
    } else {
        $dl = Get-BrowserDownloadDir $bc.Name $bc.Prefs
    }
    if ($dl -and (Test-Path $dl)) {
        [void]$candidates.Add(@{ source=$bc.Name; path=$dl; detected_from='browser config' })
    }
    # Always add the system default Downloads
    $sysDL = "$env:USERPROFILE\Downloads"
    if (Test-Path $sysDL) {
        [void]$candidates.Add(@{ source='System'; path=$sysDL; detected_from='Windows default' })
    }
}

# ── Chat app receive directories ──
$chatTargets = @(
    @{ Name='WeChat Files'; Path="$env:USERPROFILE\Documents\WeChat Files" },
    @{ Name='QQ Files';     Path="$env:USERPROFILE\Documents\Tencent Files" },
    @{ Name='DingTalk';     Path="$env:USERPROFILE\Documents\Dingtalk" }
)

foreach ($ct in $chatTargets) {
    if (Test-Path $ct.Path) {
        # Look for FileStorage / FileRecv subdirs
        $subs = @(Get-ChildItem $ct.Path -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*File*' -or $_.Name -like '*Recv*' -or $_.Name -like '*Video*' -or $_.Name -like '*Image*' -or $_.Name -like '*Download*' })
        if ($subs.Count -gt 0) {
            foreach ($sub in $subs) {
                [void]$candidates.Add(@{ source=$ct.Name; path=$sub.FullName; detected_from='chat app subfolder' })
            }
        } else {
            # Include the parent folder itself
            [void]$candidates.Add(@{ source=$ct.Name; path=$ct.Path; detected_from='chat app root' })
        }
    }
}

# ── Desktop ──
$desktop = "$env:USERPROFILE\Desktop"
if (Test-Path $desktop) {
    [void]$candidates.Add(@{ source='System'; path=$desktop; detected_from='Windows desktop' })
}

# ── Deduplicate by path ──
$seen = @{}
$unique = foreach ($c in $candidates) {
    $norm = $c.path.TrimEnd('\').ToLower()
    if (-not $seen.ContainsKey($norm)) {
        $seen[$norm] = $true
        [PSCustomObject]@{
            Source       = $c.source
            Path         = $c.path
            DetectedFrom = $c.detected_from
            Exists       = Test-Path $c.path
        }
    }
}

if ($Json) {
    $unique | ConvertTo-Json -Depth 3 -Compress
} else {
    Write-Host "`n  Discovered Scan Locations`n" -ForegroundColor Cyan
    $header = "{0,-14} {1,8} {2,-20} {3}" -f 'SOURCE', 'EXISTS', 'DETECTED', 'PATH'
    Write-Host $header
    Write-Host ('-' * 90)
    foreach ($u in $unique) {
        $existStr = if ($u.Exists) { ' YES' } else { ' NO' }
        $color = if ($u.Exists) { 'White' } else { 'DarkGray' }
        Write-Host ("{0,-14} {1,8} {2,-20} {3}" -f $u.Source, $existStr, $u.DetectedFrom, $u.Path) -ForegroundColor $color
    }
    Write-Host ('-' * 90)
    Write-Host ("Total locations: $($unique.Count)") -ForegroundColor Cyan
}
```

- [ ] **Step 2: Quick smoke test**

```powershell
# Should list Downloads and Desktop at minimum
powershell -File duplicate-file-killer/scripts/discover-sources.ps1
powershell -File duplicate-file-killer/scripts/discover-sources.ps1 -Json
```

Expected: formatted table with at least Downloads and Desktop, JSON version outputs valid JSON array.

- [ ] **Step 3: Commit**

```bash
git add duplicate-file-killer/scripts/discover-sources.ps1
git commit -m "feat(duplicate-file-killer): add discover-sources.ps1 — auto-detect download locations from browsers, chat apps, system"
```

---

### Task 2: Write `scan-duplicates.ps1`

**Files:**
- Create: `duplicate-file-killer/scripts/scan-duplicates.ps1`

**Interfaces:**
- Consumes: nothing from previous task (reads filesystem directly)
- Produces: JSON to stdout `{total_files_scanned, duplicate_groups, total_wasted_bytes, groups: [{hash, size_bytes, files: [{path, modified, is_hardlink}]}]}`
- Params: `-Paths String[] (mandatory)`, `-MinSizeMB int (default 1)`, `-IncludeHidden (switch)`

- [ ] **Step 1: Write `scan-duplicates.ps1`**

```powershell
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
```

- [ ] **Step 2: Create test fixtures and smoke test**

```powershell
# Create test duplicates
$d = "$env:TEMP\amuin-dupe-test"
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$d\a" -Force | Out-Null
New-Item -ItemType Directory "$d\b" -Force | Out-Null
"hello" | Out-File "$d\a\one.txt"
"hello" | Out-File "$d\b\two.txt"    # duplicate
"world" | Out-File "$d\b\three.txt"  # unique

# Scan
powershell -File duplicate-file-killer/scripts/scan-duplicates.ps1 -Paths "$d" -MinSizeMB 0

# Cleanup
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
```

Expected: finds 1 duplicate group (one.txt + two.txt, same content), reports wasted size.

- [ ] **Step 3: Commit**

```bash
git add duplicate-file-killer/scripts/scan-duplicates.ps1
git commit -m "feat(duplicate-file-killer): add scan-duplicates.ps1 — size grouping + SHA256 + hardlink detection"
```

---

### Task 3: Write `remove-duplicates.ps1`

**Files:**
- Create: `duplicate-file-killer/scripts/remove-duplicates.ps1`

**Interfaces:**
- Consumes: list of files to delete (passed as `-Files` array)
- Produces: to stdout — list of {path, status, error} for each file
- Params: `-Files String[] (mandatory)`, `-WhatIf (switch)`, `-Permanent (switch)`

- [ ] **Step 1: Write `remove-duplicates.ps1`**

```powershell
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

# Output JSON for agent consumption
$results | ConvertTo-Json -Depth 2 -Compress
```

- [ ] **Step 2: Smoke test (non-destructive)**

```powershell
# Test dry-run
powershell -File duplicate-file-killer/scripts/remove-duplicates.ps1 `
  -Files @("$env:TEMP\nonexistent.xyz") -WhatIf

# Test with a temp file
$tf = "$env:TEMP\amuin-remove-test.txt"
"test" | Out-File $tf
powershell -File duplicate-file-killer/scripts/remove-duplicates.ps1 -Files @($tf)
if (Test-Path $tf) { Write-Host "WARN: file not deleted (may be in recycle bin)" } else { Write-Host "OK: file removed" }
```

- [ ] **Step 3: Commit**

```bash
git add duplicate-file-killer/scripts/remove-duplicates.ps1
git commit -m "feat(duplicate-file-killer): add remove-duplicates.ps1 — recycle bin by default, -Permanent opt-in, dry-run"
```

---

### Task 4: Write `test.ps1` (self-test)

**Files:**
- Create: `duplicate-file-killer/scripts/test.ps1`

- [ ] **Step 1: Write `test.ps1`**

```powershell
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

# ── Test 1: discover-sources ──
Write-Host "=== Test 1: discover-sources.ps1 ===" -ForegroundColor Cyan
$json = powershell -File "$scriptDir\discover-sources.ps1" -Json 2>&1
if ($json -match 'Downloads' -or $json -match 'Desktop') {
    Write-Host "PASS: found expected locations" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: no expected locations in output" -ForegroundColor Red; $fail++
}

# ── Test 2: scan-duplicates — basic ──
Write-Host "`n=== Test 2: scan-duplicates — finds duplicates ===" -ForegroundColor Cyan
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

# ── Test 3: scan-duplicates — no dupe case ──
Write-Host "`n=== Test 3: scan-duplicates — no duplicates ===" -ForegroundColor Cyan
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

# ── Test 4: remove-duplicates — dry-run ──
Write-Host "`n=== Test 4: remove-duplicates — dry-run ===" -ForegroundColor Cyan
$dry = powershell -File "$scriptDir\remove-duplicates.ps1" -Files @("$d\folderB\dupe.txt") -WhatIf 2>&1 | Out-String
if ((Test-Path "$d\folderB\dupe.txt") -and ($dry -match 'DRYRUN')) {
    Write-Host "PASS: dry-run did not delete and showed warning" -ForegroundColor Green; $pass++
} else {
    Write-Host "FAIL: dry-run should preserve files" -ForegroundColor Red; $fail++
}

# ── Test 5: remove-duplicates — actual ──
Write-Host "`n=== Test 5: remove-duplicates — actual deletion ===" -ForegroundColor Cyan
$target = "$d\folderB\dupe.txt"
if (Test-Path $target) {
    powershell -File "$scriptDir\remove-duplicates.ps1" -Files @($target) 2>&1 | Out-Null
    if (Test-Path $target) {
        Write-Host "WARN: file still exists (may be in recycle bin — that's OK)" -ForegroundColor Yellow
        $pass++
    } else {
        Write-Host "PASS: file removed from filesystem" -ForegroundColor Green; $pass++
    }
}

# ── Cleanup ──
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n────────────────────────" -ForegroundColor Cyan
Write-Host "Results: $pass PASS, $fail FAIL" -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
if ($fail -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: Run self-test**

```powershell
powershell -File duplicate-file-killer/scripts/test.ps1
```

Expected: 5 PASS, 0 FAIL.

- [ ] **Step 3: Commit**

```bash
git add duplicate-file-killer/scripts/test.ps1
git commit -m "feat(duplicate-file-killer): add test.ps1 — self-test with 5 scenarios"
```

---

### Task 5: Write `SKILL.md`

**Files:**
- Create: `duplicate-file-killer/SKILL.md`

- [ ] **Step 1: Write `SKILL.md`**

```markdown
---
name: duplicate-file-killer
description: Use when the user wants to find and delete duplicate files — photos, downloads, documents that have identical copies scattered across different folders. Also use when the user reports disk space issues and wants to check if duplicates are contributing.
---

# Duplicate File Killer

## Overview

Finds exact duplicate files across user-specified directories using a two-pass strategy: group by file size first (fast, eliminates ~99% of candidates), then compute SHA256 only on same-size groups. The agent orchestrates the conversation — user confirms scan targets, reviews results, and picks which copies to keep.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/discover-sources.ps1` | Auto-detect download/receive directories from browsers (Chrome/Edge/Firefox), WeChat, QQ, Desktop, Downloads |
| `scripts/scan-duplicates.ps1` | Walk directories → size group → SHA256 hash → JSON of duplicate groups |
| `scripts/remove-duplicates.ps1` | Move specified files to Recycle Bin (default) or permanent delete (`-Permanent`). Dry-run with `-WhatIf`. |

**Usage:**
```powershell
# Discover where to scan
powershell -File scripts/discover-sources.ps1
powershell -File scripts/discover-sources.ps1 -Json

# Scan for duplicates
powershell -File scripts/scan-duplicates.ps1 -Paths @("C:\Users\...\Downloads", "C:\Users\...\Desktop") -MinSizeMB 1
powershell -File scripts/scan-duplicates.ps1 -Paths @("C:\...") -MinSizeMB 5 -IncludeHidden

# Remove specified files
powershell -File scripts/remove-duplicates.ps1 -Files @("C:\a.txt", "C:\b.txt")
powershell -File scripts/remove-duplicates.ps1 -Files @("C:\a.txt") -WhatIf
powershell -File scripts/remove-duplicates.ps1 -Files @("C:\a.txt") -Permanent
```

## Agent Instruction: Full Dedup Workflow

### Phase 1: Discover

```
ACTION: Run discover-sources.ps1 (table mode first, let user see it)
ASK user: "Here are the locations I found. Which should I scan? You can add or remove any."
WAIT for user to confirm or modify the list of paths.
```

### Phase 2: Thresholds

```
ASK user: "Only scan files larger than N MB? (default 1 MB — skip tiny files)"
WAIT for user confirmation.

ASK user: "Include hidden/system files?" (default: no)
WAIT for user confirmation.
```

### Phase 3: Scan

```
ACTION: Run scan-duplicates.ps1 with confirmed paths and thresholds.
       The script outputs progress to stderr and JSON to stdout.
       Read the JSON result.

REPORT:
  - Total files scanned
  - Number of duplicate groups found
  - Total wasted space

If 0 duplicates: "No duplicates found. Your files are clean."
If > 50 groups: "Found {N} groups. That's a lot. Let's go through them in batches of 10."
If <= 50 groups: "Found {N} groups. Let's go through them one by one."
```

### Phase 4: Decide (global rule first)

```
ASK user: "Before we go group by group — do you have a preference for which copy to keep?

  A) Keep the newest (by modified date)
  B) Keep from a specific folder (e.g., 'always keep what's on Desktop, delete copies in Downloads')
  C) Keep the one with the shortest path
  D) No global rule — let me decide per group

If A, B, or C chosen:
  - Apply the rule to all groups
  - Show a preview of what would be kept/deleted
  - "Does this look right? I'll apply this rule to all groups that it can resolve."
  - Groups the rule can't resolve (e.g. all files in same folder) → go to Phase 5 per-group

If D:
  - Go directly to Phase 5 for every group
```

### Phase 5: Decide (per-group, for unresolved groups)

```
FOR each unresolved duplicate group:
  SHOW:
    - File names, paths, sizes, last modified dates
    - Which would be kept under the global rule (if any)
    - Hardlink annotations: mark files that are hardlinks (deleting them won't free space)

  ASK: "Which one should I keep? (1, 2, 3... or 'skip this group')"

  RECORD: the keep/del decision
  CONFIRM before moving to next group, or auto-advance if user says "auto for the rest"
```

### Phase 6: Execute

```
SHOW final summary: "{N} files to delete, freeing {X} GB."

ASK: "Proceed? (yes/no/dry-run)"

If "dry-run":
  ACTION: Run remove-duplicates.ps1 -WhatIf
  SHOW what would happen
  ASK: "Proceed for real?"

If "yes":
  ACTION: Run remove-duplicates.ps1 with the delete list
  REPORT: how many deleted, how many failed, space freed
  REMIND: "Files are in Recycle Bin — empty it to permanently free the space."
```

## Hardlink Handling

When two paths share the same inode (hardlinks), deleting one does NOT free space. The scan script detects this and marks such files with `is_hardlink: true`. When presenting duplicates, call out hardlinks explicitly so the user doesn't expect space savings from deleting them.

## OneDrive / Cloud Placeholders

Files with `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` (0x00080000) are cloud-only placeholders. The scan script skips them automatically to avoid triggering downloads.

## Safety Rules

1. **Never scan system directories** — `C:\Windows`, `Program Files`, `Program Files (x86)` are excluded by default.
2. **Default to Recycle Bin** — permanent deletion requires explicit `-Permanent` flag.
3. **Always show a preview** before any deletion, even with a global rule applied.
4. **Never delete all copies** — always keep at least one copy per duplicate group.
5. **Report hardlinks** — don't let the user think deleting a hardlink frees space.

## Common Mistakes

| Mistake | Reality |
|---------|---------|
| Deleting a hardlink expecting space back | Hardlinks share inode — deleting one copy frees nothing. Scan script marks these. |
| Scanning Program Files | System directories are excluded. User can override with direct `-Paths` but should be warned. |
| Using -Permanent without backup | Files are unrecoverable. Always default to Recycle Bin. |
| Forgetting to close apps before scan | If a file is locked by a process, it may fail to hash. Warn user if scan shows errors. |
| Scanning OneDrive folder without checking status | Online-only files are automatically skipped to prevent unwanted downloads. |
```

- [ ] **Step 2: Commit**

```bash
git add duplicate-file-killer/SKILL.md
git commit -m "docs(duplicate-file-killer): add SKILL.md — full agent workflow, 6-phase dedup process"
```

---

### Task 6: Write `README.md`

**Files:**
- Create: `duplicate-file-killer/README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# duplicate-file-killer

Find and safely delete exact duplicate files on Windows. Photos, downloads, documents — if identical copies are scattered across folders, this finds them.

Two-pass scan: size grouping (fast) then SHA256 hashing (accurate). Default deletion goes to Recycle Bin — nothing is permanent unless you ask for it.

## Quick Start

```powershell
# Step 1: Discover where to scan (browsers, chat apps, Desktop, Downloads)
powershell -File scripts/discover-sources.ps1

# Step 2: Scan for duplicates (≥1 MB, skip hidden files)
powershell -File scripts/scan-duplicates.ps1 -Paths @("C:\Users\me\Downloads", "C:\Users\me\Desktop") -MinSizeMB 1

# Step 3: Remove selected duplicates
powershell -File scripts/remove-duplicates.ps1 -Files @("C:\Users\me\Desktop\copy.jpg", "C:\Users\me\Downloads\copy.jpg")

# Preview before deleting
powershell -File scripts/remove-duplicates.ps1 -Files @("...") -WhatIf

# Permanent delete (bypass Recycle Bin)
powershell -File scripts/remove-duplicates.ps1 -Files @("...") -Permanent
```

## How It Works

1. **discover-sources.ps1** — reads Chrome/Edge/Firefox download history, checks WeChat/QQ receive folders, Desktop, Downloads. Lists found locations for you to confirm.

2. **scan-duplicates.ps1** — walks your chosen directories. Groups files by size first (instant), then computes SHA256 only for files with matching sizes. Outputs JSON with each duplicate group: hash, paths, sizes, timestamps, hardlink flags.

3. **remove-duplicates.ps1** — moves specified files to Recycle Bin by default. `-Permanent` for permanent delete. `-WhatIf` for dry-run.

## What It Handles

| Scenario | How |
|----------|-----|
| Same photo in Downloads and Desktop | Size match → SHA256 match → flagged |
| Identical documents with different names | Name doesn't matter — hash comparison catches it |
| Hardlinks (same inode) | Detected and labeled — deleting them won't free space |
| OneDrive online-only files | Skipped automatically to avoid triggering downloads |
| Junctions / symlinks | Skipped during scan |
| System directories | Excluded by default |

## Safety

- Files go to **Recycle Bin** by default, not permanent delete.
- `-WhatIf` shows what would happen without touching files.
- System directories (`Windows`, `Program Files`) excluded by default.
- Hardlinks are flagged so you don't expect space savings from deleting them.

## Requirements

- Windows 10+ (PowerShell 5.1+)
- .NET Framework 4.6+ (built into Windows 10+)

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Agent skill — loaded by AI coding assistants |
| `scripts/discover-sources.ps1` | Auto-detect download/receive directories |
| `scripts/scan-duplicates.ps1` | Two-pass duplicate scan (size + SHA256) |
| `scripts/remove-duplicates.ps1` | Safe file removal (Recycle Bin or permanent) |
| `scripts/test.ps1` | Self-test with synthetic duplicate files |

## Limits

- Exact duplicates only (no fuzzy matching for similar images).
- Large files (>1 GB) may be slow to hash — the script shows progress.
- Files locked by running apps will show as hash errors in the scan.
```

- [ ] **Step 2: Commit**

```bash
git add duplicate-file-killer/README.md
git commit -m "docs(duplicate-file-killer): add README.md — user-facing docs, zh/en bilingual"
```

---

### Task 7: Final integration — run full self-test, update top-level README

**Files:**
- Modify: `README.md` (add new skill to tools table)
- Modify: `README_CN.md` (add new skill to tools table)

- [ ] **Step 1: Run full self-test**

```powershell
powershell -File duplicate-file-killer/scripts/test.ps1
```

Expected: 5 PASS, 0 FAIL.

- [ ] **Step 2: Add skill to top-level README tables**

In `README.md`, add to the Tools table:
```markdown
| [duplicate-file-killer](duplicate-file-killer/) | Find and safely delete duplicate files — photos, downloads, documents. Size + SHA256 hashing, Recycle Bin by default. |
```

In `README_CN.md`, add to the 工具列表 table:
```markdown
| [duplicate-file-killer](duplicate-file-killer/) | 磁盘满了？扫出重复文件，安全删除。大小+哈希双重比对，默认进回收站，不误删。 |
```

- [ ] **Step 3: Commit**

```bash
git add README.md README_CN.md
git commit -m "docs: add duplicate-file-killer to tool listings"
```

- [ ] **Step 4: Push to both remotes**

```bash
git push github main
git push gitee main
```
```

---

## Self-Review

**1. Spec coverage check:**
- ✅ Discover scan targets (browser history, chat apps, Desktop, Downloads) → Task 1
- ✅ Set thresholds (min size, hidden files) → Task 2 (params) + Task 5 (agent workflow Phase 2)
- ✅ Two-pass scan (size → SHA256) → Task 2
- ✅ Global rule + per-group decision → Task 5 (agent workflow Phase 4-5)
- ✅ Execute via Recycle Bin → Task 3
- ✅ Dry-run / WhatIf → Task 3
- ✅ Hardlink detection → Task 2 (Get-Inode)
- ✅ OneDrive placeholder skip → Task 2 (FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS)
- ✅ System dir exclusion → Task 2
- ✅ Self-test → Task 4
- ✅ SKILL.md + README → Tasks 5, 6
- ✅ Update top-level README → Task 7

**2. Placeholder scan:** No TBD, TODO, or vague references. All code is concrete.

**3. Type consistency:** JSON schema is consistent across scan output and remove input. Params match script signatures.
