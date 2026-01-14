# Implementation Plan: `--parent` Flag Dependency Chain Fix

**Related Design Doc:** [parent-flag-dependency-chain.md](parent-flag-dependency-chain.md)  
**Date:** 2026-01-14

---

## Overview

This plan implements the enhancement to `tk create --parent` so it automatically adds the child ticket as a dependency on the parent ticket. Currently `--parent` only sets the `parent:` field on the child — it doesn't update the parent's `deps:` array, leaving the blocking relationship incomplete.

**What you're building:**

```
# Before (broken): User has to run two commands
tk create "Child task" --parent proj-1234
tk dep proj-1234 <child-id>   # manual step required

# After (fixed): One command does both
tk create "Child task" --parent proj-1234
# parent's deps automatically updated
```

---

## Prerequisites

Before starting, ensure you can:

1. Run the script: `./ticket help` or `tk help`
2. Create a test ticket: `tk create "Test"`
3. View tickets: `tk ls`
4. Clean up: `rm -rf .tickets` (if you want a fresh start)

**Key files:**

| File | Purpose |
|------|---------|
| `ticket` | The entire application (single bash script, ~1250 lines) |
| `README.md` | User documentation |
| `CHANGELOG.md` | Release notes |

---

## Task 1: Understand the Existing Code

**Goal:** Read and understand the relevant functions before making changes.

**Time estimate:** 15 minutes

### Steps

1. Open `ticket` in your editor

2. Read `cmd_create()` (lines 112-178):
   - Note how `--parent` is parsed at line 131: `--parent) parent="$2"; shift 2 ;;`
   - Note how `parent:` is written to the child's frontmatter at line 155: `[[ -n "$parent" ]] && echo "parent: $parent"`
   - Observe that nothing updates the parent ticket

3. Read `ticket_path()` (lines 62-87):
   - This resolves a (possibly partial) ticket ID to a file path
   - Returns error if not found or ambiguous
   - You'll use this to validate the parent exists

4. Read `yaml_field()` (lines 90-94):
   - Extracts a field value from YAML frontmatter
   - You'll use this to check if parent is closed

5. Read `cmd_dep()` (lines 434-476):
   - This is the existing logic for adding a dependency
   - Note how it handles empty deps `[]` vs existing deps
   - You could reuse this, but calling it would print output we don't want

### Verification

You understand:
- Where `--parent` is parsed
- Where the child file is created
- How `ticket_path()` validates IDs
- How dependencies are added to the YAML array

**Do not commit — this is a read-only task.**

---

## Task 2: Add Parent Validation (Fail Fast)

**Goal:** If `--parent` is provided, validate the parent ticket exists before creating the child.

**Time estimate:** 10 minutes

**File:** `ticket` (lines 112-178, `cmd_create()` function)

### Steps

1. After the argument parsing loop (after line 135), add validation logic:

```bash
    # Validate parent exists before creating child
    local parent_file=""
    if [[ -n "$parent" ]]; then
        parent_file=$(ticket_path "$parent") || return 1
    fi
```

2. **Why this works:**
   - `ticket_path` returns 0 and prints the path if found
   - `ticket_path` returns 1 and prints an error to stderr if not found/ambiguous
   - `|| return 1` exits `cmd_create` with error code 1 if validation fails
   - No child ticket is created because we exit before the file write

3. **Where to insert:** After line 135 (end of the `while` loop), before line 137 (`title="${title:-Untitled}"`)

### Test It

```bash
# Setup
rm -rf .tickets
mkdir .tickets

# Test 1: Parent not found — should fail
./ticket create "Child" --parent nonexistent
# Expected: "Error: ticket 'nonexistent' not found" (exit code 1)
echo $?  # Should print: 1

# Test 2: No .tickets files exist yet for ambiguous test, so create two similar IDs
./ticket create "Parent A"  # e.g., prints "t-abcd"
./ticket create "Parent B"  # e.g., prints "t-ef12"

# Test 3: Ambiguous ID (partial match hits both) — skip if IDs don't overlap
# This depends on generated IDs; may need to manually create files

# Test 4: Valid parent — should succeed (child created, no error)
PARENT_ID=$(./ticket create "Parent")
./ticket create "Child" --parent "$PARENT_ID"
# Expected: prints child ID, exit code 0
```

### Commit

```bash
jj commit -m "create --parent: fail fast if parent ticket not found"
```

---

## Task 3: Add Closed Parent Warning

**Goal:** If the parent ticket is closed, print a warning to stderr but continue.

**Time estimate:** 10 minutes

**File:** `ticket` (in `cmd_create()`, right after the validation block from Task 2)

### Steps

1. After the parent validation block, add the closed check:

```bash
    # Warn if parent is closed
    if [[ -n "$parent_file" ]]; then
        local parent_status
        parent_status=$(yaml_field "$parent_file" "status")
        if [[ "$parent_status" == "closed" ]]; then
            echo "Warning: parent $parent is closed" >&2
        fi
    fi
```

2. **Key points:**
   - `>&2` sends output to stderr (not stdout)
   - We use `$parent` (the ID the user provided) in the message, not the resolved ID
   - We continue execution — this is just a warning

### Test It

```bash
# Setup
rm -rf .tickets

# Create and close a parent
PARENT_ID=$(./ticket create "Parent")
./ticket close "$PARENT_ID"

# Create child with closed parent — should warn but succeed
./ticket create "Child" --parent "$PARENT_ID"
# Expected stderr: "Warning: parent <id> is closed"
# Expected stdout: child ID
# Exit code: 0

# Verify child was created
./ticket ls  # Should show both tickets
```

### Commit

```bash
jj commit -m "create --parent: warn if parent ticket is closed"
```

---

## Task 4: Update Parent's deps Array

**Goal:** After creating the child, add the child's ID to the parent's `deps:` array.

**Time estimate:** 15 minutes

**File:** `ticket` (in `cmd_create()`, after the child file is written)

### Steps

1. At the end of `cmd_create()`, after `echo "$id"` (line 177), add the dependency update:

```bash
    # Update parent's deps to include this child
    if [[ -n "$parent_file" ]]; then
        local parent_deps
        parent_deps=$(yaml_field "$parent_file" "deps")
        
        if [[ "$parent_deps" == "[]" ]]; then
            update_yaml_field "$parent_file" "deps" "[$id]"
        else
            local new_deps
            new_deps=$(echo "$parent_deps" | sed "s/\]/, $id]/")
            update_yaml_field "$parent_file" "deps" "$new_deps"
        fi
    fi
```

2. **Key points:**
   - We already have `$parent_file` from the validation step (Task 2)
   - `$id` is the newly generated child ticket ID
   - Logic matches `cmd_dep()` — handles empty `[]` vs existing deps
   - No output to stdout (we already printed the child ID)

3. **Important:** The `echo "$id"` line must remain BEFORE this block. The child ID is printed first, then we silently update the parent.

### Test It

```bash
# Setup
rm -rf .tickets

# Test 1: Create parent, then child with --parent
PARENT_ID=$(./ticket create "Parent Epic")
CHILD_ID=$(./ticket create "Child Task" --parent "$PARENT_ID")

# Verify parent's deps contains child
./ticket show "$PARENT_ID"
# Expected: deps line should show the child ID, e.g., "deps: [t-xxxx]"

# Verify child has parent field
./ticket show "$CHILD_ID"
# Expected: parent line shows parent ID, e.g., "parent: t-yyyy"

# Test 2: Add second child to same parent
CHILD2_ID=$(./ticket create "Another Child" --parent "$PARENT_ID")
./ticket show "$PARENT_ID"
# Expected: deps: [t-xxxx, t-zzzz] (both children)

# Test 3: Verify blocking behavior works
./ticket close "$PARENT_ID"
./ticket blocked
# Parent should appear in blocked list (has open deps)
```

### Commit

```bash
jj commit -m "create --parent: add child as dependency on parent ticket"
```

---

## Task 5: Update Help Output

**Goal:** Update `cmd_help()` to document the new behavior.

**Time estimate:** 5 minutes

**File:** `ticket` (line 1202 in `cmd_help()`)

### Steps

1. Find line 1202:
   ```
       --parent               Parent ticket ID
   ```

2. Change it to:
   ```
       --parent               Parent ticket ID (adds child to parent's deps)
   ```

### Test It

```bash
./ticket help | grep -A1 parent
# Expected: "--parent               Parent ticket ID (adds child to parent's deps)"
```

### Commit

```bash
jj commit -m "help: document --parent dependency behavior"
```

---

## Task 6: Update README.md

**Goal:** Update the README usage section to match the new help text.

**Time estimate:** 5 minutes

**File:** `README.md` (line 89)

### Steps

1. Find line 89:
   ```
       --parent               Parent ticket ID
   ```

2. Change it to:
   ```
       --parent               Parent ticket ID (adds child to parent's deps)
   ```

### Test It

```bash
grep "parent" README.md
# Should show the updated description
```

### Commit

```bash
jj commit -m "docs: update README for --parent behavior"
```

---

## Task 7: Update CHANGELOG.md

**Goal:** Document the changes for the next release.

**Time estimate:** 5 minutes

**File:** `CHANGELOG.md`

### Steps

1. Add a new `## [Unreleased]` section at the top of the file (after line 1, before `## [0.2.2]`):

```markdown
## [Unreleased]

### Changed

- `--parent` flag on `create` now also adds child as dependency on parent ticket
- `create --parent` fails if parent ID not found or ambiguous
- `create --parent` warns (to stderr) if parent ticket is closed
```

### Test It

```bash
head -15 CHANGELOG.md
# Should show the new Unreleased section at top
```

### Commit

```bash
jj commit -m "changelog: document --parent dependency chain fix"
```

---

## Task 8: Final Integration Testing

**Goal:** Run through all scenarios to verify the complete implementation.

**Time estimate:** 10 minutes

### Test Script

Run these commands in sequence:

```bash
#!/bin/bash
set -e

echo "=== Setup ==="
rm -rf .tickets

echo ""
echo "=== Test 1: Happy path ==="
PARENT=$(./ticket create "Epic: User Auth")
echo "Parent: $PARENT"
CHILD=$(./ticket create "Implement login form" --parent "$PARENT")
echo "Child: $CHILD"
./ticket show "$PARENT" | grep -E "^deps:"
# Expected: deps: [<child-id>]

echo ""
echo "=== Test 2: Multiple children ==="
CHILD2=$(./ticket create "Implement logout" --parent "$PARENT")
echo "Child2: $CHILD2"
./ticket show "$PARENT" | grep -E "^deps:"
# Expected: deps: [<child1>, <child2>]

echo ""
echo "=== Test 3: Parent not found ==="
if ./ticket create "Orphan" --parent nonexistent 2>/dev/null; then
    echo "FAIL: Should have errored"
    exit 1
else
    echo "PASS: Correctly rejected missing parent"
fi

echo ""
echo "=== Test 4: Closed parent warning ==="
CLOSED_PARENT=$(./ticket create "Closed Epic")
./ticket close "$CLOSED_PARENT"
# This should warn but succeed
CHILD3=$(./ticket create "Late addition" --parent "$CLOSED_PARENT" 2>&1)
echo "$CHILD3" | grep -q "Warning" && echo "PASS: Warning shown" || echo "INFO: Check stderr manually"

echo ""
echo "=== Test 5: Partial ID matching ==="
# Use last 4 chars of parent ID
SHORT_ID="${PARENT: -4}"
CHILD4=$(./ticket create "Partial match test" --parent "$SHORT_ID")
./ticket show "$PARENT" | grep -q "$CHILD4" && echo "PASS: Partial ID works" || echo "FAIL: Partial ID broken"

echo ""
echo "=== Test 6: Blocked/Ready status ==="
./ticket blocked | grep -q "$PARENT" && echo "PASS: Parent is blocked" || echo "FAIL: Parent should be blocked"

echo ""
echo "=== All tests complete ==="
./ticket ls
```

### Verification Checklist

- [ ] `--parent` with valid ID: creates child, updates parent deps
- [ ] `--parent` with invalid ID: fails with error, no child created  
- [ ] `--parent` with closed parent: warns to stderr, proceeds
- [ ] Output is just child ID (backward compatible)
- [ ] Partial ID matching works for `--parent`
- [ ] `tk blocked` shows parent with open children
- [ ] `tk help` shows updated `--parent` description
- [ ] README matches help output
- [ ] CHANGELOG has Unreleased section

### Commit

No commit for this task — it's verification only.

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `ticket` | ~136-145 | Add parent validation before child creation |
| `ticket` | ~145-150 | Add closed parent warning |
| `ticket` | ~179-188 | Add child to parent's deps after creation |
| `ticket` | 1202 | Update help text for `--parent` |
| `README.md` | 89 | Update docs for `--parent` |
| `CHANGELOG.md` | 3-9 | Add Unreleased section with changes |

**Total: ~20 lines of new code, 2 lines of doc updates, 7 lines of changelog.**

---

## Troubleshooting

**"Error: ticket 'X' not found" when parent exists:**
- Check if `.tickets/` directory exists
- Verify the parent file exists: `ls .tickets/`
- Try the full ID instead of partial

**Parent deps not updating:**
- Verify `$parent_file` is set (add `echo "DEBUG: $parent_file"`)
- Check file permissions on parent ticket file

**Warning not appearing:**
- Warnings go to stderr; try: `./ticket create "X" --parent Y 2>&1`

**Portability issues on macOS:**
- The script uses `_sed_i` wrapper for portable in-place editing
- If you add new sed commands, use `_sed_i` not `sed -i`
