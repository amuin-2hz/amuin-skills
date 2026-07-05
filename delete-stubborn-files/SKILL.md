---
name: delete-stubborn-files
description: Use when Windows refuses to delete a file or folder — path too long, reserved names (CON/PRN/NUL), trailing spaces/dots, broken junctions, permission denied, locked by process, or cyclic links. The file appears normal but Explorer won't touch it.
---

# Delete Stubborn Files on Windows

## Overview

Windows has multiple independent reasons a file won't delete. Each requires a different weapon. Trying the wrong one wastes time; trying the right sequence almost always works.

7 causes, 5 weapons, 1 script: `scripts/fix.ps1`

## Diagnosis Tree

| # | Symptom (error message) | Cause | Weapon |
|---|---|---|---|
| 1 | "文件名对目标文件夹太长" / "Path too long" | Path > 260 chars | `\\?\` long-path prefix |
| 2 | "找不到该项目" / "Could not find this item" | Trailing space or dot in filename | `\\?\` + `rmdir` |
| 3 | Nothing — just refuses when the name is CON, PRN, NUL, AUX, COM1-9, LPT1-9 | Reserved DOS device name | `\\?\` prefix |
| 4 | "文件正在被另一个程序使用" / "File in use" | Process has open handle | Find PID → kill → delete |
| 5 | "你需要权限才能执行此操作" / "Access denied" | Ownership / ACL missing | `takeown` + `icacls` |
| 6 | Folder has junction arrow, `ls` shows infinite nesting | Cyclic or broken junction | `rmdir` (no `/s` — critical!) |
| 7 | No error, but file reappears | Sync app (OneDrive, Defender) restoring it | Pause sync, check quarantine |

## Usage

```powershell
# Diagnose only (safe — no deletion)
powershell -File scripts/fix.ps1 -Path "C:\path\to\stubborn\file"

# Diagnose AND delete
powershell -File scripts/fix.ps1 -Path "C:\path\to\stubborn\file" -Force
```

## Weapons (Escalation Order)

`fix.ps1 -Force` tries these in sequence, stopping on success:

1. **Standard delete** — `Remove-Item -Recurse -Force`
2. **Strip attributes** — clears ReadOnly/Hidden, then retries
3. **`\\?\` long path** — bypasses 260-char MAX_PATH and reserved name checks
4. **`cmd rmdir`** — handles junctions correctly (no `/s` for junction points)
5. **`takeown` + `icacls`** — seizes ownership + grants full control

If all 5 fail: the file likely has a **kernel-level lock** (driver, antivirus). Safe Mode is the next step.

## Optional: Handle.exe for Process Detection

If `handle64.exe` (Sysinternals) is present in the scripts directory, fix.ps1 will auto-detect which process is locking the file. Download from:
```
https://learn.microsoft.com/en-us/sysinternals/downloads/handle
```

Without it, the script still works — it just can't tell you *which* process is locking.

## Key Insight: Junction Deletion Trap

When deleting a junction point, **NEVER use `-Recurse` / `/s`**. Recursive delete follows the junction and tries to delete the TARGET folder's contents. `rmdir` (no `/s`) removes only the junction link itself.

This is why `fix.ps1` weapon 4 detects junctions and switches to non-recursive `cmd rmdir`.

## Common Mistakes

| Mistake | Reality |
|---------|---------|
| Using `rmdir /s` on a junction | Deletes TARGET content, not just the link. Use `rmdir` without `/s`. |
| `\\\\?\\` with wrong slashes | Must be exactly `\\?\C:\...` — two backslashes, question mark, then the path |
| `takeown` without admin | Needs elevated PowerShell. The script handles this gracefully. |
| Giving up after one weapon | Some files need multiple weapons chained. Let `-Force` escalate. |
