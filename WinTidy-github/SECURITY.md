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

## Scope

Examples of what is in scope:

- Privilege escalation, for example through the data folder, backups that **Restore** applies, or the paths WinTidy loads modules and tools from
- Deletion outside the intended locations (junctions, symlinks, path traversal)
- Restore writing to registry keys outside the allow-list

Out of scope: findings that require an attacker who already has administrator rights on the PC.
