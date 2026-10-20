# Mac Performance Manager: user guide

The complete reference. For installation and a quick start, see the [README](../README.md).
Settings are documented line by line in [`config.env.example`](../config.env.example).

- [Usage](#usage) · [Menu](#menu) · [How memory is judged](#how-memory-is-judged)
- [Cursor diagnostics](#cursor-diagnostics-menu-7) · [Development processes](#development-processes-menu-8) · [Disk](#disk-menu-4)
- [Safety model](#safety-model) · [Work mode](#work-mode-work-session) · [Configuration](#configuration)
- [Files and privacy](#files-and-privacy) · [Troubleshooting](#troubleshooting) · [Limitations](#limitations)

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
mpm --work          # start (or ./mac-performance-manager.sh --work)
# stop: press q (or Ctrl+C) in that window, or from another terminal:
mpm --stop
```

It runs in the foreground of that window only: no LaunchAgent, no daemon, nothing keeps
running after it stops. Only one session can run at a time, however it was started (`--work`, menu item 11, or the `mpm`
command): the pidfile in `state/` records its PID and start time.

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
[`config.env.example`](../config.env.example). The file is **parsed, not sourced**: unknown
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

## Limitations

- The test suite passes on macOS 27.0.1 (Apple Silicon, bash 3.2.57), but with stubbed tool
  output. Real-world output formats of `top`, `lsof`, `pmset` and `docker` on other macOS
  versions should be checked on first use. See [DEVELOPMENT.md](DEVELOPMENT.md#tests) for what is not covered.
- Window and workspace counts for Cursor are estimates; memory per extension is not
  measurable from the OS.
- Group memory totals are approximations, as described above.
- `ps` CPU% is a recent average; precise CPU needs the 1-second `top` sample used in diagnostics.
- Recommendations name the biggest measured consumers. They cannot know which window,
  tab or server you still need.
