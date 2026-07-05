---
name: free-drive-space
description: Use when any drive is running low on space and large data directories (iPhone backups, browser profiles, WeChat files, package caches, dev tools) need to be relocated to another drive via Windows directory junctions (mklink /j). Works for any drive, not just C. Also use when checking whether existing directories are already junctioned.
---

# Free Drive Space via Directory Junctions

## Overview

Windows **directory junctions** (`mklink /j`) make a folder at one path transparently read/write to another drive. Apps see a normal folder; all I/O actually hits the target drive. No app config changes needed.

Works for **any drive**, not just C. If a folder is on the wrong drive, junction it.

**Core principle:** Copy → Verify → Delete → Junction. Never skip verification.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/scan.ps1` | Scan all known space hogs, report size + junction status |
| `scripts/migrate.ps1` | Full pipeline: copy → verify → delete → junction. Safety gates at each step. |
| `scripts/verify-junctions.ps1` | Health check — are all known junctions alive? |

**Usage:**
```powershell
# See what's eating your drives
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

| Source | Typical Size | Note |
|--------|-------------|------|
| `%USERPROFILE%\Apple\MobileSync\Backup` | 10–200 GB | Apple Devices (modern iTunes replacement) |
| `%LOCALAPPDATA%\Google\Chrome\User Data` | 2–20 GB | Close Chrome before migrating |
| `%LOCALAPPDATA%\Microsoft\Edge\User Data` | 1–10 GB | Close Edge before migrating |
| `%USERPROFILE%\Documents\WeChat Files` | 1–100 GB | Close WeChat before migrating |
| `%APPDATA%\Tencent\WeChat` | 500 MB–5 GB | WeChat app data (stickers, mini-programs) |
| `%USERPROFILE%\Documents\Tencent Files` | 500 MB–20 GB | QQ files |
| `%LOCALAPPDATA%\npm-cache` | 500 MB–2 GB | npm package download cache |
| `%APPDATA%\npm` | 200 MB–1 GB | npm global packages |
| `%LOCALAPPDATA%\pip\cache` | 100 MB–2 GB | pip wheel cache |
| `%USERPROFILE%\.gradle` | 1–10 GB | Gradle build cache |
| `%USERPROFILE%\.m2` | 500 MB–5 GB | Maven local repository |
| `%APPDATA%\Apple Computer\MobileSync\Backup` | varies | Old iTunes backup |

## Unsupported — Do NOT Use Junctions

| Tool | Reason | Alternative |
|---|---|---|
| **pnpm** | Content-addressable store uses hardlinks; cross-drive copy explodes size | `pnpm config set store-dir H:\...` |
| **Docker** | Uses VHDX disk images | Settings → Docker Engine → data-root |
| **WSL** | Uses VHDX virtual disks | `wsl --export` / `wsl --import` |

## Important: Close Apps Before Migrating

For browsers (Chrome/Edge) and chat apps (WeChat/QQ): **close the app completely** before migration. Check Task Manager to make sure no background processes remain. The app will work normally after the junction is created.

## Migrate Script Safety Gates

`scripts/migrate.ps1` enforces these checks before any destructive action:

1. Source must exist and NOT already be a junction
2. Target must NOT already exist
3. Target drive must have >= source size + 1 GB free
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
| Junction folder shows content in `ls` -> "didn't work" | Junctions LOOK like normal folders. Use `scan.ps1` or `Get-Item -Force \| Select LinkType` to verify |
| Using old iTunes paths for Apple Devices | Apple Devices uses `%USERPROFILE%\Apple\MobileSync\` |
| Deleting original before verifying copy | `migrate.ps1` prevents this — always verify file counts first |
| robocopy `/E` flag eaten by bash | `migrate.ps1` handles this internally |
| `/COPYALL` needs admin | `migrate.ps1` uses `/COPY:DAT` |
| Migrating while app is running | Close Chrome/Edge/WeChat/QQ before migrating their folders |
