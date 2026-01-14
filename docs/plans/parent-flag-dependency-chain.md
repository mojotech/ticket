# Design: `--parent` Flag Dependency Chain Fix

**Status:** Draft  
**Date:** 2026-01-14  
**Author:** cpjolicoeur + Amp

## Problem Statement & Goals

**Problem:**
The `--parent` flag on `tk create` currently only sets the `parent:` field in the child ticket's frontmatter. It does not update the parent ticket's `deps:` array, meaning the blocking relationship isn't established. Users must manually run `tk dep <parent> <child>` to complete the dependency chain.

**Goals:**

1. Make `--parent` a complete operation — one command should establish both the informational relationship (child → parent) and the blocking dependency (parent blocked by child)
2. Fail fast if the parent ticket doesn't exist or is ambiguous
3. Warn (but proceed) if the parent is already closed
4. Maintain backward-compatible output (just the child ID)
5. Update documentation to reflect the enhanced behavior

**Non-Goals:**

- Changing the semantics of `deps:` or `parent:` fields
- Adding bidirectional blocking (child is not blocked by parent)
- Modifying the `tk dep` command behavior

## Semantics

- `parent:` field on child — informational/organizational relationship ("this task belongs to that epic")
- `deps:` array on parent — blocking relationship ("parent cannot close until these are done")

When using `--parent`, both are established. The child is not blocked by the parent.

## Implementation Details

**Changes to `cmd_create()` (lines 112-178):**

The function currently parses `--parent` and stores it in a local variable, then writes `parent: $parent` to the child's frontmatter. The enhanced flow will be:

1. **Before creating the child ticket:** If `--parent` is provided, validate it exists using `ticket_path()`. If the lookup fails (not found or ambiguous), exit with an error before creating anything.

2. **Check parent status:** If the parent exists but has `status: closed`, print a warning to stderr: `Warning: parent <id> is closed`

3. **Create the child ticket:** Existing behavior — write the markdown file with `parent: <parent-id>` in frontmatter.

4. **Update the parent's deps:** Call `cmd_dep "$parent_id" "$child_id"` (or inline the logic) to add the child to the parent's `deps:` array. This reuses the existing `cmd_dep` logic which already handles appending to the YAML array.

**Output behavior:**

- stdout: Just the child ID (e.g., `proj-a1b2`)
- stderr: Warning if parent is closed, or error if parent not found

## Documentation Updates

**README.md (line 89):**

Current:
```
    --parent               Parent ticket ID
```

Updated:
```
    --parent               Parent ticket ID (also adds child as dependency on parent)
```

**`cmd_help()` output (line 1202):**

Same change — update the `--parent` description to indicate it establishes both the `parent:` field and the blocking dependency.

**CHANGELOG.md:**

Add under `## [Unreleased]` → `Changed`:
```
- `--parent` flag on `create` now also adds child as dependency on parent ticket
- `create --parent` fails if parent ID not found or ambiguous
- `create --parent` warns (to stderr) if parent ticket is closed
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Parent ID not found | Error to stderr, exit 1, no child created |
| Parent ID ambiguous (matches multiple) | Error to stderr, exit 1, no child created |
| Parent is closed | Warning to stderr, proceed with creation |
| Parent already has deps | Append child to existing array |
| Parent has empty deps `[]` | Add child as first element |

## Manual Testing Checklist

```bash
# Happy path
tk create "Parent task"           # note the ID, e.g., proj-1234
tk create "Child task" --parent proj-1234
tk show proj-1234                 # verify deps: [proj-XXXX]

# Error: parent not found
tk create "Orphan" --parent nonexistent  # should fail

# Warning: closed parent
tk create "Parent" && tk close <id>
tk create "Child" --parent <id>   # should warn but succeed

# Partial ID matching still works
tk create "Child" --parent 1234   # partial match
```

## Implementation Plan

1. Modify `cmd_create()` to validate parent before creating child
2. Add closed-parent warning logic
3. Add call to update parent's deps after child creation
4. Update `cmd_help()` output
5. Update README.md usage section
6. Add CHANGELOG.md entry
7. Manual testing per checklist above
