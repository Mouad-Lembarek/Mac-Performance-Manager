# Contributing

Thanks for helping. The most useful contributions, in order:

1. **Reports from other Macs.** Intel Macs, older macOS versions, 16-128 GB machines and
   desktops (Mac mini, Mac Studio) have not been tested yet. Open an issue with your Mac
   model, RAM, macOS version and the output of `mpm --once`, even if everything works.
2. **Bug reports**, using the issue template.
3. **Pull requests** for bugs, new app groupings (for example VS Code, Zed, LM Studio) or
   clearer advice.

## Ground rules

These keep the tool trustworthy. A pull request that breaks one of them will not be merged.

- **Nothing happens without the user's confirmation.** No new automatic kills, quits or
  deletions. Anything that changes the system must show what it will do and require a typed
  confirmation, and must re-check its target right before acting.
- **Never delete permanently.** Use the Trash.
- **No sudo, no network access, no telemetry, no background daemon.**
- **No dependencies.** macOS built-in tools only (`vm_stat`, `sysctl`, `ps`, `top`, `df`,
  `pmset`, `lsof`, `awk`, ...). No Homebrew, Python or npm.
- **Bash 3.2 and BSD tools.** The script must run on the `/bin/bash` that ships with macOS:
  no associative arrays, `mapfile`, `${var,,}`, `sed -i`, `grep -P`, `readlink -f` and so on.
  The test suite checks for the common ones.
- **Measure, don't guess.** Recommendations come from measured data and say so when a value
  is approximate.

## Running the tests

```bash
./tests/run_tests.sh
```

The suite takes about 5 minutes. It never touches your real processes, files, Trash or
settings: macOS tools are replaced by stubs that print recorded output, everything runs in a
temporary folder that is also `HOME`, and process tests use throw-away processes the suite
starts itself. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#tests) for details.

Every fix needs a test that fails without it. Run the full suite before opening a pull request
and paste the final `Passed: ... Failed: 0` line in the description.

## Pull requests

- Keep changes small and focused; match the surrounding code style and comment density.
- Update `docs/GUIDE.md` and `config.env.example` when behaviour or settings change, and add a
  line to `CHANGELOG.md` under an "Unreleased" heading.
- Describe how you tested it, including on which Mac and macOS version.
