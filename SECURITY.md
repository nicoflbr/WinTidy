# Security policy

WinTidy runs with administrator rights and changes system settings, so security reports are taken seriously.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately via **Security → Report a vulnerability** on this repository (GitHub private vulnerability reporting).

Helpful details:

- WinTidy version (shown in the app sidebar, or `$Script:Version` in `WinTidy.ps1`)
- Windows version and whether the account is an administrator
- Steps to reproduce and the impact you see

You can expect a first reply within a few days. Once a fix is released, you will be credited unless you prefer otherwise.

## Updates and trust

WinTidy can update itself (opt-in, off by default). It only installs published releases of the configured GitHub repository, over HTTPS from GitHub hosts. The download must match the SHA-256 checksum of the release, and the package is checked (allowed file names and types, no path traversal, size limits, PowerShell syntax, version) before anything is replaced. The files are staged in the admin-only data folder, a copy of the old files is kept and failed installations are rolled back.

What this does **not** protect against: releases are **not code-signed**, and the checksum comes from the same GitHub release as the ZIP. Whoever controls the GitHub account or the release can ship code that runs with administrator rights. If that is not acceptable for your environment, leave updates off or set `"UpdateEnabled": false` in the configuration, and install versions yourself after reviewing them.

## Scope

Examples of what is in scope:

- Privilege escalation, for example through the data folder, backups that **Restore** applies, or the paths WinTidy loads modules and tools from
- Deletion outside the intended locations (junctions, symlinks, path traversal)
- Restore writing to registry keys outside the allow-list
- The updater installing something that does not come from an official release, skipping the checksum or package checks, writing outside the program folder, or leaving a half-installed state

Out of scope: findings that require an attacker who already has administrator rights on the PC.
