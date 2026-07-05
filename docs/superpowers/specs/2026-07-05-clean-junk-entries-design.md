# clean-junk-entries — Design Spec

## Summary

A Windows PowerShell skill that scans the registry and Task Scheduler for junk entries left behind by uninstalled software — right-click context menu items, This PC virtual folder icons, Control Panel uninstall list residues, Explorer toolbar remnants, and broken scheduled tasks. Results are classified into three tiers (confirmed junk / suspicious / clean) so the user can safely decide what to remove. Every deletion is backed up as a .reg file with a restore script.

## Interaction Flow

1. **Scan** — Agent runs `scan.ps1 -Json`, reads structured results.
2. **Summary** — "Found X confirmed junk, Y suspicious, Z clean items."
3. **Triage** — 🔴 confirmed junk shown first, user batch-confirms deletion. 🟡 suspicious items shown next, user decides per item or per vendor.
4. **Execute** — Agent passes confirmed key list to `clean.ps1`. Each key is exported to .reg, then deleted, then verified.
5. **Report** — How many deleted, backup location, restore instructions.

## Scan Targets (5 Categories)

| # | Category | Registry / System Locations | Junk Criteria |
|---|----------|---------------------------|---------------|
| 1 | Context menu residues | `HKCR\*\shell`, `HKCR\*\shellex\ContextMenuHandlers`, `HKCR\Directory\shell`, `HKCR\Directory\shellex`, `HKCR\Drive\shell`, `HKCR\DesktopBackground\shell` | Referenced exe/dll path does not exist |
| 2 | This PC icon entries | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\`, `HKCU\SOFTWARE\...\MyComputer\NameSpace\` + corresponding `HKCR\CLSID\{...}` | CLSID target dll missing; or owning software uninstalled |
| 3 | Uninstall list residues | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`, `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\`, `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\` | `InstallLocation` or `UninstallString` targets missing; or `SystemComponent=1` with suspicious publisher |
| 4 | Explorer shell extensions | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell\`, `HKCR\Drive\shellex\`, `HKCR\Folder\shellex\` | Same as #1 |
| 5 | Broken scheduled tasks | `Get-ScheduledTask` under `\Microsoft\Windows\*` (non-system), and user-created tasks | LastRunResult = failed + task action path does not exist |

## Classification Tiers

| Tier | Label | Rule | Default Action |
|------|-------|------|----------------|
| 🔴 `confirmed` | Confirmed junk | Target exe/dll path does not exist on disk; or CLSID InProcServer32 missing | **Preselect for deletion** |
| 🟡 `suspicious` | Suspicious | No digital signature on target; publisher name matches known domestic bloatware list; key recreated itself after prior deletion (regeneration check) | Show, user decides |
| 🟢 `clean` | Working but removable | Valid, signed target exists but user wants to clean up | Show only if user asks |

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/scan.ps1` | Scan 5 categories → classify into 3 tiers → output JSON |
| `scripts/clean.ps1` | Accept key list → export .reg backup per key → delete → verify → report JSON |
| `scripts/restore.ps1` | List backup snapshots → user picks one → import .reg files |

**Usage:**
```powershell
# Scan everything
powershell -File scripts/scan.ps1 -Json
powershell -File scripts/scan.ps1    # human-readable table

# Clean specific keys
powershell -File scripts/clean.ps1 -Keys @("HKCR\*\shell\douyin_wallpaper", "HKLM\SOFTWARE\...\NameSpace\{...}") -WhatIf
powershell -File scripts/clean.ps1 -Keys @(...) -Force

# Restore from backup
powershell -File scripts/restore.ps1
powershell -File scripts/restore.ps1 -List
powershell -File scripts/restore.ps1 -Restore "2026-07-05_14-30-00"
```

## Backup & Restore

- Backup directory: `%USERPROFILE%\Amuin\backups\clean-junk-entries\<yyyy-MM-dd_HH-mm-ss>\`
- Each deleted key exported as a separate .reg file named after the sanitized key path
- A `manifest.json` records: timestamp, keys deleted, original values, .reg filenames
- `restore.ps1` reads manifests, lists snapshots, imports selected snapshot's .reg files
- After cleanup, Agent prints the backup path and reminds user how to restore

## Safety Gates

1. **Admin required** — script self-checks and elevates if needed
2. **Pre-deletion .reg export** — every key exported before deletion; abort if export fails
3. **System CLSID whitelist** — known Windows CLSIDs (Recycle Bin, Control Panel, etc.) are never flagged
4. **`-WhatIf` mode** — dry-run shows what would be deleted
5. **Tier-gated defaults** — 🔴 confirmed = preselected; 🟡 suspicious = shown but NOT preselected; 🟢 clean = hidden by default
6. **Verification after delete** — check key is actually gone before reporting success

## Known Bloatware Publisher Patterns (for 🟡 classification)

A configurable list of substrings matched against publisher names, display names, and CLSID descriptions. Default includes patterns commonly seen in domestic bloatware: `抖音`, `小智`, `壁纸`, `WPS`, `360`, `腾讯`, `百度`, `迅雷`, `快压`, `驱动精灵`, etc. This list is in a comment-based config block at the top of scan.ps1, editable by the user.

## Non-Goals

- Real-time registry monitoring (not a resident tool)
- Deleting files — registry-only cleanup
- Cleaning up residual files/folders from uninstalled apps (different skill)
- Cross-platform support (Windows-only, like other Amuin skills)
