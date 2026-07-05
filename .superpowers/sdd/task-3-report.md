# Task 3 Report: restore.ps1 — Implementation Report

## Status: Implemented

### Files Created
- `clean-junk-entries/scripts/restore.ps1` — 107 lines

### What It Does
1. Lists backup snapshots with `-List` (also default when no args supplied)
2. Restores `.reg` files from a named snapshot with `-Restore <timestamp>`
3. Reads `manifest.json` in each snapshot to show deleted key count
4. Reports success/failure counts per imported `.reg` file

### Parameters
| Param | Type | Description |
|-------|------|-------------|
| `-List` | Switch | Show all backup snapshots |
| `-Restore` | String | Timestamp folder name of the snapshot to restore |

### Behavior
- **No args / `-List`**: Scans `%USERPROFILE%\Amuin\backups\clean-junk-entries\` for snapshot directories, displays a table with timestamp, key count, reg file count, and path. Exits 0.
- **`-Restore <timestamp>`**: Finds the snapshot folder, iterates `.reg` files within, runs `reg import` on each. Shows per-file success/failure. Exits 0 if all succeed, 1 if any fail.
- **Backup root missing**: Prints a yellow warning and exits 0.
- **Snapshot not found**: Prints a red error with exit 1.

### Smoke Test Results
| Command | Output | Exit |
|---------|--------|------|
| `restore.ps1` (no args) | "No snapshots found." | 0 |
| `restore.ps1 -List` | "No snapshots found." | 0 |
| `restore.ps1 -Restore "nonexistent"` | "[ERROR] Snapshot not found: ..." | 1 |

### Verification
- Code matches brief exactly (List mode, Restore mode, error handling, exit codes, table formatting)
- No post-implementation fixes required

### Next: Task 4 — test.ps1
