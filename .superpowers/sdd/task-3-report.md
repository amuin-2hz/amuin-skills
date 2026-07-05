# Task 3 Report: remove-duplicates.ps1

## Files
- Created: `duplicate-file-killer/scripts/remove-duplicates.ps1`

## Interface
| Parameter   | Type       | Mandatory | Description                                      |
|-------------|------------|-----------|--------------------------------------------------|
| `-Files`    | `String[]` | Yes       | Paths of files/directories to remove             |
| `-WhatIf`   | `switch`   | No        | Dry-run — show intended actions, no actual delete |
| `-Permanent`| `switch`   | No        | Skip Recycle Bin; use `Remove-Item -Force` instead |

## Behavior
- Default mode: move to Windows Recycle Bin via `Shell.Application` COM (`InvokeVerb('delete')`)
- `-Permanent` mode: direct `Remove-Item -Force -Recurse`
- `-WhatIf` mode: log intent, produce mock results, no filesystem changes
- `$ErrorActionPreference = 'Continue'` — a single file failure does not abort the batch
- Output: per-file status objects as compressed JSON on stdout; colored progress on console

## Smoke Test Results

### Test 1: Dry-run with nonexistent file
```
-WhatIf -Files @("$env:TEMP\nonexistent.xyz")
```
- Correctly showed `DRY RUN — nothing will be deleted.`
- Reported `[SKIP] Already gone` for the nonexistent path
- JSON output: `{"Path":"...","Status":"already_gone","FreedBytes":0,"Error":""}`

### Test 2: Dry-run with -Permanent
```
-WhatIf -Permanent -Files @("$env:TEMP\nonexistent.xyz")
```
- Correctly showed `Mode: PERMANENT` and dry-run banner
- Reported `[SKIP] Already gone` for the nonexistent path

### Test 3: Real delete via Recycle Bin
```
-Files @("$env:TEMP\amuin-remove-test.txt")
```
- Created temp file with content "test content"
- Script reported `[OK]` and confirmed deletion
- `Test-Path` after execution: file no longer present on disk
- JSON output: `{"Path":"...","Status":"deleted","FreedBytes":17,"Error":""}`
- Console showed recycle-bin hint: "Files are in Recycle Bin — empty it to permanently free space."

All three tests passed successfully.

## Fixes Applied (2026-07-05)

- **Exit code**: Added `if ($failed -gt 0) { exit 1 } else { exit 0 }` after the final summary `Write-Host` line, so `$LASTEXITCODE` is 0 on full success and 1 if any file failed.
- **COM cleanup**: Added `[System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null` after `InvokeVerb('delete')` in `Move-ToRecycleBin` to release the `Shell.Application` COM object immediately after use.
