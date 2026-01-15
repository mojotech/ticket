---
id: code-review-pr5
status: open
deps: []
links: []
created: 2026-01-15T21:56:00Z
type: task
priority: 1
assignee: 
---
# Code Review: PR #5 - Add prune command

Code review findings for PR #5 that adds the `prune` command to delete old closed tickets.

## Critical Issues (Must Fix Before Merge)

### 1. Non-recursive Dependency Protection (CRITICAL)

**Location:** `cmd_prune()` lines 1282-1290

**Problem:** Only *direct* dependencies of open tickets are protected. Transitive dependencies are vulnerable.

**Example:**
- Ticket A (open) depends on B (closed)
- Ticket B depends on C (closed, old)
- `tk prune` will delete C, even though A transitively requires it
- Later reopening B leaves it permanently blocked by missing ticket C

**Solution:** Implement recursive dependency collection (see Design section below)

### 2. Unsafe `closed_at` Field Removal (HIGH)

**Location:** `cmd_status()` lines 229-230

```bash
if _grep -q "^closed_at:" "$file"; then
    _sed_i "$file" '/^closed_at:/d'
fi
```

**Problem:** Deletes ANY line starting with `closed_at:` anywhere in the file, not just in YAML frontmatter. User content in ticket body could be corrupted.

**Solution:** Restrict deletion to frontmatter using sed range:
```bash
_sed_i "$file" '1,/^---$/{ /^closed_at:/d; }'
```

### 3. Dangling Links After Prune (HIGH)

**Problem:** When tickets are pruned, `links` arrays in other tickets retain references to deleted ticket IDs.

**Solution Options:**
- A) Clean up references during prune (more complex, maintains integrity)
- B) Document that dangling refs are expected behavior (simpler, matches git's design)

### 4. Destructive by Default (HIGH)

**Problem:** `tk prune` deletes files immediately without confirmation. Most CLI tools require `-f/--force` for destructive operations.

**Solution Options:**
- A) Make `--dry-run` the default, require `--force` to actually delete
- B) Add interactive confirmation prompt when not piped
- C) Document prominently and leave as-is (dangerous but explicit)

## Medium Issues

### 5. Race Condition

**Problem:** Ticket status checked at scan time. If reopened by another process before `rm`, it gets deleted anyway.

**Mitigation:** Re-check status immediately before deletion:
```bash
local current_status
current_status=$(yaml_field "$filepath" "status")
[[ "$current_status" != "closed" ]] && continue
rm "$filepath"
```

### 6. O(N^2) Performance

**Location:** Line 1302
```bash
if echo "$protected_deps" | _grep -qx "$id" 2>/dev/null; then
```

**Problem:** Spawns grep process for every ticket. With 1000 tickets, that's 1000 process spawns.

**Solution:** Use awk associative array for O(1) lookup:
```bash
# Build protected set inline in awk, check with: if (id in protected) continue
```

### 7. BSD sed Compatibility

**Location:** `update_yaml_field()` line 106

```bash
_sed_i "$file" "0,/^---$/ { /^---$/a\\
```

**Problem:** `0,/pattern/` is GNU-only syntax. BSD sed requires `1,/pattern/`.

### 8. Ambiguous Dry-Run Output

**Problem:** Output looks identical whether `--dry-run` is set or not until the final summary line.

**Solution:** Prefix each line with `[DRY-RUN]` when in dry-run mode.

## Low Issues

1. **Regex in grep:** `_grep -qx "$id"` treats ID as regex; use `-F` for literal
2. **ARG_MAX risk:** `awk ... "$TICKETS_DIR"/*.md` glob could exceed max args
3. **Missing `done` status:** `cmd_closed` handles `done` but `cmd_prune` only handles `closed`
4. **`parent` not protected:** Pruning a closed parent leaves children with broken `parent:` reference
5. **Grep option injection:** ID starting with `-` could fail; use `-- "$id"`
6. **Pipe separator collision:** Filepath containing `|` breaks `read` parsing

## Design: Transitive Dependency Protection

The current implementation only protects direct dependencies:

```
A (open) -> B (closed) -> C (closed)
                          ^ VULNERABLE
```

### Proposed Solution: Iterative Closure

Replace the single-pass direct dependency collection with an iterative approach that follows the entire dependency chain:

```bash
# Collect ALL transitive dependencies of open/in_progress tickets
collect_transitive_deps() {
    local ticket_data="$1"
    local queue=""
    local protected=""
    
    # Seed queue with direct deps of active tickets
    queue=$(echo "$ticket_data" | awk -F'|' '
        $3 == "open" || $3 == "in_progress" {
            n = split($5, arr, ",")
            for (i = 1; i <= n; i++) if (arr[i] != "") print arr[i]
        }' | sort -u)
    
    # Iteratively expand until no new deps found
    while [[ -n "$queue" ]]; do
        protected=$(printf '%s\n%s' "$protected" "$queue" | sort -u)
        
        # Find deps of items in queue
        local next_queue=""
        next_queue=$(echo "$ticket_data" | awk -F'|' -v queue="$queue" '
            BEGIN { n = split(queue, arr, "\n"); for (i in arr) need[arr[i]] = 1 }
            $2 in need {
                m = split($5, deps, ",")
                for (j = 1; j <= m; j++) if (deps[j] != "") print deps[j]
            }' | sort -u)
        
        # Remove already-protected items from next queue
        queue=$(comm -23 <(echo "$next_queue") <(echo "$protected"))
    done
    
    echo "$protected"
}
```

### Alternative: Single-Pass AWK Solution

More efficient - collect all deps in one awk pass, then compute transitive closure:

```awk
# In the prune awk script:
END {
    # Build dependency graph
    for (id in all_deps) {
        n = split(all_deps[id], arr, ",")
        for (i = 1; i <= n; i++) if (arr[i] != "") {
            dep_graph[id, ++dep_count[id]] = arr[i]
        }
    }
    
    # Compute transitive closure from active tickets
    for (id in statuses) {
        if (statuses[id] == "open" || statuses[id] == "in_progress") {
            mark_protected(id)
        }
    }
}

function mark_protected(id,    i, dep) {
    if (id in protected) return
    protected[id] = 1
    for (i = 1; i <= dep_count[id]; i++) {
        dep = dep_graph[id, i]
        if (dep != "") mark_protected(dep)
    }
}
```

## Acceptance Criteria

- [ ] Transitive dependencies of open tickets are protected from pruning
- [ ] `closed_at` removal is scoped to YAML frontmatter only
- [ ] Either dry-run is default OR output clearly distinguishes dry-run mode
- [ ] `shellcheck` passes with no warnings
- [ ] Manual testing confirms all scenarios work on both GNU and BSD

## Notes

Review conducted by 3 parallel code-review agents. Findings correlated by severity.
