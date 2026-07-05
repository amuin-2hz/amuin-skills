# clean-junk-entries

Clean up registry junk left behind by uninstalled software. Context menus that won't go away, This PC icons that keep coming back, broken uninstall list entries — scanned, classified, and safely removed with full .reg backup.

## Quick Start

```powershell
# Step 1: Scan (needs admin for full access)
powershell -File scripts/scan.ps1

# Step 2: Review the 🔴 confirmed and 🟡 suspicious entries, then clean
powershell -File scripts/clean.ps1 -Keys @("HKCR:\*\shell\bad_entry", "HKLM:\...") -Force

# Step 3: If you made a mistake, restore
powershell -File scripts/restore.ps1 -List
powershell -File scripts/restore.ps1 -Restore "<timestamp>"

# Preview before deleting
powershell -File scripts/clean.ps1 -Keys @("...") -WhatIf
```

## What It Cleans

| Category | Examples |
|----------|----------|
| Context menus | Right-click entries from uninstalled apps, wallpaper/shortcut tools |
| This PC icons | Tencent Video, Baidu Netdisk, WPS cloud — icons in 此电脑 that won't delete |
| Uninstall list | Programs in Settings → Apps that are already gone but still listed |
| Explorer extensions | Toolbar buttons, shell extensions from removed software |
| Scheduled tasks | Broken tasks that run (and fail) for programs that no longer exist |

## 3-Tier Safety

🔴 **Confirmed junk** — target exe/dll missing. Safe to delete. *Preselected.*
🟡 **Suspicious** — unsigned exe, or bloatware publisher match, or partial residue. *User must review and approve.*
🟢 **Clean** — valid, signed entry. *Hidden by default.*

## Safety

- Every deleted key is exported as a `.reg` file to `%USERPROFILE%\Amuin\backups\clean-junk-entries\<timestamp>\`
- `restore.cmd` in the backup folder for double-click restore
- System CLSIDs (Recycle Bin, Control Panel, etc.) are whitelisted and never flagged
- Dry-run mode (`-WhatIf`) shows what would happen before touching anything

## Requirements

- Windows 10+ (PowerShell 5.1+)
- Administrator rights for full scan and deletion

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Agent skill — loaded by AI coding assistants |
| `scripts/scan.ps1` | 5-category registry scan with 3-tier classification |
| `scripts/clean.ps1` | Backup .reg → delete registry key → verify |
| `scripts/restore.ps1` | List and restore backup snapshots |
| `scripts/test.ps1` | Self-test with temp keys and real known-junk detection |

## Limits

- Registry only — does not delete residual files/folders (use delete-stubborn-files for those)
- Some entries may regenerate if the software has a self-repair mechanism (re-scan after reboot)
- Bloatware pattern list is subjective; edit the `$bloatwarePatterns` array in scan.ps1 to customize
