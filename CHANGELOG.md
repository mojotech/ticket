# Changelog

## [Unreleased]

### Added
- `prune` command to delete old closed tickets
  - `--days=N` to set age threshold (default: 7 days)
  - `--all` to prune regardless of age
  - `--dry-run` to preview without deleting
- `closed_at` timestamp field set when tickets are closed
- Dependency protection: closed tickets referenced by open/in-progress tickets are never pruned

### Fixed
- Recursive dependency protection in `prune` command (was only direct)
- BSD sed compatibility in `update_yaml_field` (was GNU-only)
- O(N^2) performance in `prune` dependency lookup by using awk associative arrays

### Changed
- `prune` command now prefixes dry-run output with `[DRY-RUN]` for clarity
- `prune` command now considers `done` status as eligible for pruning
- `update_yaml_field` now uses more robust first-line substitution for new fields

## [0.2.3] - 2026-01-14

### Added

- `--dep` flag for `create` command to add initial dependency at creation time

### Changed

- Clarified `--parent` flag documentation: advisory metadata for epic/subtask hierarchy, not a blocking dependency

## [0.2.2] - 2026-01-13

### Added

- `--version` / `-V` flag to print the current version

## [0.2.1] - 2026-01-26

### Added

- `add-note` command for appending timestamped notes to tickets
- Nix flake support for installation via `nix run github:wedow/ticket`

## [0.2.0] - 2026-01-04

### Added

- `--parent` flag for `create` command to set parent ticket
- `link`/`unlink` commands for symmetric ticket relationships
- `show` command displays parent title and linked tickets
- `migrate-beads` now imports parent-child and related dependencies

## [0.1.1] - 2026-01-02

### Fixed

- `edit` command no longer hangs when run in non-TTY environments

## [0.1.0] - 2026-01-02

Initial release.
