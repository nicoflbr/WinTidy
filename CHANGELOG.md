# Changelog

## 1.6.0 – 2026-10-25
**New page: Debloat**
- New page **Debloat** in the app (own check, own "Apply selected" button). It removes what Windows and PC makers put in your way: ads and suggestions, tracking, unneeded buttons and preinstalled apps. The selection was compiled with the help of [Win11Debloat](https://github.com/raphire/win11debloat) (MIT, see `THIRD-PARTY-NOTICES.md`) - but WinTidy only takes over what fits its principles: per-user settings from Windows Settings and Explorer options, removable Store apps. No policies for the whole PC, no services, no security features, no telemetry policies, no scripts from the internet.
- Four rules for **settings** (`DBL-ADS`, `DBL-PRIVACY`, `DBL-SHELL`, `DBL-COMFORT`), 24 settings in total. Only ads and suggestions are preselected; the rest is a matter of taste. Every change is written through `Set-RegValueWithUndo`, so it shows up under History and can be undone one by one. Settings that do not exist on the installed Windows build (e.g. Copilot button, Chat icon, "End task" in the taskbar) are not offered.
- Three rules for **apps**: advertising apps from third parties (`DBL-APPS-PROMO`), Microsoft apps (`DBL-APPS-MS`) and apps of PC makers (`DBL-APPS-OEM`, expert level, each app individually). A catalog of 112 known apps; only installed ones are shown, nothing is preselected, a note says that everything can be reinstalled from the Store. Apps are removed for the current user and from the Windows image. Windows components, the Store, Defender, App Installer and similar apps are on a never-remove list that is checked again when removing.
- Not offered on managed PCs, on Windows Server and when WinTidy runs under a different account than the one that is signed in (the settings would end up in the wrong profile).
- New optional rule fields `Seite` (page of the app) and `Vorwahl` (preselection of Low-risk rules). `Get-AllFindings` has a new parameter `-Page`; the normal check does not include the Debloat rules, and the findings of both pages stay available for `Invoke-FixSelection`. New `Invoke-GuiDebloatScan`. Command line: `-Rule DBL-ADS,...` works as for every other rule.
- New `tests/Test-Debloat.ps1` (catalog, allow-list, detection per Windows build, fix, app removal and refusal of dangerous names, page handling, contexts), also run by CI and the release workflow.
- Not taken over from Win11Debloat on purpose: removing Edge, OneDrive or Defender, disabling services, telemetry and Windows Update policies, Start menu layout files, changes for all users or the default profile, and running as a script from the internet.

## 1.5.0 – 2026-10-25
**Automatic updates (opt-in)**
- New setting **Update WinTidy automatically** (Settings, off by default). When it is on, the app checks GitHub for a new release at most once a day (`UpdateIntervalHours`), downloads it, verifies it and installs it. A banner offers **Restart now**; the new version is used after the next start. A button **Check for updates now** does the same on request and asks before installing.
- New command line mode `-Mode Update` (also **[U]** in the menu): shows the release notes, asks for confirmation (`-Yes` skips it) and installs.
- New configuration keys `UpdateEnabled` (`false` switches updates off completely, e.g. on managed PCs), `UpdateRepo` (default `nicoflbr/WinTidy`) and `UpdateIntervalHours` (default 24).
- Only official, published releases of the configured repository are installed (no pre-releases, no drafts), and only via HTTPS from GitHub hosts. The ZIP must match the SHA-256 checksum of the release (GitHub's digest of the asset and/or the new `WinTidy-vX.Y.Z.zip.sha256` file; at least one is required and they must agree). The package is checked before anything is touched: allowed file names and types only (no path tricks), size limits, PowerShell syntax of every script, and its version must equal the release tag and be newer than the installed one.
- Updating needs administrator rights and the protected data folder: the download is staged there, so that other programs cannot swap it between check and installation. It is blocked for git clones (use `git pull`), network drives, folders WinTidy cannot write to, and `-DataPath`.
- A copy of the replaced files is kept in the data folder (`update\backup\<version>`). Files are replaced one by one with a journal; if a step fails, or the PC loses power half way, the old files are put back (also at the next check). `WinTidy.config.json` is never overwritten if it exists, `WinTidy.config.local.json` is never touched, unchanged files are skipped.
- Release workflow: every release now also contains `WinTidy-vX.Y.Z.zip.sha256`.
- New `tests/Test-Update.ps1` (offline, with built ZIP packages): version parsing, allowed paths, blockers, checksum cases, zip-slip, forbidden files, syntax and version checks, tampering, rollback, journal repair. Runs in the CI on Windows PowerShell 5.1 and PowerShell 7.
- Note: WinTidy releases are not code-signed. The update is as trustworthy as the GitHub account and release it comes from (see `SECURITY.md`). Version 1.4.1 and older have no updater: install 1.5.0 manually once.

## 1.4.1 – 2026-10-25
- App: the number badge next to "Recommendations" was cut off in English. The sidebar is a bit wider and the badge is anchored on the right, so it is always fully visible.

## 1.4.0 – 2026-10-25
**English and German**
- WinTidy now speaks English and German: app, command line, HTML report and all messages. By default it follows Windows (German Windows → German, otherwise English).
- App: new setting **Language** (Same as Windows / Deutsch / English); WinTidy offers to restart so that the change takes effect. Saved together with the appearance in `%APPDATA%\WinTidy\app-einstellungen.json`.
- Command line: new parameter `-Language auto|en|de`. Prompts accept `y`/`yes` as well as `j`/`ja`.
- The texts are in English in the code; the German translation is in `lang\de.psd1`. `Test-Parse.ps1` checks that every text has a translation, that there are no unused or duplicate entries and that placeholders match.
- Internal values (rule categories, risk levels, status codes, snapshot fields, file names in the data folder) are unchanged, so existing data, history and undo keep working in both languages.

**Configuration**
- New optional `WinTidy.config.local.json` for personal settings of this PC. It is loaded after `WinTidy.config.json`, is not part of the repository and is never overwritten by an update – so a git clone or a new ZIP can be used directly as the installation.
- `WinTidy.config.beispiel.json` is now called `WinTidy.config.example.json`.

**Documentation**
- All documentation, code comments and tests are in English. `ANLEITUNG.md` is now `USAGE.md`, `ENTWICKLUNG.md` is now `DEVELOPMENT.md` (with a new section on languages). This changelog was translated.

## 1.3.4 – 2026-10-23
- Fix: the chosen appearance (light/dark/same as Windows) was never saved. Because of a typo, the file name contained an invisible control character (`\a`); Windows rejected the path. `Test-Parse.ps1` now reports control characters.
- Dark mode: the selected menu item in the sidebar was dark blue on dark blue. Own text color `NavSelFg` (light in dark mode).
- Hardware hints show a light bulb instead of a symbol that looked like an empty checkbox (nothing can be selected there).
- Version number of the engine on the level of the app (still showed 1.3.2).
- Prepared publication on GitHub: English `README.md`, user documentation now in `ANLEITUNG.md`, MIT license, `CONTRIBUTING.md`, `SECURITY.md`, templates for issues and pull requests, automatic tests (Windows PowerShell 5.1 and PowerShell 7) and a release workflow that publishes a ready ZIP for a tag `vX.Y.Z`.

## 1.3.3 – 2026-10-23
- Fix: the app did not start ("Unable to cast object of type PSObject to type Brush"). In PowerShell `New-Object` returns a wrapper object; stored as a resource, WPF cannot use it as a brush. Now the actual object (`.psobject.BaseObject`) is stored.

## 1.3.2 – 2026-10-23
- Fix dark mode: cards, sidebar and texts stayed light because WPF freezes brushes used by styles. Colors are now replaced as resources; elements created in code refer to the key via `Set-Brush` (SetResourceReference).
- Own checkboxes matching the design (incl. "partially selected"), radio buttons for the appearance, narrow scroll bars and tooltips – light and dark.

## 1.3.1 – 2026-10-23
- **App: dark mode.** Settings › Appearance: "Same as Windows" (default, follows Personalization › Colors even while the window is open), "Light" or "Dark". The title bar becomes dark too. The choice is saved per user in `%APPDATA%\WinTidy\app-einstellungen.json`. With an active Windows contrast theme its colors still apply.
- Colors in dark mode checked for readability (text ≥ 4.5:1, borders ≥ 3:1); own link color (`Link`) instead of the accent color.

## 1.3.0 – 2026-10-23
Result of four independent reviews (code, security, usability, domain logic).

**Security and privacy**
- Data folder protected under `%ProgramData%\WinTidy\<PC>` (only admins/SYSTEM can write), without admin rights under `%LOCALAPPDATA%`; old data is taken over. Before, programs without admin rights could manipulate backups that "Restore" applied with admin rights.
- Deleting no longer follows links (junctions/symlinks/OneDrive placeholders); protection list for drive root, Windows, profiles, programs. Age = modification **and** creation date.
- `C:\Temp` is no longer hard-coded (only via `ExtraTempPaths`).
- `CLN-WINOLD`: warns about personal files in `Windows.old\Users` and then preselects nothing; preselection only with a known age ≥ 10 days; the files for "Reset this PC" stay.
- Server/company PC lock in the command line too; detection fails closed and additionally covers Entra join and ConfigMgr.
- Restore: single-value undo (before/after) instead of `reg import` of whole keys, does not overwrite values changed since, only allow-listed paths; tasks are switched on again instead of re-registered from XML; unique run IDs.
- Configuration is validated (minimum ages, no system components in `BloatApps`, shadow copy target ≥ 3 %); tables are merged per sub-key.
- With admin rights: `PSModulePath` only system folders, `winget` only from the App Installer package, uninstall commands only from HKLM; reports are opened via Explorer (no browser with admin rights); HTML values consistently escaped.
- `cleanmgr`: leftover category flags are removed first; `SystemRestorePointCreationFrequency` is restored instead of deleted.
- Network paths (NAS/VPN) never count as "orphaned"; `\??\` service paths are checked correctly.
- Cooling test with a watchdog in the C# part, stop on overheating/heat throttling/power adapter unplugged, timeouts for all measurements, blocked on servers and in VMs.
- Preselection in the app: only permanent changes that are really safe. No longer preselected: recycle bins of old accounts, old drivers, Store apps, program updates, ghost devices; autostarts only from `HeavyStartup`. `ProtectedStartup` extended considerably (antivirus, VPN, backup, cloud, input devices), matching also via vendor/description of the file.

**Domain logic / false alarms**
- Drive state "Unknown" is no longer an alarm; Warning = warn, Unhealthy/Predictive Failure = crit. SMART prediction is now really assigned (operator precedence bug before).
- CPU temperature relative to the temperature limit of the CPU family (`CpuTjMax`); scan temperature as a median and only rated at idle; Tdie before Tctl.
- Event 37 counted as episodes, warning only on desktops with ≥ 3 in 7 days, otherwise a hint.
- NVIDIA: fan value interpreted as a target value, 0x20 (regulates at the temperature limit) is normal, throttle reasons only in 2 of 3 samples, limits of the card from `nvidia-smi -q`, idle/load distinction, PCIe link.
- Fans: fan stop at idle is not a defect, pumps at 100 % are normal, pump at 0 RPM only a warning, full speed only with a matching running fan. Fan reaction in the test per fan (without GPU/pump).
- Cooling test: EcoQoS switched off for the measurement, normal thread priority, firmware power limit evaluated, cancelled tests are not saved.
- `HW-COOLPOLICY` only with ACPI active cooling, no automatic preselection any more; `/setactive` only for the plan that is still active.
- `SYS-TRIM` only on a real problem (TRIM switched off or not run for > 14 days) instead of a permanent finding; `SYS-MAINT` detects switched-off drive optimization.
- `CLN-WINSXS` analysis at most every 7 days, not with a pending restart. `CLN-DRIVERSTORE` offers no packages that any (also unplugged) device uses. `SEC-CHECKS` considers third-party antivirus/firewall and legacy BIOS.
- Laptop detection via `PCSystemType`/chassis (a UPS does not count as a battery), battery operation via `BatteryStatus.PowerOnline`.
- Health score: snapshots in time don't count, free space with an absolute lower limit, error count max. −5, new: Windows without support −20, updates > 40 days −10, Windows Update off −15.

**New checks**
- Hardware: only one RAM module, monitor on the motherboard, graphics card with too narrow a link, missing graphics driver, devices with an error code, power plan limits processor/turbo off/minimum 100 %, Intel 13th/14th gen with microcode < 0x12F, LAN only 100 Mbit/s, several fan tools, tuning programs, memory diagnostic errors, WHEA 19/17, long uptime despite Fast Startup.
- Security: Windows without support/soon without support, no updates for > 40 days, Windows Update switched off, Secure Boot certificates 2023.
- `SYS-TWEAKS`: pagefile off, Prefetch off, SysMain off, Defender off by policy.
- `CLN-HIBERFIL`: shrink the hibernation file on desktops (reversible).

**App**
- Progress shows the area being checked instead of action words ("delete"); no "step x of y" for measurements and the cooling test.
- Plain-language texts for almost all findings (no registry paths/package names), display names for Store apps and device classes, toned-down hints on Secure Boot/BIOS/firewall.
- Red banner on imminent data loss (drive/RAM); own symbol and "Important:" for critical points; traffic light kept after an app restart; hardware card with headings, legend and "What to do?".
- Cooling test: battery/server/VM caught in advance, honest result if nothing was measurable, laptop hint.
- No more silent "nothing happens" during background work; check button only active after loading; history loads afterwards.
- Restore point prompt with "No" as default; "Nothing applied" instead of "Done!" with 0 changes; skipped items separated from errors (e.g. "driver is still in use", "uninstall cancelled").
- History shows "undone on …"; undo preview with understandable names.
- Group "Maintain Windows", improved contrast, screen reader names for the navigation, Esc cancels, new help questions.

**Follow-up review (fifth, independent agent)**
- Data folder: the content is checked too (owner, write permissions, no links) and reset if needed; if it is not safe, WinTidy blocks "Restore".
- Restore normalizes file paths (no `..`), registry paths with `..` are rejected; deleting checks the path chain for links immediately before.
- `SYS-GAMEDVR` only checks and switches background recording (`HistoricalCaptureEnabled`) – before, a false alarm on almost every PC.
- `CLN-HIBERFIL`: no preselection if hybrid sleep or hibernation via button is used; hint in the text.
- Red drive banner not for merely warm drives; area/rating in the snapshot, so that it is also right after an app restart.
- Small things: data takeover with `[ ]` in the path, LibreHardwareMonitor sensor "Distance to TjMax" ignored, script policy undo only after success, app autostarts fail closed, TRIM message only with an SSD, VM false alarms, Windows 10 Enterprise end of support, `-Rule A,B` via WinTidy.cmd, technical text in expert mode.

**Tests**
- `Test-Parse.ps1` additionally checks UTF-8 BOM, PS7 operators and typographic quotes. `Test-Hardware.ps1` and `Test-GuiApi.ps1` extended considerably (fan stop, pump, GPU reasons, drive states, TjMax, number formats, safety stop, cancel, SKIP, RP-FEHLT with System Protection, single-value undo, allow list, run IDs).

## 1.2.0 – 2026-10-23
**Hardware & cooling**
- New rule `HW-COOLING`: processor, graphics card and drive temperatures, fan speeds (stopped CPU fan → critical, full speed with a cool processor → fan curve too aggressive), throttling by firmware (event 37) and heat (ACPI thermal zones), NVIDIA throttle reasons via `nvidia-smi`, SSD wear, SMART warning, drive state, battery wear. Every point with level ok/warn/crit.
- Sensors from LibreHardwareMonitor/OpenHardwareMonitor (WMI) or HWiNFO (gadget registry) are read automatically if one of them is running.
- **Cooling test** (app: "Test cooling", CLI: `-Mode Hardware -CoolingTest [-Seconds n]`, menu [9]): full load on all cores with low priority, rates performance drop (only a problem together with heat/throttling), maximum temperature and fan reaction; measurement series under `kuehltest\`. Can be cancelled, not on battery.
- New rule `HW-COOLPOLICY` (Medium): cooling policy on AC from "passive" to "active" (only with ACPI thermal zones); undo via Restore.
- New rule `HW-DISPLAY`: refresh rate below what the monitor can do according to EDID.
- Snapshot: new sections `Hardware` and `Stabilitaet`; report: section "Hardware & cooling" incl. the last cooling test; comparison: warning signs and hardware irregularities.
- Score: critical hardware findings −5 (max. −10), irregularities −1 (max. −3).

**Engine**
- `CLN-WINOLD` (new, Medium, permanent): previous Windows version separated from `CLN-WINCLEAN`, preselected only after `WinOldMinAgeDays` (10) days. `CLN-WINCLEAN` no longer touches Windows.old.
- Fix: the "before" score was too high because warning signs only came from the findings – now every snapshot measures them itself (`Stabilitaet.Warnsignale`).
- Defender deduction only if no other antivirus is active (`Sicherheit.AndererVirenschutz`).
- Ghost devices: "Microsoft VHD Loopback Controller" and other virtual Microsoft devices excluded.
- `Get-WtContext`: server, company PC (domain/Intune), other account, restart pending, battery. Company PCs only see safe cleanup points; on servers changes are blocked.
- `Invoke-FixSelection`: restore point **before** any change (on failure status `RP-FEHLT`, nothing changed), cancel between steps, details per step, long steps skipped on battery, reports switched-on System Protection.
- `Invoke-Restore` returns a result (restored/errors/details), new `Get-RestorePreview`, `Get-HistoryLight`; runs know the number of reversible changes.
- Rules can specify `Dauer`, `Endgueltig`, `Einzeln`, `Umkehrbar` (for the app).
- Configuration: `WinTidy.config.json` only contains own deviations; all defaults in `WinTidy.config.beispiel.json`. Before, the shipped full copy hid new defaults.

**App**
- Hardware card with a traffic light per measurement point and a "Test cooling" button.
- Notice banners (without admin rights, server, company PC, other account, restart pending, battery), cancel button, error page instead of a crash, help page with FAQ, high contrast, "Why not 100?" for the score, result with details per step, prompt on a missing restore point, only one app instance at a time.

**Tests**
- New `tests/Test-Hardware.ps1`: rating of sensors, GPU, drives, battery, score and cooling test with synthetic values (platform independent). `Test-Report.ps1` checks the hardware section in the report. New `tests/Test-GuiApi.ps1`: interface to the app (restore point errors, cancel, battery, server/company PC, restore preview).

## 1.1.1 – 2026-10-21
- Ghost devices: virtual system adapters (WAN Miniport, Hyper-V, Bluetooth etc.) and software devices (`SWD\`, `ROOT\`) are no longer offered (new: `GhostDeviceExclude`)
- WinSxS: no new suggestion if the cleanup ran in the last 14 days (DISM otherwise permanently reports "recommended"); no misleading space estimate any more
- Fix: "Illegal characters in path" with unusual autostart command lines

## 1.1.0 – 2026-10-21
- **New: WinTidy App** (`WinTidy-App.ps1`, start via `WinTidy App.cmd`): graphical interface for non-IT users with overview (health score, key figures, hints), recommendations with traffic light and preselection, progress display with log, result with measured before/after, history with boot time chart, settings (undo, desktop shortcut, expert mode, thorough check)
- Engine loadable as a library, GUI API (`Invoke-GuiScan`, `Invoke-FixSelection`, `Get-HistoryData`, `Invoke-GuiRestore`), understandable texts for all rules
- Fix: `-RunId` for Restore was overwritten by the run ID
- Fix: the restore point no longer resets the shadow copy limit
- Fix: `TSK-ANTIPATTERN` ignores comments (no more false alarms on explanatory notes)
- `CLN-WINCLEAN` additionally empties the Delivery Optimization cache and old LiveKernelReports
- `SYS-MAINT` only reports real maintenance gaps (> 14 days)
- `HW-HINTS`: detects larger, barely used SSDs also behind RAID drivers and active RAID drivers without an array

## 1.0.0 – 2026-10-21
First version, created from an assessment and two optimization rounds on the first test PC.

- Modes: Menu, Scan, Preview, Apply, Compare, Report, Restore, Rules
- 28 rules in 9 areas (storage, startup, tasks, services, programs, system, security, hardware, stability)
- Snapshots as JSON, action log as JSONL, registry and task backups per run
- Health score with traceable deductions
- HTML report: score, boot time history with apply markers, before/after, findings, boot slowdowns, autostart, drives, cleanup balance, action log, snapshot history
- Risk levels Low/Medium/High/Info with `-Yes` / `-IncludeMedium`
- Restore point before every Apply (the 24-hour lock is lifted briefly)
- Tests: syntax/rule IDs, report from test data (platform independent)
