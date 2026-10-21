# Mac Performance Manager

[![CI](https://github.com/Mouad-Lembarek/Mac-Performance-Manager/actions/workflows/ci.yml/badge.svg)](https://github.com/Mouad-Lembarek/Mac-Performance-Manager/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-Apple_Silicon-000000?logo=apple)
![Bash 3.2+](https://img.shields.io/badge/Bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white)
![No dependencies](https://img.shields.io/badge/dependencies-none-success)

**Find out what is really slowing down your Mac, and what to close.**

A small terminal tool for developers who run Cursor, AI agents, Docker, Node.js, Python and a
browser full of tabs on a Mac with too little RAM. It reads the same signals as Activity
Monitor, tells you whether memory is *really* the problem, and names the apps, language
servers and forgotten dev servers that are using it. It works well on 8 GB Macs and adapts
its advice to any amount of RAM.

![mpm --once on an 8 GB MacBook Air under memory pressure](docs/images/demo.gif)

## Why it is different

- **It explains instead of "optimizing".** No RAM cleaner, no `sudo purge`, no placebo. macOS
  keeps RAM full on purpose; the tool looks at kernel memory pressure and *active* swapping,
  which is what actually makes a Mac slow, and tells you what to close.
- **Made for developer workloads.** It knows Cursor's helper processes, TypeScript and Python
  language servers, `next dev` / `vite` servers left running in old projects (with their port
  and project folder), Docker, local AI runtimes such as Ollama, and which app started what.
- **Safe by design.** One Bash script using only macOS built-in tools. No sudo, no network
  access, no telemetry, no background daemon.
- **You stay in control.** Never kills, quits or deletes anything of yours without a typed
  confirmation, and never deletes permanently (cleanup moves folders to the Trash). The one
  exception is opt-in and off by default: in a work session, the `AUTO_STOP_IDLE_*` rules can
  stop an idle TypeScript server or dev server (SIGTERM only, announced first, `x` cancels).
  See the [safety model](docs/GUIDE.md#safety-model).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Mouad-Lembarek/Mac-Performance-Manager/master/install.sh | bash
```

This puts the script in `~/.local/share/mac-performance-manager/` and creates the `mpm`
command in `~/.local/bin`. It never uses sudo and never edits your shell profile; if
`~/.local/bin` is not in your `PATH`, it prints the one line to add. Prefer to read it first?
Open [`install.sh`](install.sh), then run `bash install.sh`.

Or from a clone, which lets you read everything first:

```bash
git clone https://github.com/Mouad-Lembarek/Mac-Performance-Manager.git
cd Mac-Performance-Manager
./install.sh                     # optional: adds the mpm command
./mac-performance-manager.sh     # or run it directly, without installing
```

**Update:** run the install command again, or `git pull` in your clone. **Uninstall:**
`./install.sh --uninstall`, or the install command followed by `-s -- --uninstall`. It removes the
`mpm` command and moves the downloaded copy to the Trash; a clone is never touched.

## Use

| Command | What it does |
|---|---|
| `mpm --once` | One overview: memory, CPU, disk, top processes, recommendations |
| `mpm --free` | **Free up memory:** a ranked plan of what to close, with what each step costs; you approve each step |
| `mpm` | Interactive menu: memory, CPU, disk, Cursor and dev-process diagnostics, safe cleanup |
| `mpm --work` | All-day monitor in a terminal tab. Quiet until a problem is *sustained*; `q` stops it |
| `mpm --report` | Saved report with recent warnings |
| `mpm --live` | Live overview, refreshes every 4 s |
| `mpm --stop` | Stop a work mode running in another terminal |
| `mpm --check-config` | Check your settings (exits 1 if there are errors) |

**A simple routine:** start `mpm --work` in a terminal tab in the morning and forget it. When the
Mac feels slow, press **f** in that tab (or run `mpm --free`): you get a ranked list such as
"Cursor ~6.3 GB, quit app", "tsserver ~1.5 GB, stop process: Cursor restarts it when needed",
"Slack ~1.1 GB, idle". Pick a number, review, confirm; it measures again and shows what you
actually gained.

Settings are optional: copy `config.env.example` to `config.env` next to the script and edit it.
Every setting is documented in [`config.env.example`](config.env.example).

## FAQ

**Will it make my Mac faster?** It frees memory the only way that really works: by closing
what you don't need. `mpm --free` ranks what would free the most, tells you what each step
costs, does the steps you approve (stop a dev process, quit an app), then measures the result.
It never closes anything on its own guess, because only you know which tab or window you still
need. "RAM cleaner" tricks such as `sudo purge` only empty caches that macOS refills within
minutes, so the tool doesn't do them.

**Does it need sudo or send data anywhere?** No. It only reads what macOS shows to your user
account, and everything stays in local files with private permissions. Command lines and
paths of other processes are never written to disk.

**Which Macs does it support?** It is developed and tested on Apple Silicon with macOS 27 and
the `/bin/bash` 3.2 that ships with macOS. It adapts its advice to the RAM it detects. Intel
Macs and older macOS versions should work but have not been tested yet; reports are welcome.

**Is it safe to leave `--work` running all day?** Yes. It costs about 0.85 s of CPU per 100 s and
a few MB of memory, runs only in its own terminal tab, and stops completely when you press `q`.

**I use VS Code, not Cursor.** The memory, swap, dev-server and language-server parts work the
same; the Cursor-specific diagnostics simply find nothing.

## Documentation

- [User guide](docs/GUIDE.md): every mode and menu item, how memory is judged, the safety
  model, work mode, configuration, files and privacy, troubleshooting, limitations
- [Development](docs/DEVELOPMENT.md): project layout and the test suite
- [Changelog](CHANGELOG.md)

## Contributing

Bug reports with your Mac model, RAM, macOS version and `mpm --once` output are the most
useful contribution, especially from Intel Macs and older macOS versions. See
[CONTRIBUTING.md](CONTRIBUTING.md). Security issues: see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
