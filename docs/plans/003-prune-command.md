# Design: Prune Command

**GitHub Issue:** #3  
**Status:** Draft  
**Author:** cpjolicoeur  
**Date:** 2025-01-15

## Overview

Add a `prune` command that deletes closed tickets meeting specific criteria, helping keep the `.tickets/` directory clean without losing active work context.

## Command Interface

```bash
tk prune [options]

Options:
  --days=N      Only prune tickets closed more than N days ago (default: 7)
  --all         Prune all eligible closed tickets regardless of age
  --dry-run     Preview what would be deleted without actually deleting
```

### Examples

```bash
tk prune                    # Delete closed tickets older than 7 days
tk prune --days=30          # Delete closed tickets older than 30 days
tk prune --all              # Delete all eligible closed tickets
tk prune --dry-run          # Preview what would be deleted
tk prune --all --dry-run    # Preview all eligible tickets
```

## Eligibility Criteria

A ticket is eligible for pruning if **ALL** of the following are true:

1. **Status is `closed`** — only closed tickets are candidates
2. **Has a `closed_at` field** — tickets closed before this feature ships are never pruned (backwards compatibility)
3. **Closed date exceeds age threshold** — older than 7 days by default, or bypassed with `--all`
4. **Not a dependency of any open/in-progress ticket** — protects active dependency chains from orphaning

## Schema Change

New YAML frontmatter field `closed_at` set when a ticket is closed:

```yaml
---
id: proj-a1b2
status: closed
closed_at: 2025-01-08T14:30:00Z
deps: []
links: []
created: 2025-01-01T12:00:00Z
type: task
priority: 2
assignee: Developer Name
---
```

### `closed_at` Lifecycle

The `closed_at` field is managed by `cmd_status()`, making it consistent regardless of which command is used to change status:

- **Setting to `closed`:** If `closed_at` is not already present, set it to current ISO 8601 timestamp. If already present, preserve the existing value (first close wins).
- **Setting to `open` or `in_progress`:** Clear the `closed_at` field if present.

This means:
- `tk close <id>` → sets `closed_at` (if not already set)
- `tk reopen <id>` → clears `closed_at`
- `tk status <id> closed` → sets `closed_at` (if not already set)
- `tk status <id> open` → clears `closed_at`
- `tk status <id> in_progress` → clears `closed_at`

Re-closing an already-closed ticket does **not** update the timestamp — the original close time is preserved. To refresh the timestamp, the user must first reopen the ticket, then close it again.

## Algorithm

1. Gather all tickets with `status: closed` and a `closed_at` field
2. Filter by age threshold (unless `--all` is specified)
3. Build a set of ticket IDs referenced as dependencies by open/in-progress tickets
4. Exclude any closed tickets in that dependency set
5. If `--dry-run`, display what would be deleted and exit
6. Otherwise, delete the eligible ticket files via `rm`

## Output Format

**Normal execution:**
```
proj-a1b2: Fix login bug (closed 2025-01-05)
proj-c3d4: Update README (closed 2025-01-03)
Pruned 2 tickets
```

**Dry-run execution:**
```
proj-a1b2: Fix login bug (closed 2025-01-05)
proj-c3d4: Update README (closed 2025-01-03)
Would prune 2 tickets
```

**No tickets to prune:** Silent exit (code 0)

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (including when no tickets match) |
| 1 | Error (e.g., invalid arguments) |

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| No closed tickets exist | Silent exit (code 0) |
| All closed tickets are too recent | Silent exit (code 0) |
| All closed tickets are dependency-protected | Silent exit (code 0) |
| Ticket missing `closed_at` field | Skipped (never pruned) |
| Ticket with malformed `closed_at` | Skipped (unparseable dates treated as missing) |
| `--days` with non-positive value | Invalid — must be a positive integer (>= 1) |
| `--days` with non-numeric value | Invalid — must be a positive integer |
| Both `--days` and `--all` specified | `--all` takes precedence (ignores `--days`) |
| Re-closing an already closed ticket | `closed_at` is preserved (not updated) |
| `tk status <id> closed` on open ticket | Sets `closed_at` (same as `tk close`) |
| `tk status <id> open` on closed ticket | Clears `closed_at` (same as `tk reopen`) |

## Implementation Touchpoints

### Functions to Add/Modify

| Function | Change |
|----------|--------|
| `cmd_prune()` | New command handler implementing the prune logic |
| `cmd_status()` | Add `closed_at` logic: set when closing (if not present), clear when non-closed |
| `cmd_help()` | Add `prune` command to help output |
| Main dispatch | Add `prune` case |

Note: `cmd_close()` and `cmd_reopen()` remain thin wrappers around `cmd_status()` — no changes needed.

### Helper Functions to Leverage

- `yaml_field()` — read `status`, `closed_at`, `deps` fields
- `update_yaml_field()` — set/clear `closed_at`
- `_iso_date()` — generate portable ISO 8601 timestamp
- Existing awk patterns from `cmd_ready()`/`cmd_blocked()` for bulk ticket scanning

### Documentation Updates

- `README.md` — add `prune` to Usage section
- `CHANGELOG.md` — add entry under `[Unreleased]`

## Future Considerations

- Add `--quiet` flag for script-friendly output
- Support duration strings (e.g., `--age=2w` for weeks)
- Support ISO date cutoff (e.g., `--before=2025-01-01`)
