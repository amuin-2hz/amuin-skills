---
name: duplicate-file-killer
description: Use when the user wants to find and delete duplicate files — photos, downloads, documents that have identical copies scattered across different folders. Also use when the user reports disk space issues and wants to check if duplicates are contributing.
---

# Duplicate File Killer

## Overview

Finds exact duplicate files across user-specified directories using a two-pass strategy: group by file size first (fast, eliminates ~99% of candidates), then compute SHA256 only on same-size groups. The agent orchestrates the conversation — user confirms scan targets, reviews results, and picks which copies to keep.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/discover-sources.ps1` | Auto-detect download/receive directories from browsers (Chrome/Edge/Firefox), WeChat, QQ, Desktop, Downloads |
| `scripts/scan-duplicates.ps1` | Walk directories → size group → SHA256 hash → JSON of duplicate groups |
| `scripts/remove-duplicates.ps1` | Move specified files to Recycle Bin (default) or permanent delete (`-Permanent`). Dry-run with `-WhatIf`. |

**Usage:**
```powershell
# Discover where to scan
powershell -File scripts/discover-sources.ps1
powershell -File scripts/discover-sources.ps1 -Json

# Scan for duplicates
powershell -File scripts/scan-duplicates.ps1 -Paths @("C:\Users\...\Downloads", "C:\Users\...\Desktop") -MinSizeMB 1
powershell -File scripts/scan-duplicates.ps1 -Paths @("C:\...") -MinSizeMB 5 -IncludeHidden

# Remove specified files
powershell -File scripts/remove-duplicates.ps1 -Files @("C:\a.txt", "C:\b.txt")
powershell -File scripts/remove-duplicates.ps1 -Files @("C:\a.txt") -WhatIf
powershell -File scripts/remove-duplicates.ps1 -Files @("C:\a.txt") -Permanent
```

## Agent Instruction: Full Dedup Workflow

### Phase 1: Discover

```
ACTION: Run discover-sources.ps1 (table mode first, let user see it)
ASK user: "Here are the locations I found. Which should I scan? You can add or remove any."
WAIT for user to confirm or modify the list of paths.
```

### Phase 2: Thresholds

```
ASK user: "Only scan files larger than N MB? (default 1 MB — skip tiny files)"
WAIT for user confirmation.

ASK user: "Include hidden/system files?" (default: no)
WAIT for user confirmation.
```

### Phase 3: Scan

```
ACTION: Run scan-duplicates.ps1 with confirmed paths and thresholds.
       The script outputs progress to stderr and JSON to stdout.
       Read the JSON result.

REPORT:
  - Total files scanned
  - Number of duplicate groups found
  - Total wasted space

If 0 duplicates: "No duplicates found. Your files are clean."
If > 50 groups: "Found {N} groups. That's a lot. Let's go through them in batches of 10."
If <= 50 groups: "Found {N} groups. Let's go through them one by one."
```

### Phase 4: Decide (global rule first)

```
ASK user: "Before we go group by group — do you have a preference for which copy to keep?

  A) Keep the newest (by modified date)
  B) Keep from a specific folder (e.g., 'always keep what's on Desktop, delete copies in Downloads')
  C) Keep the one with the shortest path
  D) No global rule — let me decide per group

If A, B, or C chosen:
  - Apply the rule to all groups
  - Show a preview of what would be kept/deleted
  - "Does this look right? I'll apply this rule to all groups that it can resolve."
  - Groups the rule can't resolve (e.g. all files in same folder) → go to Phase 5 per-group

If D:
  - Go directly to Phase 5 for every group
```

### Phase 5: Decide (per-group, for unresolved groups)

```
FOR each unresolved duplicate group:
  SHOW:
    - File names, paths, sizes, last modified dates
    - Which would be kept under the global rule (if any)
    - Hardlink annotations: mark files that are hardlinks (deleting them won't free space)

  ASK: "Which one should I keep? (1, 2, 3... or 'skip this group')"

  RECORD: the keep/del decision
  CONFIRM before moving to next group, or auto-advance if user says "auto for the rest"
```

### Phase 6: Execute

```
SHOW final summary: "{N} files to delete, freeing {X} GB."

ASK: "Proceed? (yes/no/dry-run)"

If "dry-run":
  ACTION: Run remove-duplicates.ps1 -WhatIf
  SHOW what would happen
  ASK: "Proceed for real?"

If "yes":
  ACTION: Run remove-duplicates.ps1 with the delete list
  REPORT: how many deleted, how many failed, space freed
  REMIND: "Files are in Recycle Bin — empty it to permanently free the space."
```

## Hardlink Handling

When two paths share the same inode (hardlinks), deleting one does NOT free space. The scan script detects this and marks such files with `is_hardlink: true`. When presenting duplicates, call out hardlinks explicitly so the user doesn't expect space savings from deleting them.

## OneDrive / Cloud Placeholders

Files with `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` (0x00080000) are cloud-only placeholders. The scan script skips them automatically to avoid triggering downloads.

## Safety Rules

1. **Never scan system directories** — `C:\Windows`, `Program Files`, `Program Files (x86)` are excluded by default.
2. **Default to Recycle Bin** — permanent deletion requires explicit `-Permanent` flag.
3. **Always show a preview** before any deletion, even with a global rule applied.
4. **Never delete all copies** — always keep at least one copy per duplicate group.
5. **Report hardlinks** — don't let the user think deleting a hardlink frees space.

## Common Mistakes

| Mistake | Reality |
|---------|---------|
| Deleting a hardlink expecting space back | Hardlinks share inode — deleting one copy frees nothing. Scan script marks these. |
| Scanning Program Files | System directories are excluded. User can override with direct `-Paths` but should be warned. |
| Using -Permanent without backup | Files are unrecoverable. Always default to Recycle Bin. |
| Forgetting to close apps before scan | If a file is locked by a process, it may fail to hash. Warn user if scan shows errors. |
| Scanning OneDrive folder without checking status | Online-only files are automatically skipped to prevent unwanted downloads. |
