# delete-stubborn-files

Windows refuses to delete a file. You've tried everything. This fixes it.

7 causes, 5 escalating weapons, 1 script.

## Quick Start

```powershell
# Diagnose what's wrong (safe — no deletion)
powershell -File scripts/fix.ps1 -Path "C:\path\to\stubborn\file"

# Fix it
powershell -File scripts/fix.ps1 -Path "C:\path\to\stubborn\file" -Force
```

## What It Handles

| Cause | Example |
|-------|---------|
| Path too long (>260 chars) | Deep `node_modules`, nested backups |
| Reserved name | File named `CON`, `PRN`, `NUL`, `COM1` |
| Trailing space/dot | `folder.` or `file ` — Explorer can create but not delete |
| Locked by process | App still has the file open |
| Permission denied | From another Windows install, corrupted ACL |
| Broken/cyclic junction | Junction pointing to nothing or itself |

## Safety

Running without `-Force` only diagnoses — no changes made.

With `-Force`, weapons escalate from safest to most aggressive, stopping on success.
