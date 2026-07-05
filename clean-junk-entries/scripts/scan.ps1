<#
.SYNOPSIS
    Scan registry and Task Scheduler for junk entries left by uninstalled software.
    5 categories, 3-tier classification (confirmed/suspicious/clean).
    Output as JSON (with -Json) or formatted color-coded table.
#>
param(
    [switch] $Json,
    [string[]] $Categories  # If omitted, scan all. Valid: context_menu, this_pc, uninstall, explorer_bar, scheduled_tasks
)

$ErrorActionPreference = 'Stop'

# ── Admin check ──
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  [WARN] Not running as admin. Some registry keys may be inaccessible." -ForegroundColor Yellow
}

# ── Config: known bloatware publisher patterns ──
$bloatwarePatterns = @(
    '抖音', '小智', '壁纸', 'WPS', '360', '腾讯视频', '腾讯', '百度', '迅雷',
    '快压', '驱动精灵', '驱动人生', '鲁大师', '2345', 'hao123', '搜狐',
    'PPTV', '风行', '酷狗', '酷我', '暴风', 'Akamai', 'OpcClaw'
)

# ── System CLSID whitelist (never flag these) ──
$systemCLSID = @(
    '{20D04FE0-3AEA-1069-A2D8-08002B30309D}',  # This PC
    '{645FF040-5081-101B-9F08-00AA002F954E}',  # Recycle Bin
    '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}',  # Network
    '{26EE0668-A00A-44D7-9371-BEB064C98683}',  # Control Panel
    '{088E3905-0323-4B02-9826-5D99428E115F}',  # Downloads
    '{24AD3AD4-A569-4530-98E1-AB02F9417AA8}',  # Pictures
    '{A0953C92-50DC-43BF-BE83-3742FED03C9C}',  # Videos
    '{3DFACD43-77FF-4A68-965C-24A556B60DE2}',  # Music
    '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}',  # Desktop
    '{D3162B92-9365-467A-956B-92703ACA08AF}',  # Documents
    '{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}',  # 3D Objects
    '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'   # OneDrive
)

# ── Helpers ──
function Test-PathExists($p) {
    if (-not $p) { return $false }
    # Expand environment variables in path
    $expanded = [Environment]::ExpandEnvironmentVariables($p)
    # Strip quotes and arguments (e.g. "C:\app.exe" /uninstall)
    if ($expanded -match '^"([^"]+)"') { $expanded = $Matches[1] }
    elseif ($expanded -match '^(.+?\.(exe|dll|msi|scr|sys|cpl))') { $expanded = $Matches[1] }
    return (Test-Path $expanded)
}

function Get-DisplayName($key, $defaultName) {
    try {
        $dn = (Get-ItemProperty $key -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        if ($dn) { return $dn }
    } catch {}
    try {
        $dn = (Get-ItemProperty $key -Name 'DisplayName' -ErrorAction SilentlyContinue).DisplayName
        if ($dn) { return $dn }
    } catch {}
    try {
        $dn = (Get-ItemProperty $key -Name 'MUIVerb' -ErrorAction SilentlyContinue).MUIVerb
        if ($dn) { return $dn }
    } catch {}
    return $defaultName
}

function Get-Publisher($key) {
    try { return (Get-ItemProperty $key -Name 'Publisher' -ErrorAction SilentlyContinue).Publisher } catch {}
    return ''
}

function Test-IsSigned($exePath) {
    if (-not $exePath -or -not (Test-Path $exePath)) { return $false }
    try {
        $sig = Get-AuthenticodeSignature $exePath -ErrorAction SilentlyContinue
        return ($sig.Status -eq 'Valid')
    } catch { return $false }
}

function Match-Bloatware($text) {
    if (-not $text) { return @() }
    $matches = @()
    foreach ($p in $bloatwarePatterns) {
        if ($text -match [regex]::Escape($p)) { $matches += $p }
    }
    return $matches
}

function Classify-Entry($keyPath, $targetPath, $displayName, $publisher) {
    $targetMissing = -not (Test-PathExists $targetPath)
    $publisherMatches = Match-Bloatware "$displayName $publisher"

    if ($targetMissing) {
        # Hard evidence: target file doesn't exist
        return @{ tier = 'confirmed'; evidence = "Target file not found: $targetPath" }
    }

    # Check digital signature
    if ($targetPath -and (Test-PathExists $targetPath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($targetPath)
        if (-not (Test-IsSigned $expanded)) {
            if ($publisherMatches.Count -gt 0) {
                return @{ tier = 'suspicious'; evidence = "Unsigned + matches bloatware: $($publisherMatches -join ', ')" }
            }
            return @{ tier = 'suspicious'; evidence = "Unsigned executable: $expanded" }
        }
    }

    # Publisher matches known bloatware but file exists and is signed
    if ($publisherMatches.Count -gt 0) {
        return @{ tier = 'suspicious'; evidence = "Publisher matches bloatware: $($publisherMatches -join ', ')" }
    }

    return @{ tier = 'clean'; evidence = 'Target exists, signed, no bloatware match' }
}

# ── Results accumulator ──
$allResults = @()
$summary = @{ confirmed = 0; suspicious = 0; clean = 0 }

$allCategories = $Categories
if (-not $allCategories -or $allCategories.Count -eq 0) {
    $allCategories = @('context_menu', 'this_pc', 'uninstall', 'explorer_bar', 'scheduled_tasks')
}

# ═══════════════════════════════════════════
# CATEGORY 1: Context Menu
# ═══════════════════════════════════════════
if ('context_menu' -in $allCategories) {
    Write-Host "`n  [1/5] Scanning context menus..." -ForegroundColor Cyan
    $ctxEntries = @()

    $ctxPaths = @(
        'HKCR:\*\shell',
        'HKCR:\*\shellex\ContextMenuHandlers',
        'HKCR:\Directory\shell',
        'HKCR:\Directory\shellex\ContextMenuHandlers',
        'HKCR:\Directory\Background\shell',
        'HKCR:\Drive\shell',
        'HKCR:\DesktopBackground\shell',
        'HKCR:\Folder\shell',
        'HKCR:\Folder\shellex\ContextMenuHandlers'
    )

    foreach ($ctxRoot in $ctxPaths) {
        if (-not (Test-Path $ctxRoot)) { continue }
        $subkeys = Get-ChildItem $ctxRoot -ErrorAction SilentlyContinue
        foreach ($sk in $subkeys) {
            $keyPath = ($sk.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '') -replace '^HKEY_CURRENT_USER\\?', 'HKCU:\' -replace '^HKEY_LOCAL_MACHINE\\?', 'HKLM:\' -replace '^HKEY_CLASSES_ROOT\\?', 'HKCR:\'
            $displayName = Get-DisplayName $keyPath (Split-Path $keyPath -Leaf)
            $targetPath = ''

            # Try to find the command/executable
            $cmdKey = Join-Path $keyPath 'command'
            if (Test-Path $cmdKey) {
                try { $targetPath = (Get-ItemProperty $cmdKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)' } catch {}
            }
            # Check for shellex CLSID
            if (-not $targetPath) {
                try {
                    $clsid = (Get-ItemProperty $keyPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
                    if ($clsid -and $clsid -match '\{[\w-]+\}') {
                        $inprocKey = "HKCR:\CLSID\$clsid\InProcServer32"
                        if (Test-Path $inprocKey) {
                            $targetPath = (Get-ItemProperty $inprocKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
                        }
                    }
                } catch {}
            }

            # Skip standard Windows shell verbs by name — these are always
            # built-in (open, edit, print, etc.) and never third-party junk
            $leafName = Split-Path $keyPath -Leaf
            $standardVerbs = @(
                'open', 'edit', 'print', 'printto', 'play', 'preview',
                'runas', 'runasuser', 'find', 'explore', 'properties',
                'install', 'uninstall', 'config', 'configure', 'sendto',
                'new', 'rename', 'delete', 'copy', 'cut', 'paste',
                'select', 'shell', 'Shell', 'None', 'SEP_', 'separator'
            )
            if ($leafName -in $standardVerbs) { continue }

            $publisher = Get-Publisher $keyPath
            $class = Classify-Entry $keyPath $targetPath $displayName $publisher
            $summary[$class.tier]++

            $ctxEntries += [PSCustomObject]@{
                key_path     = $keyPath
                display_name = $displayName
                tier         = $class.tier
                evidence     = $class.evidence
                target_path  = $targetPath
                publisher    = $publisher
            }
        }
    }

    $allResults += [PSCustomObject]@{
        name    = 'context_menu'
        label   = 'Context Menu'
        entries = @($ctxEntries | Sort-Object { @{ confirmed=0; suspicious=1; clean=2 }[$_.tier] }, display_name)
    }
}

# ═══════════════════════════════════════════
# CATEGORY 2: This PC (MyComputer NameSpace)
# ═══════════════════════════════════════════
if ('this_pc' -in $allCategories) {
    Write-Host "  [2/5] Scanning This PC icons..." -ForegroundColor Cyan
    $pcEntries = @()

    $namespacePaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace'
    )

    foreach ($nsRoot in $namespacePaths) {
        if (-not (Test-Path $nsRoot)) { continue }
        $clsidKeys = Get-ChildItem $nsRoot -ErrorAction SilentlyContinue
        foreach ($ck in $clsidKeys) {
            $clsid = Split-Path $ck.PSPath -Leaf
            if ($clsid -in $systemCLSID) { continue }  # Whitelist

            $keyPath = ($ck.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '') -replace '^HKEY_CURRENT_USER\\?', 'HKCU:\' -replace '^HKEY_LOCAL_MACHINE\\?', 'HKLM:\' -replace '^HKEY_CLASSES_ROOT\\?', 'HKCR:\'
            $displayName = ''
            $targetPath = ''

            # Look up CLSID in HKCR
            $clsidKey = "HKCR:\CLSID\$clsid"
            if (Test-Path $clsidKey) {
                $displayName = Get-DisplayName $clsidKey $clsid
                $inprocKey = "$clsidKey\InProcServer32"
                if (Test-Path $inprocKey) {
                    try { $targetPath = (Get-ItemProperty $inprocKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)' } catch {}
                }
                # Also check ShellFolder
                $sfKey = "$clsidKey\ShellFolder"
                if (-not $targetPath -and (Test-Path $sfKey)) {
                    try { $targetPath = (Get-ItemProperty $sfKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)' } catch {}
                }
            }

            if (-not $displayName) { $displayName = "CLSID $clsid" }

            $publisher = Get-Publisher $clsidKey
            $class = Classify-Entry $keyPath $targetPath $displayName $publisher

            # Upgrade: if CLSID is in NameSpace but InProcServer32 missing, it's confirmed junk
            if ($class.tier -ne 'confirmed' -and $clsidKey -and -not (Test-Path "$clsidKey\InProcServer32")) {
                $class = @{ tier = 'suspicious'; evidence = 'CLSID registered but no InProcServer32 (shell namespace only)' }
            }

            $summary[$class.tier]++

            $pcEntries += [PSCustomObject]@{
                key_path     = $keyPath
                display_name = $displayName
                clsid        = $clsid
                tier         = $class.tier
                evidence     = $class.evidence
                target_path  = $targetPath
                publisher    = $publisher
            }
        }
    }

    $allResults += [PSCustomObject]@{
        name    = 'this_pc'
        label   = 'This PC Icons'
        entries = @($pcEntries | Sort-Object { @{ confirmed=0; suspicious=1; clean=2 }[$_.tier] }, display_name)
    }
}

# ═══════════════════════════════════════════
# CATEGORY 3: Uninstall List Residues
# ═══════════════════════════════════════════
if ('uninstall' -in $allCategories) {
    Write-Host "  [3/5] Scanning uninstall list..." -ForegroundColor Cyan
    $uninstallEntries = @()

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($uiRoot in $uninstallPaths) {
        if (-not (Test-Path $uiRoot)) { continue }
        $subkeys = Get-ChildItem $uiRoot -ErrorAction SilentlyContinue
        foreach ($sk in $subkeys) {
            $keyPath = ($sk.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '') -replace '^HKEY_CURRENT_USER\\?', 'HKCU:\' -replace '^HKEY_LOCAL_MACHINE\\?', 'HKLM:\' -replace '^HKEY_CLASSES_ROOT\\?', 'HKCR:\'
            $displayName = ''
            $targetPath = ''
            $publisher = ''

            try {
                $props = Get-ItemProperty $keyPath -ErrorAction SilentlyContinue
                $displayName = $props.DisplayName
                $publisher   = $props.Publisher
                $targetPath  = $props.InstallLocation
                if (-not $targetPath) { $targetPath = $props.UninstallString }
                if (-not $targetPath) { $targetPath = $props.DisplayIcon }
                $isSystemComponent = $props.SystemComponent
            } catch {}

            if (-not $displayName) { continue }  # Skip entries without a name

            # System components check
            if ($isSystemComponent -eq 1) {
                $bloatMatches = Match-Bloatware "$displayName $publisher"
                if ($bloatMatches.Count -gt 0) {
                    $summary['suspicious']++
                    $uninstallEntries += [PSCustomObject]@{
                        key_path     = $keyPath
                        display_name = $displayName
                        tier         = 'suspicious'
                        evidence     = "SystemComponent=1 + bloatware match: $($bloatMatches -join ', ')"
                        target_path  = $targetPath
                        publisher    = $publisher
                    }
                }
                continue
            }

            $class = Classify-Entry $keyPath $targetPath $displayName $publisher
            $summary[$class.tier]++

            $uninstallEntries += [PSCustomObject]@{
                key_path     = $keyPath
                display_name = $displayName
                tier         = $class.tier
                evidence     = $class.evidence
                target_path  = $targetPath
                publisher    = $publisher
            }
        }
    }

    $allResults += [PSCustomObject]@{
        name    = 'uninstall'
        label   = 'Uninstall List'
        entries = @($uninstallEntries | Sort-Object { @{ confirmed=0; suspicious=1; clean=2 }[$_.tier] }, display_name)
    }
}

# ═══════════════════════════════════════════
# CATEGORY 4: Explorer Bar / Shell Extensions
# ═══════════════════════════════════════════
if ('explorer_bar' -in $allCategories) {
    Write-Host "  [4/5] Scanning Explorer shell extensions..." -ForegroundColor Cyan
    $explorerEntries = @()

    $explorerPaths = @(
        'HKCR:\Drive\shellex\ContextMenuHandlers',
        'HKCR:\Drive\shellex\FolderExtensions',
        'HKCR:\Folder\shellex\ContextMenuHandlers',
        'HKCR:\Folder\shellex\ColumnHandlers'
        # 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell'  # Windows built-in commands (shell32.dll), never junk
    )

    foreach ($exRoot in $explorerPaths) {
        if (-not (Test-Path $exRoot)) { continue }
        $subkeys = Get-ChildItem $exRoot -ErrorAction SilentlyContinue
        foreach ($sk in $subkeys) {
            $keyPath = ($sk.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '') -replace '^HKEY_CURRENT_USER\\?', 'HKCU:\' -replace '^HKEY_LOCAL_MACHINE\\?', 'HKLM:\' -replace '^HKEY_CLASSES_ROOT\\?', 'HKCR:\'
            $displayName = Get-DisplayName $keyPath (Split-Path $keyPath -Leaf)
            $targetPath = ''
            $publisher = Get-Publisher $keyPath

            # Check command subkey
            $cmdKey = Join-Path $keyPath 'command'
            if (Test-Path $cmdKey) {
                try { $targetPath = (Get-ItemProperty $cmdKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)' } catch {}
            } else {
                # Shellex CLSID
                try {
                    $clsid = (Get-ItemProperty $keyPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
                    if ($clsid -and $clsid -match '\{[\w-]+\}') {
                        $inprocKey = "HKCR:\CLSID\$clsid\InProcServer32"
                        if (Test-Path $inprocKey) {
                            $targetPath = (Get-ItemProperty $inprocKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
                        }
                    }
                } catch {}
            }

            $class = Classify-Entry $keyPath $targetPath $displayName $publisher
            $summary[$class.tier]++

            $explorerEntries += [PSCustomObject]@{
                key_path     = $keyPath
                display_name = $displayName
                tier         = $class.tier
                evidence     = $class.evidence
                target_path  = $targetPath
                publisher    = $publisher
            }
        }
    }

    $allResults += [PSCustomObject]@{
        name    = 'explorer_bar'
        label   = 'Explorer Extensions'
        entries = @($explorerEntries | Sort-Object { @{ confirmed=0; suspicious=1; clean=2 }[$_.tier] }, display_name)
    }
}

# ═══════════════════════════════════════════
# CATEGORY 5: Broken Scheduled Tasks
# ═══════════════════════════════════════════
if ('scheduled_tasks' -in $allCategories) {
    Write-Host "  [5/5] Scanning scheduled tasks..." -ForegroundColor Cyan
    $taskEntries = @()

    try {
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
        $tasks = @()
        if ($allTasks) {
            $tasks = @($allTasks | Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' })
        }

        foreach ($t in $tasks) {
            $taskInfo = Get-ScheduledTaskInfo $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
            $lastResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { 0 }

            if ($lastResult -eq 0) { continue }  # Task ran successfully, skip

            # Extract target path from task actions
            $targetPath = ''
            try {
                $actions = $t.Actions
                foreach ($a in $actions) {
                    if ($a.Execute) { $targetPath = $a.Execute; break }
                }
            } catch {}

            $displayName = "$($t.TaskPath)$($t.TaskName)"
            $class = Classify-Entry $t.TaskPath $targetPath $displayName ''

            # Scheduled task with failed last run + missing exe = confirmed junk
            if ($class.tier -ne 'confirmed' -and -not (Test-PathExists $targetPath)) {
                $class = @{ tier = 'confirmed'; evidence = "Last run failed (result=$lastResult) + target missing: $targetPath" }
            } elseif ($class.tier -eq 'clean') {
                $class = @{ tier = 'suspicious'; evidence = "Last run failed (result=$lastResult)" }
            }

            $summary[$class.tier]++

            $taskEntries += [PSCustomObject]@{
                key_path     = $t.TaskPath + $t.TaskName
                display_name = $displayName
                tier         = $class.tier
                evidence     = $class.evidence
                target_path  = $targetPath
                publisher    = ''
            }
        }
    } catch {
        Write-Host "    [WARN] Cannot enumerate scheduled tasks — run as Administrator for this category" -ForegroundColor Yellow
    }

    $allResults += [PSCustomObject]@{
        name    = 'scheduled_tasks'
        label   = 'Scheduled Tasks'
        entries = @($taskEntries | Sort-Object { @{ confirmed=0; suspicious=1; clean=2 }[$_.tier] }, display_name)
    }
}

# ── Output ──
if ($Json) {
    $output = [PSCustomObject]@{
        categories = $allResults
        summary    = [PSCustomObject]$summary
    }
    Write-Output ($output | ConvertTo-Json -Depth 5 -Compress)
    exit 0
} else {
    # Color-coded table output
    foreach ($cat in $allResults) {
        $confirmedCount = ($cat.entries | Where-Object { $_.tier -eq 'confirmed' }).Count
        $suspiciousCount = ($cat.entries | Where-Object { $_.tier -eq 'suspicious' }).Count
        Write-Host "`n  $($cat.label) — " -ForegroundColor Cyan -NoNewline
        Write-Host "$($cat.entries.Count) entries " -NoNewline
        if ($confirmedCount -gt 0) { Write-Host "🔴$confirmedCount " -NoNewline -ForegroundColor Red }
        if ($suspiciousCount -gt 0) { Write-Host "🟡$suspiciousCount " -NoNewline -ForegroundColor Yellow }
        Write-Host ""

        foreach ($e in $cat.entries) {
            $color = switch ($e.tier) {
                'confirmed'  { 'Red' }
                'suspicious' { 'Yellow' }
                'clean'      { 'DarkGray' }
            }
            $tierSymbol = switch ($e.tier) {
                'confirmed'  { '🔴' }
                'suspicious' { '🟡' }
                'clean'      { '  ' }
            }
            Write-Host "    $tierSymbol $($e.display_name)" -ForegroundColor $color
            Write-Host "       $($e.evidence)" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n  ─────────────────────────" -ForegroundColor DarkGray
    Write-Host "  Confirmed : $($summary.confirmed) (preselected for deletion)" -ForegroundColor Red
    Write-Host "  Suspicious: $($summary.suspicious) (review needed)" -ForegroundColor Yellow
    Write-Host "  Clean     : $($summary.clean) (hidden by default)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Run with -Json for machine-readable output." -ForegroundColor Cyan
}

exit 0

