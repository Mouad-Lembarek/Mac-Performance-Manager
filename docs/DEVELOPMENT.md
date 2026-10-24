# Mac Performance Manager: development

How the project is laid out and how it is tested. To contribute, see
[CONTRIBUTING.md](../CONTRIBUTING.md). The history of fixes is in [CHANGELOG.md](../CHANGELOG.md).

## Project structure

```
mac-performance-manager.sh   the tool (the only file needed to use it)
install.sh                   optional installer: adds/removes the mpm command
config.env.example           documented settings; copy to config.env to customise
README.md                    overview, install, quick start
docs/GUIDE.md                full user guide
docs/DEVELOPMENT.md          this file
.gitignore                   excludes config.env, logs/, reports/, state/
tests/
  run_tests.sh               test suite (run from the project root, see below)
  bin/                       stubs for macOS tools (ps, sysctl, vm_stat, top, df, pmset,
                             lsof, memory_pressure, system_profiler, osascript, docker,
                             uname, sw_vers) plus `unavailable`, used to simulate a missing tool
  fixtures/                  recorded tool output and config files the stubs return
```

`logs/`, `reports/` and `state/` are created next to the script on first run (or in `DATA_DIR`).

---

## Tests

Run from the project root:

```bash
./tests/run_tests.sh
```

Run with a specific shell: `MPM_TEST_SHELL=/opt/homebrew/bin/bash ./tests/run_tests.sh`.

**How the suite stays independent of your Mac's state**

- macOS tools are replaced by the stubs in `tests/bin`, which print the output in
  `tests/fixtures`. The real tools are used only where a test needs them: `ps` for the
  throw-away test processes, `git`, `find` and `du` for the disk tests.
- Everything runs in a temporary folder that is also `HOME`. Git ignores your personal
  and system configuration. The `osascript` stub always fails, so Finder, the real Trash and
  Notification Center are never touched.
- Process-safety tests start their own throw-away processes. Each one is a symlink to
  `sleep` inside the temporary folder, because macOS kills a *copy* of its own signed
  binaries at launch. Conditions that cannot be created safely for real (a process owned
  by root, a macOS executable, a session-critical name, unparsable `ps` output, an unreadable
  start time, a PID reused between review and confirmation) are simulated by the `ps` stub
  for that one test process only.
- The disk tests give each artifact folder a clearly different size. The size ranking
  therefore does not depend on the order `find` returns folders in. Every refused
  artifact is also fed straight into the Trash flow, with `trash` typed, to prove it is
  never moved.
- On exit or Ctrl+C the suite kills only the processes it started, and only after checking
  that each PID still belongs to that process. Then it removes its temporary folder.

**What is covered:** parsers (`vm_stat`, `vm.swapusage`, `df`, `pmset`, `top -l 2`,
`memory_pressure`, `ps`); process classification and "started by"; config (valid, missing,
invalid, injection attempt); sustained detection, swap trends, history trimming, log rotation,
timeouts; every mode and menu item; missing tools; non-macOS refusal; Ctrl+C handling. Process
safety covers:
- cancel, an empty answer, end of input and `y` all send nothing
- SIGTERM only after `yes`
- a process that ignores SIGTERM is never force-killed without `KILL` (not `kill`)
- all protected and unverifiable cases are refused
- PID reuse is detected both before SIGTERM and before SIGKILL

Work sessions are driven through a FIFO, with pressure, disk and process table steered by the stubs:
- start, adaptive sampling (relax, and back on pressure), ELEVATED hint, sustained HIGH detection;
- disk scan deferred under pressure, the dev-process list (including duplicate TypeScript
  servers), declining and approving a graceful stop of a throw-away process, and the
  before/after measurement;
- recovery with attribution reported as correlation, reuse of detailed samples, inspect,
  diagnosis options, on-demand and final reports (no command lines or paths), and `q`;
- low-disk hint with no deletion, missing optional tools, and Ctrl+C with input attached;
- bounded history, and stopping only the manager's own helpers;
- the opt-in dev server rule, on throw-away `next dev` launchers:
  - only the verified idle one is stopped, and its server child with it;
  - left alone: started by an AI agent, client connected, build running under it,
    unverifiable folder;
  - a server that comes back counts as ineffective; cooldown; a pending action is dropped at shutdown;
- `AUTO_MAX_ACTIONS`, `AUTO_COOLDOWN_MIN`, no action without sustained pressure, a rule pausing
  itself, and pressure-based effect measurement;
- dev-server protections, one case at a time:
  - edits in the project (but not in `node_modules`), or unreadable changes;
  - a test runner seen as `node` in a subfolder, and not in another or similarly named project;
  - a build under the server;
  - AI agents seen as `node` (working in the project, in a parent folder, but not from `/`; or
    having started the server);
  - CPU of a grandchild;
- manager temp cleanup: off by default; removes only stale manager files and keeps live,
  recent, symlinked, unrelated and nested files;
- the opt-in idle TypeScript server rule, on throw-away `tsserver` processes:
  - nothing happens at normal pressure;
  - an announced stop is dropped when pressure eases, and cancelled by `x`;
  - SIGTERM after the notice, never SIGKILL;
  - a Cursor restart is detected and the rule pauses itself;
  - refusals: identity changed, not a TypeScript server, a protected PID.

Disk safety, reports without secrets, and static checks (no sudo/killall/pkill/purge,
no executed `rm -rf`, no network, no bash-4-only syntax, no GNU-only options) are covered too.

**Expected result on macOS** (macOS 27, Apple Silicon, `/bin/bash` 3.2.57,
`/usr/bin/awk`): **287 passed, 0 failed, 2 skipped** (about 5 minutes). The two skips are expected on macOS:

| Skipped test | Why |
|---|---|
| required tool missing (`vm_stat`) | Needs a system without `vm_stat`. macOS always ships `/usr/bin/vm_stat`, and the script adds `/usr/bin` to `PATH`, so this can only run on a non-macOS host |
| BWK awk comparison | Compares output with `original-awk`, which is not installed. On macOS, `/usr/bin/awk` already *is* BWK awk, so the main run covers it |

**Not tested:** other macOS versions or Intel Macs, Homebrew bash 4/5 (`MPM_TEST_SHELL`),
non-macOS hosts, and the real Finder/AppleScript path for moving to the Trash (stubbed).
Real `top`, `lsof`, `pmset`, `docker` and `system_profiler` output is not exercised either,
only fixtures. Only the process-safety tests use the real `ps`.
