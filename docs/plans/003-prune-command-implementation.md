# Implementation Plan: Prune Command

**GitHub Issue:** #3  
**Design Doc:** [003-prune-command.md](./003-prune-command.md)  
**Date:** 2025-01-15

---

## Prerequisites

Before starting, ensure you can run the script:

```bash
cd /path/to/ticket
./ticket help
```

You'll be editing a single file: `ticket` (a bash script, ~1265 lines). There is no build step, no test suite, and no linter. Manual testing is the verification method.

---

## Task 1: Update `cmd_status()` to Manage `closed_at` Field

**Goal:** Make `cmd_status()` the authoritative place for `closed_at` logic. When setting status to `closed`, set `closed_at` if not already present (first close wins). When setting status to any non-closed value, clear `closed_at`.

**File:** `ticket`

**Location:** Find `cmd_status()` around line 204-221.

**Current code:**

```bash
cmd_status() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $(basename "$0") status <id> <status>" >&2
        echo "Valid statuses: $VALID_STATUSES" >&2
        return 1
    fi

    local id="$1"
    local status="$2"

    validate_status "$status" || return 1

    local file
    file=$(ticket_path "$id") || return 1

    update_yaml_field "$file" "status" "$status"
    echo "Updated $(basename "$file" .md) -> $status"
}
```

**Change to:**

```bash
cmd_status() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $(basename "$0") status <id> <status>" >&2
        echo "Valid statuses: $VALID_STATUSES" >&2
        return 1
    fi

    local id="$1"
    local status="$2"

    validate_status "$status" || return 1

    local file
    file=$(ticket_path "$id") || return 1

    update_yaml_field "$file" "status" "$status"

    # Manage closed_at field based on status
    if [[ "$status" == "closed" ]]; then
        # Set closed_at only if not already present (first close wins)
        if ! _grep -q "^closed_at:" "$file"; then
            update_yaml_field "$file" "closed_at" "$(_iso_date)"
        fi
    else
        # Clear closed_at when moving to any non-closed status
        if _grep -q "^closed_at:" "$file"; then
            _sed_i "$file" '/^closed_at:/d'
        fi
    fi

    echo "Updated $(basename "$file" .md) -> $status"
}
```

**Why this approach:**
- `cmd_status()` is the single source of truth for status changes
- `cmd_close()` and `cmd_reopen()` remain thin wrappers (no changes needed)
- All paths to closing/reopening behave consistently
- Re-closing an already-closed ticket preserves the original `closed_at` timestamp
- `_iso_date()` (line 25-27) returns portable ISO 8601 format
- `_grep` (line 11-15) and `_sed_i()` (line 30-35) are portable wrappers

**How to test:**

```bash
# Test 1: Basic close via tk close
./ticket create "Test close"
./ticket close t-xxxx
cat .tickets/t-xxxx.md | grep closed_at
# Should show: closed_at: 2025-01-15T...Z

# Test 2: Basic close via tk status
./ticket create "Test status closed"
./ticket status t-yyyy closed
cat .tickets/t-yyyy.md | grep closed_at
# Should show: closed_at: 2025-01-15T...Z

# Test 3: Reopen clears closed_at
./ticket reopen t-xxxx
cat .tickets/t-xxxx.md | grep closed_at
# Should return nothing (exit code 1)

# Test 4: status open clears closed_at
./ticket close t-xxxx
cat .tickets/t-xxxx.md | grep closed_at  # Should exist
./ticket status t-xxxx open
cat .tickets/t-xxxx.md | grep closed_at
# Should return nothing (exit code 1)

# Test 5: Re-closing preserves original timestamp
./ticket close t-xxxx
cat .tickets/t-xxxx.md | grep closed_at  # Note the timestamp
sleep 2
./ticket close t-xxxx
cat .tickets/t-xxxx.md | grep closed_at
# Should show SAME timestamp (not updated)

# Test 6: status in_progress clears closed_at
./ticket close t-yyyy
./ticket status t-yyyy in_progress
cat .tickets/t-yyyy.md | grep closed_at
# Should return nothing (exit code 1)

# Cleanup
rm .tickets/t-xxxx.md .tickets/t-yyyy.md
```

**Commit:** `Add closed_at timestamp management to cmd_status()`

---

## Task 2: Add `cmd_prune()` Function — Argument Parsing

**Goal:** Create the `cmd_prune()` function with proper argument parsing for `--days=N`, `--all`, and `--dry-run`.

**File:** `ticket`

**Location:** Add this function before `cmd_help()` (around line 1194). Keep related commands grouped together — add it near `cmd_closed()` if you prefer logical grouping.

**Code to add:**

```bash
cmd_prune() {
    [[ ! -d "$TICKETS_DIR" ]] && return 0

    local days=7
    local prune_all=0
    local dry_run=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days=*)
                days="${1#--days=}"
                # Validate: must be a positive integer (>= 1)
                if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: --days requires a positive integer (got '$days')" >&2
                    return 1
                fi
                shift
                ;;
            --all)
                prune_all=1
                shift
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "Error: unknown option '$1'" >&2
                echo "Usage: $(basename "$0") prune [--days=N] [--all] [--dry-run]" >&2
                return 1
                ;;
        esac
    done

    # TODO: Implement pruning logic in next task
    echo "DEBUG: days=$days, prune_all=$prune_all, dry_run=$dry_run"
}
```

**Why this pattern:**
- Matches existing argument parsing style (see `cmd_create()` lines 123-137, `cmd_closed()` lines 601-605)
- Validates `--days=0` as invalid per design spec
- Exits with error (return 1) on unknown options

**How to test:**

```bash
# Test default values
./ticket prune
# Should show: DEBUG: days=7, prune_all=0, dry_run=0

# Test --days
./ticket prune --days=30
# Should show: DEBUG: days=30, prune_all=0, dry_run=0

# Test --all
./ticket prune --all
# Should show: DEBUG: days=7, prune_all=1, dry_run=0

# Test --dry-run
./ticket prune --dry-run
# Should show: DEBUG: days=7, prune_all=0, dry_run=1

# Test combinations
./ticket prune --all --dry-run
# Should show: DEBUG: days=7, prune_all=1, dry_run=1

# Test invalid --days=0
./ticket prune --days=0
# Should show: Error: --days requires a positive integer (got '0')

# Test invalid --days with negative value
./ticket prune --days=-5
# Should show: Error: --days requires a positive integer (got '-5')

# Test invalid --days with non-numeric value
./ticket prune --days=abc
# Should show: Error: --days requires a positive integer (got 'abc')

# Test unknown option
./ticket prune --invalid
# Should show error and exit 1
```

**Commit:** `Add cmd_prune() with argument parsing`

---

## Task 3: Add `prune` to Main Dispatch and Help

**Goal:** Wire up the `prune` command so `tk prune` invokes `cmd_prune()`, and add it to help output.

**File:** `ticket`

### Part A: Add to main dispatch

**Location:** Find the main dispatch `case` statement at the bottom (around line 1239-1265).

**Add this line** in alphabetical order (after `migrate-beads`, before `query`):

```bash
    prune)  shift; cmd_prune "$@" ;;
```

The dispatch block should look like:

```bash
case "${1:-help}" in
    create) shift; cmd_create "$@" ;;
    start)  shift; cmd_start "$@" ;;
    close)  shift; cmd_close "$@" ;;
    reopen) shift; cmd_reopen "$@" ;;
    status) shift; cmd_status "$@" ;;
    dep)    shift; cmd_dep "$@" ;;
    undep)  shift; cmd_undep "$@" ;;
    link)   shift; cmd_link "$@" ;;
    unlink) shift; cmd_unlink "$@" ;;
    ls)     shift; cmd_ls "$@" ;;
    ready)  cmd_ready ;;
    blocked) cmd_blocked ;;
    closed) shift; cmd_closed "$@" ;;
    prune)  shift; cmd_prune "$@" ;;
    show)   shift; cmd_show "$@" ;;
    ...
```

### Part B: Add to help output

**Location:** Find `cmd_help()` around line 1194-1236.

**Add this line** after the `closed` command (around line 1225):

```bash
  prune [options]          Delete old closed tickets
    --days=N               Only prune tickets closed > N days ago [default: 7]
    --all                  Prune all eligible closed tickets
    --dry-run              Preview what would be deleted
```

**How to test:**

```bash
# Verify command is recognized
./ticket prune
# Should show the DEBUG output from Task 3

# Verify help shows prune
./ticket help | grep -A4 prune
# Should show the prune command and its options
```

**Commit:** `Wire up prune command in dispatch and help`

---

## Task 4: Implement Prune Logic — Gather Eligible Tickets

**Goal:** Replace the DEBUG output with actual logic to gather closed tickets with `closed_at` field and filter by age.

**File:** `ticket`

**Location:** Replace the TODO/DEBUG line in `cmd_prune()` with the full implementation.

**Replace the entire `cmd_prune()` function with:**

```bash
cmd_prune() {
    [[ ! -d "$TICKETS_DIR" ]] && return 0

    local days=7
    local prune_all=0
    local dry_run=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days=*)
                days="${1#--days=}"
                # Validate: must be a positive integer (>= 1)
                if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: --days requires a positive integer (got '$days')" >&2
                    return 1
                fi
                shift
                ;;
            --all)
                prune_all=1
                shift
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "Error: unknown option '$1'" >&2
                echo "Usage: $(basename "$0") prune [--days=N] [--all] [--dry-run]" >&2
                return 1
                ;;
        esac
    done

    # Calculate cutoff timestamp (seconds since epoch)
    local cutoff_epoch
    cutoff_epoch=$(( $(date +%s) - (days * 86400) ))

    # Collect all ticket data in one awk pass
    # Output format: filepath|id|status|closed_at|deps_csv|title
    local ticket_data
    ticket_data=$(awk '
    BEGIN { FS=": "; in_front=0 }
    FNR==1 {
        if (prev_file) emit()
        id=""; status=""; closed_at=""; deps=""; title=""; in_front=0
        prev_file=FILENAME
    }
    /^---$/ { in_front = !in_front; next }
    in_front && /^id:/ { id = $2 }
    in_front && /^status:/ { status = $2 }
    in_front && /^closed_at:/ { closed_at = $2 }
    in_front && /^deps:/ {
        deps = $2
        gsub(/[\[\] ]/, "", deps)
    }
    !in_front && /^# / && title == "" { title = substr($0, 3) }
    function emit() {
        if (id != "") {
            printf "%s|%s|%s|%s|%s|%s\n", prev_file, id, status, closed_at, deps, title
        }
    }
    END { if (prev_file) emit() }
    ' "$TICKETS_DIR"/*.md 2>/dev/null)

    [[ -z "$ticket_data" ]] && return 0

    # Build set of ticket IDs that are dependencies of open/in_progress tickets
    local protected_deps
    protected_deps=$(echo "$ticket_data" | awk -F'|' '
    $3 == "open" || $3 == "in_progress" {
        n = split($5, arr, ",")
        for (i = 1; i <= n; i++) {
            if (arr[i] != "") print arr[i]
        }
    }
    ' | sort -u)

    # Filter to eligible tickets and prune
    local count=0
    while IFS='|' read -r filepath id status closed_at deps title; do
        # Must be closed
        [[ "$status" != "closed" ]] && continue

        # Must have closed_at field (backwards compatibility)
        [[ -z "$closed_at" ]] && continue

        # Check if protected as a dependency
        if echo "$protected_deps" | _grep -qx "$id" 2>/dev/null; then
            continue
        fi

        # Check age threshold (unless --all)
        if [[ "$prune_all" -eq 0 ]]; then
            # Convert ISO date to epoch for comparison
            # Handle both GNU and BSD date; skip if unparseable
            local closed_epoch
            if date -d "$closed_at" +%s &>/dev/null; then
                closed_epoch=$(date -d "$closed_at" +%s)
            elif closed_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$closed_at" +%s 2>/dev/null); then
                : # parsed successfully
            else
                # Malformed date — skip this ticket (treat as missing closed_at)
                continue
            fi

            # Skip if closed too recently
            [[ "$closed_epoch" -gt "$cutoff_epoch" ]] && continue
        fi

        # Format closed date for display (just the date part)
        local closed_display
        closed_display="${closed_at%%T*}"

        # Output the ticket info
        echo "$id: $title (closed $closed_display)"

        # Delete unless dry-run
        if [[ "$dry_run" -eq 0 ]]; then
            rm "$filepath"
        fi

        ((count++)) || true
    done <<< "$ticket_data"

    # Summary line
    if [[ "$count" -gt 0 ]]; then
        if [[ "$dry_run" -eq 1 ]]; then
            echo "Would prune $count tickets"
        else
            echo "Pruned $count tickets"
        fi
    fi
    # Silent exit (code 0) when count is 0, per design spec
}
```

**Key implementation details:**

1. **Single awk pass** — Matches the pattern used in `cmd_ready()` and `cmd_blocked()` (lines 527-594, 635-711). Collects all ticket metadata efficiently.

2. **Protected deps calculation** — Builds a list of ticket IDs that are dependencies of any open/in_progress ticket. These are never pruned.

3. **Date conversion** — Handles both GNU date (`date -d`) and BSD date (`date -j -f`). This is critical for macOS compatibility.

4. **Backwards compatibility** — Tickets without `closed_at` field are silently skipped (never pruned).

5. **Silent exit** — When no tickets match, exits successfully with no output (per design spec).

**How to test:**

```bash
# Setup: Create test tickets
./ticket create "Old ticket 1"
./ticket create "Old ticket 2"
./ticket create "Active ticket"

# Close the first two
./ticket close t-xxxx
./ticket close t-yyyy

# Manually backdate one ticket's closed_at for testing
# Edit .tickets/t-xxxx.md and change closed_at to 2025-01-01T00:00:00Z

# Test dry-run (should show the old ticket)
./ticket prune --dry-run
# Should show: t-xxxx: Old ticket 1 (closed 2025-01-01)
# Should show: Would prune 1 tickets

# Test actual prune
./ticket prune
# Should show: t-xxxx: Old ticket 1 (closed 2025-01-01)
# Should show: Pruned 1 tickets

# Verify file is gone
ls .tickets/t-xxxx.md
# Should fail: No such file

# Verify recent closed ticket still exists
ls .tickets/t-yyyy.md
# Should exist

# Test --all (prunes everything closed, regardless of age)
./ticket prune --all --dry-run
# Should show the recently closed ticket

# Cleanup
rm .tickets/*.md
```

**Test dependency protection:**

```bash
# Create tickets with dependencies
./ticket create "Dependency ticket"
./ticket create "Main ticket" --dep t-dep-id
./ticket close t-dep-id

# Manually backdate the closed ticket
# Edit .tickets/t-dep-id.md, set closed_at to old date

# Try to prune
./ticket prune --all --dry-run
# Should NOT show t-dep-id because it's a dependency of an open ticket
```

**Commit:** `Implement prune logic with eligibility filtering`

---

## Task 5: Update Documentation

**Goal:** Update README.md and CHANGELOG.md to document the new feature.

**File:** `README.md`

**Location:** Find the Usage section (around line 74-113).

**Add after the `closed` command (around line 103):**

```markdown
  prune [options]          Delete old closed tickets
    --days=N               Only prune tickets closed > N days ago [default: 7]
    --all                  Prune all eligible closed tickets
    --dry-run              Preview what would be deleted
```

**File:** `CHANGELOG.md`

**Location:** At the top of the file, add or update the `[Unreleased]` section:

```markdown
## [Unreleased]

### Added
- `prune` command to delete old closed tickets
  - `--days=N` to set age threshold (default: 7 days)
  - `--all` to prune regardless of age
  - `--dry-run` to preview without deleting
- `closed_at` timestamp field set when tickets are closed
- Dependency protection: closed tickets referenced by open/in-progress tickets are never pruned

### Changed
- `status` command now manages `closed_at` field automatically:
  - Sets `closed_at` when status becomes `closed` (if not already set)
  - Clears `closed_at` when status becomes `open` or `in_progress`
- Re-closing an already-closed ticket preserves the original `closed_at` timestamp
```

**How to test:**

```bash
# Verify help matches README
./ticket help | grep -A4 prune
# Should match what you added to README

# Verify CHANGELOG has the entry
head -20 CHANGELOG.md
# Should show the Unreleased section with prune entries
```

**Commit:** `Document prune command in README and CHANGELOG`

---

## Summary Checklist

| Task | Description | Commit Message |
|------|-------------|----------------|
| 1 | Update `cmd_status()` to manage `closed_at` | `Add closed_at timestamp management to cmd_status()` |
| 2 | Add `cmd_prune()` with argument parsing | `Add cmd_prune() with argument parsing` |
| 3 | Wire up dispatch and help | `Wire up prune command in dispatch and help` |
| 4 | Implement full prune logic | `Implement prune logic with eligibility filtering` |
| 5 | Update README and CHANGELOG | `Document prune command in README and CHANGELOG` |

---

## Edge Cases to Verify

Before considering the feature complete, manually test these scenarios:

| Scenario | Expected Behavior |
|----------|-------------------|
| No `.tickets/` directory | Silent exit (code 0) |
| Empty `.tickets/` directory | Silent exit (code 0) |
| No closed tickets | Silent exit (code 0) |
| All closed tickets too recent | Silent exit (code 0) |
| All closed tickets are dependency-protected | Silent exit (code 0) |
| Ticket missing `closed_at` field | Skipped silently |
| Ticket with malformed `closed_at` | Skipped (treated as missing) |
| `--days=0` | Error: must be positive integer |
| `--days=-5` | Error: must be positive integer |
| `--days=abc` | Error: must be positive integer |
| `--days=1.5` | Error: must be positive integer |
| Unknown flag like `--foo` | Error message, exit 1 |
| `--all --days=30` | `--all` takes precedence, days ignored |
| Mixed open/closed deps on a closed ticket | Prune only if no open/in_progress deps |
| Re-closing already closed ticket | `closed_at` preserved (not updated) |
| `tk status <id> closed` on open ticket | Sets `closed_at` (same as `tk close`) |
| `tk status <id> open` on closed ticket | Clears `closed_at` (same as `tk reopen`) |
| `tk status <id> in_progress` on closed ticket | Clears `closed_at` |

---

## Portability Notes

This script must work on both GNU/Linux and macOS (BSD). Key differences to be aware of:

| Operation | GNU | BSD/macOS |
|-----------|-----|-----------|
| Date parsing | `date -d "2025-01-01"` | `date -j -f "%Y-%m-%d" "2025-01-01"` |
| In-place sed | `sed -i 's/...'` | `sed -i '' 's/...'` (use `_sed_i` wrapper) |
| sha256 | `sha256sum` | `shasum -a 256` (use `_sha256` wrapper) |
| find printf | `find -printf` | Not available (use different approach) |

The implementation in Task 5 handles date parsing for both systems. Always use the `_sed_i`, `_sha256`, and `_grep` wrappers defined at the top of the script.
