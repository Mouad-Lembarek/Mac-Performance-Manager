# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-20

First public release.

### Added

- One-command install and uninstall (`install.sh`): installs the `mpm` command in
  `~/.local/bin`, from a clone or piped from `curl`. Checks the download before using it,
  never replaces an unrelated `mpm`, never uses sudo or edits your shell profile. Uninstall
  moves the downloaded copy to the Trash and never touches a clone.
- If the script's folder is not writable, logs, history and reports go to
  `~/Library/Application Support/mac-performance-manager/` instead of being disabled.
- Documentation split into a short README, a [user guide](docs/GUIDE.md) and a
  [development guide](docs/DEVELOPMENT.md); contributing guide, security policy and issue
  templates.

### Changed

- Recommendations adapt to the detected RAM: the "heavy app" cutoff (10% of RAM) is capped at
  1 GB, and when no app group reaches it the 3 largest are named, so a large-RAM Mac under
  pressure always gets advice. Advice text uses the detected RAM instead of "8 GB".
- `--check-config` exits with status 1 when the configuration has errors.
- The safety statements in the script header, `--help` and the docs now name the one exception
  to "never kills without confirmation": the opt-in, off-by-default `AUTO_STOP_IDLE_*` rules.

### Fixed

- A work mode started from the menu (item 11) was not recognised: a second `--work` could start,
  and `--stop` reported "not running" and deleted the live session's pidfile. The owner is now
  identified by PID plus start time (recorded in UTC, so a time-zone change does not matter).
- Two work modes started at the same moment could both run. Claiming the pidfile is now
  serialised by an atomic lock; a lock left by a killed instance is recovered after a minute.
- The `rm -rf` command printed when a Trash move fails now quotes its path safely, so a folder
  name containing a quote cannot turn the pasted command into something else.

### Safety fixes found by testing on macOS

Fault injection showed two cases where the termination guard failed *open*. Both are fixed,
and the test suite fails if either fix is reverted:

1. **Unparsable `ps` output** (`proc_fields`): if a `ps` line did not match the expected
   layout, the whole raw line was used as the process name. That defeated the
   `/System`, `/usr`... check, so a macOS process could be offered for termination. Such
   a line now gives an empty name, and the process is refused as "cannot be identified".
2. **Unreadable start time** (`terminate_flow`): if the start time could not be read at
   review, the empty value matched the (also empty) value read before sending the signal.
   The PID-reuse check then passed without checking anything. An empty identity is now refused.

A third fix concerns work mode, not termination:

3. **Work mode started through a symlink** (`pidfile_alive`, `work_mode`): a running work
   mode was recognised only if its command line contained `mac-performance-manager`. When
   it was started as `mpm --work` through an `mpm` symlink, a second
   `--work` started anyway. `--stop` said "not running" and deleted the live pidfile instead
   of stopping it. The pidfile now also records the start time, and an instance is recognised
   by PID + start time + `--work`. Two tests cover this, and both fail without the fix.
   Later the same bug was found for work mode started from the menu (item 11), whose command
   line has no `--work`: the owner is now recognised by PID + start time alone (recorded in
   UTC, so a time-zone change does not matter), and claiming the pidfile is serialised by an
   atomic lock so two work modes started at the same moment cannot both run.
4. **Trash move re-checked after confirmation** (`trash_artifact_flow`): the folder was
   validated at review but not again after `trash` was typed. If it was replaced by a
   symlink in between, Finder could have moved the symlink's target. Now the folder's
   identity (device + inode, symlinks not followed) is recorded at review. After `trash`
   is typed, every eligibility check runs again and the identity must still match. Tests
   swap the folder between review and confirmation (symlink, or another folder), and include
   a control that an unchanged folder is still moved.
