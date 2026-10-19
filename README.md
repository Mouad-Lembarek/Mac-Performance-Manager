# Mac Performance Manager

[![CI](https://github.com/Mouad-Lembarek/Mac-Performance-Manager/actions/workflows/ci.yml/badge.svg)](https://github.com/Mouad-Lembarek/Mac-Performance-Manager/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-Apple_Silicon-000000?logo=apple)
![Bash 3.2+](https://img.shields.io/badge/Bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white)

A lightweight terminal tool that helps you keep an 8 GB Apple Silicon Mac responsive
while working with Cursor, AI agents, Brave, ChatGPT, Node.js, Python and Docker.

It measures, explains and recommends. It does not "optimize" anything behind your back:
no script can add physical RAM, and the only real fix for memory pressure is running
less at once. This tool tells you, with measurements, *what* to close.

- One Bash script, macOS built-in tools only (`vm_stat`, `sysctl`, `ps`, `top`, `df`,
  `pmset`, `lsof`). No Homebrew, Python or npm packages.
- No sudo, no network access, no telemetry, no background daemon.
- Never kills, quits or deletes anything of yours without a typed confirmation, and never
  deletes permanently (cleanup moves folders to the Trash). The one exception is opt-in and
  off by default: in a work session, the `AUTO_STOP_IDLE_*` rules can stop an idle TypeScript
  server or dev server (SIGTERM only, announced first, `x` cancels). See
  [Work mode](#work-mode-work-session).
- Runs on the `/bin/bash` 3.2 that ships with macOS.

---

## Installation

**One command** (no clone, no sudo, no Homebrew):

```bash
curl -fsSL https://raw.githubusercontent.com/Mouad-Lembarek/Mac-Performance-Manager/master/install.sh | bash
```

This downloads the script to `~/.local/share/mac-performance-manager/` and creates the `mpm`
command in `~/.local/bin`. Prefer to read an installer before running it? Download
[`install.sh`](install.sh), read it, then run `bash install.sh`. It never uses sudo and never
edits your shell profile: if `~/.local/bin` is not in your `PATH`, it prints the one line to add.

**From a clone** (read everything first, update with `git pull`):

```bash
git clone https://github.com/Mouad-Lembarek/Mac-Performance-Manager.git
cd Mac-Performance-Manager
./install.sh                     # optional: adds the mpm command
./mac-performance-manager.sh     # or run it directly, without installing
```

Then:

```bash
mpm --once     # one overview
mpm            # menu
mpm --work     # all-day monitor in a terminal tab
```

**Update:** run the same `curl ... | bash` command again, or `git pull` in your clone.
`mpm --version` shows the installed version.

**Uninstall:** `./install.sh --uninstall` (from a clone), or

```bash
curl -fsSL https://raw.githubusercontent.com/Mouad-Lembarek/Mac-Performance-Manager/master/install.sh | bash -s -- --uninstall
```

It removes the `mpm` command and moves `~/.local/share/mac-performance-manager/` (script,
settings, logs, reports) to the Trash. A clone is never touched; delete its folder yourself.

**Settings** (optional): copy `config.env.example` to `config.env` next to the script (in
your clone, or in `~/.local/share/mac-performance-manager/`), edit it, then check it:

```bash
mpm --check-config     # shows effective values and any problems; exits 1 if there are errors
```

The first run calls `system_profiler` once (about 1 second) to learn the model name
("MacBook Air") and caches it. Every later run skips this.

---

## Usage

After installing, `mpm` works in place of `./mac-performance-manager.sh` everywhere below.

| Command | What it does |
|---|---|
| `./mac-performance-manager.sh` | Interactive menu |
| `./mac-performance-manager.sh --live` | Live overview, refreshes every 4 s. `q` quits |
| `./mac-performance-manager.sh --work` | Work mode for the whole day. `q` or Ctrl+C stops it |
| `./mac-performance-manager.sh --report` | Concise report, printed and saved in `reports/` |
| `./mac-performance-manager.sh --once` | Print one overview and exit |
| `./mac-performance-manager.sh --stop` | Stop a work mode running in another terminal |
| `./mac-performance-manager.sh --check-config` | Show effective settings and config warnings |
| `./mac-performance-manager.sh --help` | Help |

Options: `--config FILE` (or `MPM_CONFIG=FILE`) uses another config file;
`--no-color` disables colours (`NO_COLOR` is respected too).

### Suggested daily routine

1. In the morning, open a terminal tab and run `./mac-performance-manager.sh --work`.
   Leave it there. It prints one status line and only speaks up when something is
   *sustained*.
2. When the Mac feels slow, open the menu in another tab: **2** (memory) tells you whether
   RAM is really the problem, **7** (Cursor) and **8** (dev processes) tell you what is using it.
3. Use **9** (safe cleanup) to act, then **9 > 9** to compare before/after.
4. At the end of the day, `--report` gives you a summary with recent warnings.

---

## Menu

| # | Item | Notes |
|---|---|---|
| 1 | Live system overview | Cheap `ps`-based sampling. `q` returns to the menu, Ctrl+C exits |
| 2 | Memory diagnostics | Pressure, breakdown, compression, swap rates, swap history, grouped apps |
| 3 | CPU diagnostics | 1-second `top` sample plus 3 `ps` samples to find *consistently* busy processes |
| 4 | Disk diagnostics | Free space, targeted folder scans, Trash moves, known cache sizes, Docker disk |
| 5 / 6 | Top memory / CPU processes | With application grouping and "started by" |
| 7 | Cursor diagnostics | Process roles, child processes, extensions, how to use Cursor's own tools |
| 8 | Development processes | Node/Python/DB/AI runtimes, listening dev servers + project folder, Docker |
| 9 | Safe cleanup | Guided actions with a baseline and a before/after comparison |
| 10 | Process management | Terminate a PID or quit an app, with review and confirmation |
| 11 | Start work mode | Same as `--work`, in the foreground |
| 12 | Stop monitoring | Stops a work mode running in another terminal |
| 13 | Exit | |

---

## How memory is judged

macOS deliberately keeps RAM full (file cache, compression), so "RAM 95% used" means
nothing on its own. The tool combines three signals:

1. **Kernel pressure level**: `sysctl kern.memorystatus_vm_pressure_level`
   (1 = normal, 2 = warning, 4 = critical). This is the same judgment behind Activity
   Monitor's memory-pressure graph.
2. **macOS free estimate**: `sysctl kern.memorystatus_level`, the percentage the
   `memory_pressure` tool prints. It counts free *and easily reclaimable* memory.
3. **Active swap-out rate**: the change in vm_stat's `Swapouts` counter per second. Data
   being pushed to disk *right now* is what makes a Mac feel sluggish.

Resulting status:

| Status | Meaning |
|---|---|
| OK | Pressure normal, no heavy swap-out. Existing swap is fine. |
| WATCH | Elevated in the latest sample, not yet sustained |
| HIGH | Elevated pressure or active swap-out for `SUSTAINED_SAMPLES` samples in a row |
| CRITICAL | Critical pressure (level 4 or free estimate below the critical %) sustained |
| UNKNOWN | Pressure could not be read; the tool does not guess |

**Swap** is tracked over time (`state/history.tsv`). Swap growing while pressure is
elevated produces a warning; a large but stable swap with normal pressure does not.
Swap shrinks slowly after you close apps; that is normal.

### Memory figures shown

| Figure | Source | Meaning |
|---|---|---|
| Used = app + wired + compressed | vm_stat | Same breakdown as Activity Monitor (approximation of "App Memory" = anonymous − purgeable pages) |
| Cached files | vm_stat | File cache, reclaimed instantly when needed |
| Compressor | vm_stat | RAM occupied by compressed data, and how much data it holds |
| MEM MB (per process) | `top` | Physical footprint, the value Activity Monitor shows |
| RSS MB (per process) | `ps` | Resident memory; used in live/work mode because it is cheaper |

**Group totals** (for example "Cursor ~3.7 GB across 8 processes") are sums of per-process
values. Summing RSS double-counts memory that Chromium/Electron helper processes share,
so RSS totals are an upper bound. Footprint sums are closer to reality but still
approximate. The tool labels which one you are looking at.

### "Started by"

Processes are attributed to the nearest application that launched them. A `node` process
under Cursor's extension host or integrated terminal shows **Cursor** in the "STARTED BY"
column, which tells you which language servers, agents and dev servers Cursor spawned.

---

## Cursor diagnostics (menu 7)

The tool classifies Cursor's processes by their Electron role:

- **main**: one per running Cursor instance (more than one means multiple instances)
- **renderer**: each window has one; webviews can add more, so the count is an
  *upper bound* on open windows. The exact window count is not reliably detectable.
- **plugin helper**: normally an extension host (one per window)
- **gpu / utility**: shared services (network, file watcher, terminal backend)
- **bundled tool**: for example `rg` (ripgrep) during searches

It reads only the `--type=` style role flags from these processes' arguments. Command
lines are never displayed or stored here.

It also lists processes started *by* Cursor (tsserver, pyright, eslint, terminals,
agents, dev servers), installed extensions from `~/.cursor/extensions`, and AI-assistant
extensions installed in addition to Cursor's built-in AI (Copilot, Continue, Cline,
Codeium, etc.). Each of these can run its own background services and indexing.

**Limitation:** macOS cannot attribute memory to an individual extension. All extensions
of a window share one extension-host process. To dig deeper, use Cursor itself:

- **Help > Open Process Explorer**: CPU/memory per window, extension host and language server
- **Cmd+Shift+P > "Developer: Show Running Extensions"**: activation times and CPU profiling
  (activation time alone does not mean high memory use)
- **"Developer: Restart Extension Host"**: resets a leaking extension host without closing windows
- **"Help: Start Extension Bisect"**: finds a problematic extension
- **Extensions view > Disable (Workspace)**: keep heavy extensions off in projects that do not need them
- `files.watcherExclude`, `search.exclude` and `.cursorignore`: keep `node_modules`, `dist`,
  `.venv` out of watching and indexing

The tool never disables extensions or changes settings.

---

## Development processes (menu 8)

- Node.js / Python / databases / local AI runtimes / Docker VM, with counts, memory and
  which app started them
- **Listening servers**: your processes that accept TCP connections (via `lsof`, without
  sudo), with port, memory, CPU, uptime and **project folder**. This is how you spot the
  `next dev` from yesterday's project that is still running.
- Node/Python command lines, **on screen only**, with likely secrets redacted (`--token`,
  `API_KEY=...`, `postgres://user:pass@...`, long random strings), truncated
- Docker containers with CPU/memory (`docker stats`, only if Docker is running)

Low CPU means a server is idle *now*, not that it is unused. You decide what to stop.

---

## Disk (menu 4)

- Startup-disk free space. On APFS the Data volume is measured; `df` does not count
  "purgeable" space that Finder may include in its "available" figure.
- **Targeted scan** of a folder you choose (default `~/Projects`) for `node_modules`,
  `.next`, `.turbo`, `__pycache__`, `.venv`, `dist`, `build`, `target` and similar.
  The scan skips `~/Library`, `~/.Trash` and `.git`, and Ctrl+C aborts it. Nothing is
  ever scanned automatically.
- **Move to Trash**, one item at a time, after showing path, size, what it is and the
  risk, and only after you type `trash`. Rules:
  - `node_modules`, framework caches and Python caches: offered (regenerated by tools)
  - `.venv`, `dist`, `build`, `target`, `coverage`, `.cache`: offered **only if Git
    ignores them**, because some projects commit these
  - anything containing Git-tracked files, symlinks, or paths outside the scanned
    folder: never offered
  - the Trash move uses Finder (reversible, "Put Back" works); if macOS denies that, it
    falls back to `~/.Trash`. Space is freed when you empty the Trash.
- **Known caches** (npm, pnpm, pip, uv, Yarn, Hugging Face, Ollama models, Homebrew,
  Xcode DerivedData and simulators, Cursor cached data/workspace storage/logs, Docker disk
  image): sizes plus the *official* cleanup command for each. These are report-only;
  you run the commands yourself.
- Docker volumes, databases, source code, Git repositories, credentials, configuration
  and browser profiles are never touched.

---

## Safety model

**Terminating a process** (menu 10 > 1, or 9 > 7):

1. Shows name, PID, parent, CPU, memory, running time, and the redacted command line
   (and project folder for dev processes).
2. Warns about the specific kind: Cursor helper (may crash a window or interrupt agents),
   app main process (suggests graceful quit instead), Docker/database (may lose in-flight
   writes), dev process.
3. Requires typing `yes` (`y` is not accepted).
4. Re-checks that the PID still belongs to the same process (start time + executable)
   before sending anything, which guards against PID reuse. If the start time cannot be
   read, the process is refused.
5. Sends **SIGTERM** (graceful) and waits `KILL_GRACE_SEC`.
6. If the process is still running, SIGKILL is only *offered* and requires typing `KILL`.

**Always refused:** PID 0/1, this tool, the shell and terminal running it, another
instance of this tool, processes owned by other users or root, anything under
`/System`, `/usr`, `/bin`, `/sbin`, `/Library/Apple`, session-critical processes
(WindowServer, loginwindow, Finder, Dock, Terminal, etc.), and processes that cannot be
identified.

**Quitting an app** (menu 10 > 2) asks the app to quit normally via AppleScript, so it can
ask you to save. The first time, macOS may ask whether your terminal may control that
app (System Settings > Privacy & Security > Automation).

**What this tool deliberately does not do**, because these are placebo or harmful:
`sudo purge`, clearing caches wholesale, changing swap/VM settings, disabling Spotlight,
SIP, Gatekeeper, sleep or system services, renicing processes, deleting Docker volumes or
project dependencies, killing processes automatically (the only exception is the opt-in,
off-by-default idle-server rules of [work mode](#work-mode-work-session)), restarting anything. If a restart
would help (large swap plus persistent slowness), it is *recommended*, never performed.

---

## Work mode (work session)

Start it when you begin working, leave the Terminal window open, stop it when you finish:

```bash
cd ~/Desktop/"Mac performance manager"
./mac-performance-manager.sh --work          # start
# stop: press q (or Ctrl+C) in that window, or from another terminal:
./mac-performance-manager.sh --stop
```

It runs in the foreground of that window only: no LaunchAgent, no daemon, nothing keeps
running after it stops. Only one session can run at a time (pidfile in `state/`).

**What it does by itself**

- Samples pressure, the macOS free estimate, swap use and the current swap-in/out rate,
  CPU, and per-process CPU every `WORK_INTERVAL_SEC` (30 s). Disk is checked every 10 min.
- Adapts its state: **NORMAL** (quiet), **ELEVATED** (one short hint naming the largest
  consumers), **HIGH** (sustained for `SUSTAINED_SAMPLES` samples: the likely causes,
  development processes and the options below), then **RECOVERY** (what dropped since the
  problem started, and the actions you took meanwhile, reported as correlation, not proof).
  Large swap alone is history, not a problem. Warnings need current pressure or active swap-out.
- Automatic actions change only the manager's **own** behaviour, and each one is logged:
  - after `WORK_RELAX_AFTER_SAMPLES` calm samples it samples every `WORK_RELAXED_INTERVAL_SEC`
    (60 s). On any pressure it goes back to 30 s, and the slower setting ends with the session;
  - warnings and recommendations are rate-limited (`NOTIFY_COOLDOWN_MIN`);
  - a detailed per-process sample (`top`, about 1-2 s of CPU) runs only when you ask or when a
    warning starts, and is reused until the next routine sample;
  - expensive disk scans ask first while pressure is high;
  - on exit it stops only helper processes it started, after checking their parent PID.

- **Opt-in automatic actions that do free memory** (each off unless enabled in `config.env`):

  | Setting | What it may do on its own |
  |---|---|
  | `AUTO_STOP_IDLE_TSSERVER` (+ `AUTO_TSSERVER_IDLE_MIN`, 30) | Stop an idle TypeScript language server whose parent is Cursor's/VS Code's extension host. Cursor starts a new one when that project needs it. |
  | `AUTO_STOP_IDLE_DEVSERVER` (+ `AUTO_DEVSERVER_IDLE_MIN`, 30) | Stop an idle local `next dev` / `vite` server. It is stopped like Ctrl+C and **not** restarted. |
  | `AUTO_CLEAN_MANAGER_TEMP` | Delete stale temporary files the manager itself left in `state/` after an interrupted run. Nothing else is ever deleted. |

  **Common conditions, all re-checked right before acting:**
  - memory pressure is *sustained* HIGH or CRITICAL;
  - the process is positively identified (see below);
  - it was **idle for the whole period while the session watched it**: average CPU at most 0.5%
    of one core, plus 1 s of slack. A low CPU figure at one moment is not enough;
  - no busy child, build or test under it.

  **Dev servers must also:**
  - be a `next dev`/`vite` launcher under your home folder, with a `package.json`;
  - have a listening port and **no connected browser or client**;
  - have **no file in the project changed** during the idle period (generated folders such as
    `node_modules`, `.next`, `dist` and `.git` are ignored). If that can't be checked, the
    server is left alone;
  - have no build, test, lint or type check running under it, or anywhere in the same
    project. Those are recognised by their command line (`tsc`, `vitest`, `next build`,
    `npm test`...), because JavaScript tools all show up as `node`;
  - not have been started by an AI agent, and have **no AI agent working in the project**.
    Agents are recognised by name or command line (e.g. `node .../claude-code/cli.js`). An
    agent working from a folder that contains the project, such as your home folder, also
    counts;
  - be checkable with `lsof`; if `lsof` is unavailable, ownership can't be established and nothing is stopped.

  Idle time covers the server's whole process tree, workers included.

  **How an action is carried out:**
  - It is announced `AUTO_ACTION_GRACE_SEC` (60 s) ahead, also as a notification. `x` cancels,
    and that process is not picked again in the session.
  - It sends SIGTERM only, never SIGKILL, and never restarts anything.
  - Least disruptive first: TypeScript servers before dev servers.
  - `AUTO_COOLDOWN_MIN` (10) between actions, at most `AUTO_MAX_ACTIONS` (4) per session.

  **Measured afterwards:**
  - A TypeScript server is ineffective if Cursor restarted it and took the memory back.
  - A dev server is ineffective if its port is served again, or if the free estimate did not
    rise 2 points and swap-out did not halve.
  - After `AUTO_MAX_INEFFECTIVE` (2) ineffective actions, that rule pauses for the session.
  - If the session ends during a notice period, the action is dropped.

  **Never automatic:** quitting Cursor, Brave, ChatGPT, Slack, WhatsApp, terminals or AI agents;
  closing tabs; unknown processes; deleting caches, `node_modules` or anything of yours;
  emptying the Trash; sudo; system settings.

  **The other automatic actions do not free memory for your apps.** No script can safely do that for you
  without approval: the macOS `purge` command needs sudo and only empties caches, and lowering
  another app's priority cannot be undone without admin rights. What relieves memory pressure
  is running less at once, and the session makes that a key press away.

**Keys while it runs** (in a Terminal: just the letter; sampling pauses while you answer a question):

| Key | Action |
|---|---|
| `s` | Status: state, sampling interval, last sample |
| `t` | Top consumers (detailed sample; reused if you ask again before the next sample) |
| `d` | Diagnose, then choose: browser memory help, stop a dev process, quit an app, or ignore |
| `k` | Development processes (Next.js, Vite, node, tsserver...) with memory, age, port, project folder and *what breaks if stopped*; stop one gracefully |
| `i` | Inspect a PID (read-only; says whether it is protected) |
| `c` | Disk tools: scan a folder, move a reviewed item to the Trash (asks first under high pressure) |
| `a` | Automatic actions, your decisions, and measured effects this session |
| `r` | Save a session report now |
| `n` | Sample now |
| `x` | Cancel a pending automatic action (that process is not selected again this session) |
| `q` | Stop the session |

Stopping a process always goes through the same review as menu 10: full details, typed
`yes`, identity and PID-reuse checks immediately before the signal, SIGTERM first, and
SIGKILL only if you type `KILL`. Quitting an app asks it to quit normally, so it can ask you to save.
By default nothing is stopped, quit or deleted automatically; the only exceptions are the
opt-in `AUTO_*` rules described above, each off unless you enable it.

**When it stops** (q, Ctrl+C, `--stop`, or the window closing) it prints and saves
`reports/report-session-*.txt` (process names only, no command lines or paths). The report covers:
- duration, and the share of samples at each pressure level, with the peak and the lowest free estimate;
- swap use at start, at end and at its peak, plus swapped-out/in volume and the peak swap-out rate;
- the largest groups at the worst moment;
- automatic actions, including the manager's own measured CPU time;
- your approved and declined actions, with the effect measured two samples later;
- remaining bottlenecks.

Reports are pruned to `REPORT_KEEP`. Session history in memory is capped at 40 entries per
list, and `logs/events.log` rotates at `LOG_MAX_KB`.

**Cost, measured on the development Mac** (8 GB, under memory pressure): about 0.85 s of CPU
per 100 s at the default interval, 1-4 MB of memory for the manager, and less than 1 KB
written per sample. Each detailed `top` sample costs about 1.4 s of CPU.

**Limitations:** sampling pauses while you answer a question. Individual browser tabs
are not visible, so use Brave's Task Manager (Shift+Esc). The project folder of a dev
process is the folder it was started in, and is not shown for processes started from `/`.
"Inactive project" cannot be detected reliably, so the list shows age, CPU and port and
leaves the decision to you.

---

## Configuration

All settings, defaults and allowed ranges are documented in
[`config.env.example`](config.env.example). The file is **parsed, not sourced**: unknown
keys, invalid numbers, out-of-range values and inconsistent pairs (critical ≥ warning)
are reported and replaced by defaults, and nothing in it can execute.

Most useful knobs:

| Setting | Default | Raise it if... |
|---|---|---|
| `SUSTAINED_SAMPLES` | 3 | you get warnings for short spikes |
| `PRESSURE_WARN_FREE_PCT` | 20 | lower it if WATCH appears while the Mac feels fine |
| `SWAPOUT_RATE_WARN_PAGES` | 50 | short swap bursts are flagged too eagerly |
| `CPU_PROC_WARN_PCT` | 80 | builds/indexing routinely trigger CPU warnings |
| `NOTIFICATIONS_ENABLED` | true | set false for terminal-only output |
| `WORK_INTERVAL_SEC` | 30 | the manager's own CPU use matters more than reaction time |
| `WORK_RELAXED_INTERVAL_SEC` | 60 | calm periods can be sampled even less often (must be ≥ `WORK_INTERVAL_SEC`) |
| `WORK_RELAX_AFTER_SAMPLES` | 10 | you want it to relax later (0 = never relax) |
| `DEV_CANDIDATE_MIN_MB` | 100 | the dev list (key `k`) shows too many small processes |
| `SESSION_REPORT_ENABLED` | true | set false to print the session summary without saving it |
| `AUTO_STOP_IDLE_TSSERVER` | false | set true to let the session stop idle TypeScript servers under sustained pressure |
| `AUTO_TSSERVER_IDLE_MIN` | 120 | a TypeScript server must have been idle this many minutes (observed by the session) |
| `AUTO_ACTION_GRACE_SEC` | 60 | you want more time to press `x` before an automatic stop |

---

## Files and privacy

Everything stays on your Mac, in the script folder (or `DATA_DIR`), created with
permissions `600`/`700`. If the script folder is not writable (for example a system-wide
install), the tool uses `~/Library/Application Support/mac-performance-manager/` instead:

| Path | Content |
|---|---|
| `logs/events.log` | Important events: status changes, confirmed actions (process **name** and PID only). Rotated at `LOG_MAX_KB` |
| `state/history.tsv` | Timestamp, swap MB, pressure level, free %, compressed MB, disk free MB |
| `state/static.cache` | Model identifier and model name (no serial number) |
| `state/work.pid` | PID and start time of a running work mode |
| `reports/report-session-*.txt` | Work-session summaries (names and numbers only) |
| `reports/report-*.txt` | Reports (last `REPORT_KEEP` kept) |

Command lines, arguments, file paths of processes and environment variables are never
written to disk. `.gitignore` excludes all of the above plus your `config.env`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `mpm: command not found` after installing | `~/.local/bin` is not in your `PATH`. Run the `echo 'export PATH=...' >> ~/.zshrc` line the installer printed, or use `~/.local/bin/mpm` |
| `Permission denied` when starting | Run `chmod +x mac-performance-manager.sh`, or start it with `bash mac-performance-manager.sh` |
| "this tool supports macOS only" | It reads macOS-specific kernel counters and will not run elsewhere |
| Pressure shows `unknown` | Your macOS did not expose the sysctl; the tool falls back to `memory_pressure`. If both fail, status is UNKNOWN rather than a guess |
| Many `*` in the MEM column | `top` gave no footprint for those processes (usually other users' processes); RSS is shown instead |
| "Listening servers: None found" | `lsof` sees only your own processes without sudo, which is what you want here |
| Quit app says macOS did not allow it | Allow your terminal under System Settings > Privacy & Security > Automation, or press Cmd+Q in the app |
| Trash move falls back or fails | Finder automation was denied; the tool tries `~/.Trash`, otherwise prints the path for you to handle |
| Docker section says engine not running | Docker Desktop is closed or still starting; the tool waits at most 6 s |
| Colours look wrong | Use `--no-color` or `COLOR=never` |
| Git popup asking to install developer tools | Should not happen: the tool checks `xcode-select -p` before using `/usr/bin/git`. Without Git, ignored-only artifacts are simply not offered |

---

## Project structure

```
mac-performance-manager.sh   the tool (the only file needed to use it)
install.sh                   optional installer: adds/removes the mpm command
config.env.example           documented settings; copy to config.env to customise
README.md                    this file
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

**Results on the development Mac** (macOS 27.0.1, Apple Silicon, `/bin/bash` 3.2.57,
`/usr/bin/awk`): **204 passed, 0 failed, 2 skipped.** The two skips are expected there:

| Skipped test | Why |
|---|---|
| required tool missing (`vm_stat`) | Needs a system without `vm_stat`. macOS always ships `/usr/bin/vm_stat`, and the script adds `/usr/bin` to `PATH`, so this can only run on a non-macOS host |
| BWK awk comparison | Compares output with `original-awk`, which is not installed. On macOS, `/usr/bin/awk` already *is* BWK awk, so the main run covers it |

**Not tested:** other macOS versions or Intel Macs, Homebrew bash 4/5 (`MPM_TEST_SHELL`),
non-macOS hosts, and the real Finder/AppleScript path for moving to the Trash (stubbed).
Real `top`, `lsof`, `pmset`, `docker` and `system_profiler` output is not exercised either,
only fixtures. Only the process-safety tests use the real `ps`.

### Safety fixes made after testing on macOS

Fault injection showed two cases where the termination guard failed *open*. Both are fixed,
and the tests above fail if either fix is reverted:

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

---

## Limitations

- The test suite passes on macOS 27.0.1 (Apple Silicon, bash 3.2.57), but with stubbed tool
  output. Real-world output formats of `top`, `lsof`, `pmset` and `docker` on other macOS
  versions should be checked on first use. See "Tests" for what is not covered.
- Window and workspace counts for Cursor are estimates; memory per extension is not
  measurable from the OS.
- Group memory totals are approximations, as described above.
- `ps` CPU% is a recent average; precise CPU needs the 1-second `top` sample used in diagnostics.
- Recommendations name the biggest measured consumers. They cannot know which window,
  tab or server you still need.

---

## License

[MIT](LICENSE)
