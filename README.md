# WinTidy

**Evidence-based cleanup and tuning for Windows 10 and 11.** WinTidy measures your PC first, explains every suggestion in plain language, asks before it changes anything, and then shows you the before/after result.

- No installer, no dependencies. It runs on the built-in Windows PowerShell 5.1.
- Generic rules only. There are no hard-coded paths, user names or programs, so it works on any PC.
- Everything is logged and backed up. Settings can be rolled back individually.
- Includes a friendly desktop app for non-technical users and a scriptable command line for IT pros.
- **English and German.** It follows the Windows display language; you can switch in the app settings or with `-Language en|de`.
- **Optional automatic updates** (off by default): official GitHub releases only, verified by checksum, with backup and automatic rollback.

> Full user guide: [USAGE.md](USAGE.md). Developer guide: [DEVELOPMENT.md](DEVELOPMENT.md).

## Quick start

1. Download the latest release (or **Code → Download ZIP**) and extract it anywhere, for example to a USB stick.
2. Windows marks downloaded files as "from the internet". To avoid security prompts, right-click the ZIP → **Properties** → tick **Unblock** *before* extracting. Alternatively, run this in PowerShell inside the extracted folder:
   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```
3. Double-click **`WinTidy App.cmd`** and confirm the Windows admin prompt.
4. Click **Check now**. This only measures; nothing is changed.

## What it does

| Area | Examples |
|---|---|
| **Storage** | Temp files by age, Windows Disk Cleanup handlers, `Windows.old` (only after 10 days), WinSxS cleanup, crash dumps, old recycle-bin items, unused driver packages, hibernation file size on desktops, large browser caches (Edge, Chrome, Brave, Vivaldi, Opera, Firefox - cache folders only, never cookies or sign-ins), an overview of large and old files in your personal folders (shown only, never deleted) |
| **Startup** | Broken autostart entries, orphaned startup state, active autostarts ranked by their *measured* boot delay (Event 100/101) |
| **Tasks & services** | Scheduled tasks and services pointing to missing files, harmful patterns in home-made "maintenance" scripts |
| **Apps** | Side-by-side duplicate versions, preinstalled Store bloatware, outdated programs (via winget) |
| **Debloat** (own page) | Ads and suggestions in Windows, tracking and personalisation, taskbar and Start clutter, advertising / Microsoft / PC-maker Store apps - per user, undoable settings, nothing machine-wide |
| **System** | Ghost devices, restore-point storage, SSD TRIM, stuck maintenance, DISM/SFC health, Game Bar background recording |
| **Hardware & cooling** | CPU/GPU temperatures, fan behavior, thermal/firmware throttling, drive health and wear (SMART), WHEA and memory errors, battery wear, refresh rate, single-channel RAM, XMP/EXPO, monitor plugged into the motherboard, PCIe link width, power plan limits, Intel 13th/14th gen microcode |
| **Security & stability** | Windows support status and update age, Secure Boot, antivirus and firewall (including third-party), UAC, BIOS age, risky "tweaks" (pagefile off, SysMain off, Defender disabled by policy), event log warnings |

A built-in **cooling test** loads the CPU for about a minute. It checks whether performance drops because of heat, whether the CPU reaches its TjMax, and whether the fans react. It stops on its own on overheating, heavy throttling, or when a laptop is unplugged.

### What WinTidy deliberately does *not* do

- No registry "cleaners" and no tweaks without measurable benefit. The optional **Debloat** page is the one exception: it only changes settings that Windows itself offers (per user, undoable), and only ads and suggestions are ticked.
- It never turns off Defender, Windows Update, UAC or the firewall.
- It never changes fan curves or BIOS settings. Windows has no safe, vendor-neutral way to do this, so WinTidy only measures the effect.
- It never force-removes drivers, and it never deletes anything in Documents, Pictures, Downloads or the Desktop (the large-file overview only reads).
- Nothing on a currently disconnected drive is treated as "orphaned".

## Safety model

- **Risk levels.** Every rule is rated *Low*, *Medium*, *High* or *Info*. The app preselects only safe items. On the command line, `-Yes` applies *Low* only, and `-IncludeMedium` adds *Medium*. *High* always asks for each item.
- **Restore point** before changes. If System Protection is off on the system drive, WinTidy turns it on and tells you so.
- **Per-value undo.** Every registry value, service start type, scheduled task and power setting is recorded before it changes. **Restore** puts back exactly those values and skips any value that someone else has changed since.
- **Safe deletion.** Deletion never follows junctions, symlinks or OneDrive placeholders. System roots are protected, and file age uses both the modified *and* created time.
- **Protected data folder.** Runtime data lives in `%ProgramData%\WinTidy\<PC>` with an admin-only ACL, so unprivileged programs cannot tamper with the backups that Restore applies with admin rights.
- **Updates are opt-in and verified.** If you switch them on, WinTidy installs only official releases of its GitHub repository, over HTTPS, after a SHA-256 and package check, keeps a copy of the old files and rolls back on errors. Releases are not code-signed (see [SECURITY.md](SECURITY.md)).
- **Context-aware.** On Windows Server, WinTidy only checks and never changes anything. On domain-, Entra-, Intune- or ConfigMgr-managed devices, it offers only safe cleanup and information.

## Command line

```powershell
.\WinTidy.ps1 -Mode Scan -OpenReport          # measure + HTML report, changes nothing
.\WinTidy.ps1 -Mode Preview                   # show what Apply would do
.\WinTidy.ps1 -Mode Apply                     # interactive, asks per rule/item
.\WinTidy.ps1 -Mode Apply -Yes                # unattended: low-risk rules only
.\WinTidy.ps1 -Mode Apply -Rule STA-HEAVY,APP-BLOAT
.\WinTidy.ps1 -Mode Restore -RunId 20261021-183100
.\WinTidy.ps1 -Mode Hardware -CoolingTest     # cooling test under load
.\WinTidy.ps1 -Mode Rules                     # list all rules with risk level
.\WinTidy.ps1 -Mode Update                    # check for a new version and install it
.\WinTidy.ps1 -Mode Scan -Language de         # German output and report
.\WinTidy.ps1 -Mode Rules -SavePreset mine.json   # save the rule selection as a profile
.\WinTidy.ps1 -Mode Apply -Preset mine.json       # use a profile (or the built-in Safe / Standard)
.\WinTidy.ps1 -Mode Report -Share -Pdf         # report without PC name, user name and paths (+ PDF)
```

`WinTidy.cmd` asks for admin rights and passes any parameters through.

Each run writes a console transcript, a JSON-lines action log, before/after snapshots and an HTML report with a "Did WinTidy help?" verdict, a trend for eight performance key figures and a boot-time history. To adapt WinTidy to a device, put only the keys you want to change into `WinTidy.config.local.json` (personal, git-ignored, never overwritten by an update). All keys and their defaults are listed in `WinTidy.config.example.json`.

## Requirements

- Windows 10 (2004 or later) or Windows 11
- Windows PowerShell 5.1 (built in)
- Admin rights for applying changes and for a complete scan

Optional: [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) (0.9.5 or later) or HWiNFO running in the background provides CPU temperature and all fan speeds. NVIDIA GPUs are read via `nvidia-smi`.

## Development

The engine and CLI are in `WinTidy.ps1`. The WPF app is in `WinTidy-App.ps1`; it loads the engine into a background runspace. Texts are written in English in the code and translated via `lang/de.psd1`. The tests use mocked Windows functions, so they also run on Linux/macOS with PowerShell 7:

```powershell
pwsh ./tests/Test-Parse.ps1
pwsh ./tests/Test-Report.ps1
pwsh ./tests/Test-Hardware.ps1
pwsh ./tests/Test-GuiApi.ps1
pwsh ./tests/Test-Update.ps1
pwsh ./tests/Test-Debloat.ps1
pwsh ./tests/Test-Storage.ps1
pwsh ./tests/Test-Perf.ps1
pwsh ./tests/Test-Features.ps1
```

GitHub Actions runs them on Windows PowerShell 5.1 and PowerShell 7 for every push and pull request. Before contributing, read [CONTRIBUTING.md](CONTRIBUTING.md) and the rule contract in [DEVELOPMENT.md](DEVELOPMENT.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Disclaimer

WinTidy changes system settings and deletes files. It creates a restore point and backups first, but use it at your own risk. See the [license](LICENSE) for details.

## License

[MIT](LICENSE). The selection on the Debloat page was compiled with the help of [Win11Debloat](https://github.com/raphire/win11debloat) (MIT), see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
