---
name: clean-junk-entries
description: Use when the user wants to clean up residual registry entries from uninstalled software — right-click context menus, This PC icons that won't go away, broken uninstall list entries, Explorer toolbar remnants, or failed scheduled tasks. Also use when the user complains about "ghost entries", "stuff that keeps coming back", or specific bloatware residue (Tencent Video icon, Douyin wallpaper menu, etc.).
---

# Clean Junk Registry Entries

## Overview

Software uninstalls are rarely clean. They leave behind context menu items, This PC icon entries, uninstall list residues, Explorer shell extensions, and broken scheduled tasks. Many are invisible to standard PC cleaning tools.

This skill scans 5 categories, classifies findings into 3 tiers, backs up every key as .reg before deletion, and provides a one-click restore path.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/scan.ps1` | Scan 5 registry/system categories → 3-tier (confirmed/suspicious/clean) → JSON or table |
| `scripts/clean.ps1` | Accept key list → reg export backup per key → delete → verify → report |
| `scripts/restore.ps1` | List backup snapshots → import selected snapshot's .reg files |

**Usage:**
```powershell
# Scan everything (table mode)
powershell -File scripts/scan.ps1

# Scan specific categories only
powershell -File scripts/scan.ps1 -Categories context_menu,this_pc

# JSON output for agent consumption
powershell -File scripts/scan.ps1 -Json

# Dry-run cleanup
powershell -File scripts/clean.ps1 -Keys @("HKCR:\*\shell\bad_entry") -WhatIf

# Real cleanup
powershell -File scripts/clean.ps1 -Keys @("HKCR:\...", "HKLM:\...") -Force

# Also delete associated CLSID keys (for This PC icon entries)
powershell -File scripts/clean.ps1 -Keys @("HKLM:\SOFTWARE\...\NameSpace\{...}") -Force -AlsoDeleteCLSID

# List backup snapshots
powershell -File scripts/restore.ps1 -List

# Restore a snapshot
powershell -File scripts/restore.ps1 -Restore "2026-07-05_14-30-00"
```

## 3-Tier Classification

| Tier | Symbol | Rule | Default Action |
|------|--------|------|----------------|
| Confirmed junk | 🔴 | Target exe/dll file does not exist on disk | **Preselected** for deletion |
| Suspicious | 🟡 | No digital signature + publisher matches known bloatware; or CLSID without InProcServer32 | Show, user decides |
| Clean | 🟢 | Valid, signed target exists | Hidden by default |

## Agent Instruction: Full Cleanup Workflow

### Phase 1: Scan

```
ACTION: Run scan.ps1 -Json (needs admin for full results — warn user if not elevated).
READ the JSON output.

REPORT summary:
  "Found:
   🔴 X confirmed junk entries (target files missing — safe to delete)
   🟡 Y suspicious entries (unsigned or bloatware publisher — review needed)
   🟢 Z clean entries (working, hidden)"
```

### Phase 2: Triage — Confirmed Junk

```
SHOW all 🔴 confirmed entries grouped by category.
ASK: "These {X} entries have missing target files. Safe to delete all?"
  → Yes: add all to delete list
  → No: "Which should I skip?" — remove user's picks from delete list
  → "Show me details on a specific one" — show full key path, display name, evidence
```

### Phase 3: Triage — Suspicious

```
SHOW 🟡 suspicious entries, one category at a time.
For each: show display name, publisher, evidence, target path.
ASK per entry or per vendor: "Delete?"
  → Yes: add to delete list
  → No: skip
  → "Delete all from <vendor>" : batch-add matching entries

IMPORTANT: Default is NO for suspicious entries. The user must explicitly opt in.
```

### Phase 4: Execute

```
SHOW final summary: "Will delete {N} registry keys."
CONFIRM with user.

ACTION: Run clean.ps1 with the confirmed key list.
  - Use -AlsoDeleteCLSID for This PC entries (deletes both the NameSpace key and the HKCR\CLSID)
  - Use -Force to skip per-key confirmation

REPORT:
  - How many deleted, how many failed
  - Backup directory path
  - "To undo: run restore.ps1 -Restore '<timestamp>' or double-click restore.cmd in the backup folder"
```

### Phase 5: Verify (Optional but Recommended)

```
ASK: "Want me to re-scan to verify everything is gone?"
  → Yes: run scan.ps1 -Json again, confirm the deleted entries no longer appear
  → No: done
```

## Safety Rules

1. **Admin required** — scripts warn if not elevated; registry modifications need admin.
2. **Every key backed up as .reg** — clean.ps1 exports before deleting; abort if export fails.
3. **System CLSID whitelist** — This PC, Recycle Bin, Network, Control Panel and other system folders are never flagged.
4. **Default to safe** — 🔴 confirmed = preselected; 🟡 suspicious = NOT preselected; 🟢 clean = hidden.
5. **Restore path always reported** — backup directory and restore instructions shown after every cleanup.
6. **Dry-run always available** — `-WhatIf` shows what would happen without touching anything.

## Common Mistakes

| Mistake | Reality |
|---------|---------|
| Deleting This PC NameSpace key without deleting CLSID | The icon may be controlled by the CLSID key too. Use `-AlsoDeleteCLSID`. |
| Not running as admin | Scan works partially without admin, but most deletions will fail. Always elevate. |
| Deleting system CLSIDs | The whitelist prevents this, but if the user manually specifies a system CLSID, warn them. |
| Forgetting the restore path | The backup directory is always printed. restore.cmd is in the backup folder for double-click restore. |
| Running scan once and assuming it's comprehensive | Some entries only appear after the software tries to repair itself. Re-scan after a reboot if something came back. |
