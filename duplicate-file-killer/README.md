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
