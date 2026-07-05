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
