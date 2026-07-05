# duplicate-file-killer — Design Spec

## Summary

A Windows PowerShell skill that finds duplicate files across user-chosen locations (browser download folders, chat app receive folders, Desktop, Downloads, user-specified paths) via size grouping + SHA256 hashing, then interacts with the user to decide which copies to keep and which to delete.

## Interaction Flow (Conversational / Agent-driven)

1. **Discover scan targets**
   - Auto-detect: Chrome/Edge download directories (read History SQLite), WeChat FileStorage, QQ FileRecv, system Downloads, Desktop.
   - Present the list to the user: "I found these locations. Which should I scan? Any others?"
   - User confirms or adds/removes paths.

2. **Set thresholds**
   - "Only scan files ≥ N MB?" (default: 1 MB — tiny dupes aren't worth the noise).
   - "Include hidden/system files?" (default: no).

3. **Scan**
   - Walk selected directories, skipping junctions/symlinks.
   - Group by file size first; only same-size groups proceed to SHA256.
   - Report: "Found N groups of duplicates, wasting X GB."

4. **Decide — global rule first**
   - "Any preference for which copy to keep? e.g. keep newest, keep from a certain folder, keep shortest path."
   - Agent previews what the rule would do; user confirms or refines.
   - Groups that the rule can't resolve (all copies in same folder, same timestamp) go to manual decision.

5. **Decide — per-group (for unresolved groups)**
   - Agent shows each group (file names, paths, sizes).
   - User picks which to keep; Agent marks the rest for deletion.

6. **Execute & verify**
   - Move duplicates to Recycle Bin (or a staging folder, giving the user an undo window).
   - Report: "Freed X GB. Undo: files are still in Recycle Bin / staging folder."

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/discover-sources.ps1` | Auto-detect download/receive directories from browsers, WeChat, QQ, system |
| `scripts/scan-duplicates.ps1` | Accept paths + min-size → group by size → SHA256 → output JSON of duplicate groups |
| `scripts/dedup-decide.ps1` | Accept duplicate JSON + a keep-rule → apply rule, output per-group decisions |
| `scripts/remove-duplicates.ps1` | Accept decision list → move to Recycle Bin / staging, report freed space |

## Technical Approach

- **Two-pass dedup**: size filter (fast, eliminates ~99% of candidates) → SHA256 (only on same-size groups).
- **Progress reporting**: for files > 100 MB, emit progress during hashing.
- **Safe deletion**: default is `Move-Item` to Recycle Bin (or a `duplicates-removed` staging folder with timestamp). Permanent delete only with explicit `-Force` / `-Permanent`.
- **Bypass exclusions**: skip `C:\Windows`, `C:\Program Files`, `C:\Program Files (x86)`, `System32` by default. `-IncludeSystem` flag to override.

## Safety Gates

- Never scan system directories by default.
- Verify hash groups before deleting (re-hash one random file to confirm).
- Default: Recycle Bin. Permanent delete requires explicit flag.
- Dry-run mode (`-WhatIf`) to preview without touching files.
- Each destructive step requires user confirmation unless a rule was explicitly approved.

## Key Edge Cases

- **Hardlinks**: two paths pointing to the same inode. Show as "hardlink, deleting one won't free space." Don't count in wasted-space total.
- **Junctions/symlinks**: skip during scan — don't follow them.
- **OneDrive / cloud files**: online-only placeholders should be skipped (they download on access and would skew results).
- **Files with same hash but different names**: the core case — handle normally.
- **Zero-byte files**: skip by default (min-size filter catches them).

## Non-Goals (for this version)

- Fuzzy / similar-image dedup (perceptual hashing) — only exact duplicates.
- File content preview before deletion.
- Scheduling / recurring scans.
