# free-c-drive-space

Reclaim C drive space on Windows via directory junctions (`mklink /j`).

Transparently redirect large cache/backup directories to another drive. Apps never notice.

## Quick Start

```powershell
# See what's eating C drive
powershell -File scripts/scan.ps1

# Migrate a directory (safe: verifies before deleting)
powershell -File scripts/migrate.ps1 -Source "C:\path\to\big-folder" -Target "H:\Cache\big-folder"

# Skip confirmation for automation
powershell -File scripts/migrate.ps1 -Source "..." -Target "..." -Force

# Preview what would happen
powershell -File scripts/migrate.ps1 -Source "..." -Target "..." -DryRun

# Check all junctions are healthy
powershell -File scripts/verify-junctions.ps1
```

## Supported Targets

Apple Devices backups, npm cache, npm global packages, pip cache, Gradle, Maven, old iTunes backups.

## Unsupported

**pnpm** (hardlinks break across drives — use `pnpm config set store-dir` instead), Docker (VHDX), WSL (VHDX).

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Agent skill — loaded by AI coding assistants |
| `scripts/scan.ps1` | Scan C drive for cache directories, report size + junction status |
| `scripts/migrate.ps1` | Safe migration pipeline: copy → verify → delete → junction |
| `scripts/verify-junctions.ps1` | Health check all known junctions |

## Safety

`migrate.ps1` enforces:

1. Source exists and is not already a junction
2. Target does not already exist
3. Target drive has enough free space
4. User confirmation (skip with `-Force`)
5. **File count verification before deletion** — aborts on mismatch, preserves original
6. Final junction type check after creation
