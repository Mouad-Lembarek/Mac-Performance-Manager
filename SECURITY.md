# Security policy

Mac Performance Manager can stop processes and move folders to the Trash, always after a typed
confirmation. A bug that lets it act on the wrong process or path, act without confirmation,
execute content from a configuration file, or leak command lines, paths or secrets to disk is
a security issue.

## Reporting a vulnerability

Please report it privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue for it.

Include the version (`mpm --version`), your macOS version and Mac model, and the steps to
reproduce. You should get a first answer within a week.

## Supported versions

Only the latest release receives fixes.
