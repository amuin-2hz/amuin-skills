---
name: free-c-drive-space
description: Use when C drive is running low on space due to package manager caches, iPhone/iPad backups (Apple Devices), Gradle/Maven caches, or other large data directories that can be relocated to another drive via Windows directory junctions (mklink /j). Also use when checking whether existing directories are already junctioned.
---

# Free C Drive Space via Directory Junctions

## Overview

Windows **directory junctions** (`mklink /j`) make a folder at one path transparently read/write to another drive. Apps see a normal folder; all I/O actually hits the target drive. No app config changes needed.

**Core principle:** Copy → Verify → Delete → Junction. Never skip verification.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/scan.ps1` | Scan all known cache locations, report size + junction status |
| `scripts/migrate.ps1` | Full pipeline: copy → verify → delete → junction. Safety gates at each step. |
| `scripts/verify-junctions.ps1` | Health check — are all known junctions alive? |

**Usage:**
```powershell
# See what's eating C drive
powershell -File scripts/scan.ps1

# Migrate a large directory (prompts for confirmation)
powershell -File scripts/migrate.ps1 -Source "$env:LOCALAPPDATA\npm-cache" -Target "H:\Cache\npm-cache"

# Skip confirmation for automation
powershell -File scripts/migrate.ps1 -Source "..." -Target "..." -Force

# Preview what would happen
powershell -File scripts/migrate.ps1 -Source "..." -Target "..." -DryRun

# Check all junctions are healthy
powershell -File scripts/verify-junctions.ps1
```

## Supported Targets

| Source (C drive) | Typical Size |
|---|---|
| `%USERPROFILE%\Apple\MobileSync\Backup` | 10–200 GB |
| `%LOCALAPPDATA%\npm-cache` | 500 MB–2 GB |
| `%APPDATA%\npm` | 200 MB–1 GB |
| `%LOCALAPPDATA%\pip\cache` | 100 MB–2 GB |
| `%USERPROFILE%\.gradle` | 1–10 GB |
| `%USERPROFILE%\.m2` | 500 MB–5 GB |
| `%APPDATA%\Apple Computer\MobileSync\Backup` | varies (old iTunes) |

## Unsupported — Do NOT Use Junctions

| Tool | Reason | Alternative |
|---|---|---|
| **pnpm** | Content-addressable store uses hardlinks; cross-drive copy explodes size 3–4× | `pnpm config set store-dir H:\...` |
| **Docker** | Uses VHDX disk images | Settings → Docker Engine → data-root |
| **WSL** | Uses VHDX virtual disks | `wsl --export` / `wsl --import` |

## Migrate Script Safety Gates

`scripts/migrate.ps1` enforces these checks before any destructive action:

1. Source must exist and NOT already be a junction
2. Target must NOT already exist
3. Target drive must have ≥ source size + 1 GB free
4. User confirmation (unless `-Force`)
5. Copies, then **compares file counts** — aborts and **preserves original** on mismatch
6. Only after count match: deletes original, creates junction
7. **Final check**: verifies the created item is actually a junction

## Apple Devices Path Change (vs Old iTunes)

| Data | Old Path | New Path (Apple Devices Store App) |
|---|---|---|
| Backup | `%APPDATA%\Apple Computer\MobileSync\Backup\` | `%USERPROFILE%\Apple\MobileSync\Backup\` |
| iOS firmware | `%APPDATA%\...\iTunes\iPhone Software Updates` | `%LOCALAPPDATA%\Packages\AppleInc.AppleDevices_*\LocalCache\...` |
| Device pairing | `%PROGRAMDATA%\Apple\Lockdown\` | Same |
| Temp files | `%PROGRAMDATA%\Apple Computer\iTunes\iPhone Temporary Files\` | Removed |

## Common Mistakes

| Mistake | Reality |
|---------|---------|
| Junction folder shows content in `ls` → "didn't work" | Junctions LOOK like normal folders. Use `scan.ps1` or `Get-Item -Force \| Select LinkType` to verify |
| Using old iTunes paths for Apple Devices | Apple Devices uses `%USERPROFILE%\Apple\MobileSync\` |
| Deleting original before verifying copy | `migrate.ps1` prevents this — always verify file counts first |
| robocopy `/E` flag eaten by bash | `migrate.ps1` handles this internally |
| `/COPYALL` needs admin | `migrate.ps1` uses `/COPY:DAT` |
