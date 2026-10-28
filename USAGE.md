# WinTidy – User guide

Evidence-based cleanup and tuning for Windows 10/11 – measured before, asks before changing, proven result afterwards.

WinTidy is a single PowerShell script without installation and without dependencies. It runs on the built-in Windows PowerShell 5.1 and works on any PC, because it only uses generic rules and knows no fixed paths or programs.

## Download

Download the latest version under **Releases** (or **Code → Download ZIP**). Windows marks downloaded files as "from the internet". To avoid security prompts at startup, before extracting: right-click the ZIP file → **Properties** → tick **Unblock**. Alternatively, in PowerShell inside the extracted folder: `Get-ChildItem -Recurse | Unblock-File`.

## Language

WinTidy speaks English and German. By default it follows Windows: on a German Windows it is German, otherwise English.

- **App:** Settings → **Language** (Same as Windows / Deutsch / English). WinTidy offers to restart so that the change takes effect.
- **Command line:** `-Language de` or `-Language en` (default `auto`).

The HTML report is written in the language of the run that creates it. Internal data (snapshots, logs) stays the same in both languages, so you can switch at any time.

## The app (for everyone)

Double-click `WinTidy App.cmd` → confirm the Windows prompt with **Yes** → the window opens.

1. **Overview → "Check now"**: measures the PC, shows a health score (0–100) and the most important key figures. Nothing is changed.
2. **Recommendations**: every improvement in plain words, with a traffic light ("Safe", "Check briefly", "Experts only"). The safe points are already ticked. Under "Details" you can deselect individual entries.
3. **"Apply selected"**: creates a restore point, applies the changes and then shows before/after.
4. **Hardware** (Overview, "For experts"): cooling, fans, temperatures of processor, graphics card and drives, throttling, battery wear and refresh rate. With **"Test cooling"** WinTidy puts the processor under load for about a minute and checks whether the cooling keeps up.
5. **Debloat**: removes what Windows and PC makers put in your way - ads and suggestions, tracking and personalisation, unneeded taskbar buttons, preinstalled apps. It has its own check and its own "Apply selected" button. Only ads and suggestions are ticked, the rest is up to you. Settings can be undone under History; removed apps can be reinstalled from the Store. Not offered on managed PCs and Windows Server.
6. **History**: trend of eight key figures (start time, waiting time after the desktop appears, startup programs, background processes, memory, processor and drive load at idle, free space) plus the boot time chart across all restarts, all checks and optimizations. The home page and the report answer "Did WinTidy help?" at a glance. Start times are only judged from restarts after the optimization (at least 2), so they show "not measurable yet" at first.
7. **Settings**: appearance (same as Windows, light or dark), language, **updates**, undo, create desktop shortcut, thorough check, expert mode.

The app uses the same logic and the same data as the command line – you can use both alternately.

## Command line (for IT pros)

1. Copy the `WinTidy` folder anywhere (a USB stick works too).
2. Double-click `WinTidy.cmd` → confirm admin rights → menu.
3. **[1] Scan** → measures, checks all rules, opens the HTML report. Changes nothing.
4. **[3] Apply** → restore point, then every rule with a confirmation prompt.
5. Restart the PC normally 2–3 times, then **[1] Scan** again → the report shows "Did WinTidy help?" with the key figures, before/after including the boot time history.

## Modes

| Mode | What happens | Changes something? |
|---|---|---|
| `Scan` | snapshot + check all rules + report | no |
| `Preview` | shows what `Apply` would do | no |
| `Apply` | snapshot before → restore point → rules with prompts → snapshot after → comparison → report | yes |
| `Compare` | compares two snapshots in the console | no |
| `Report` | rebuilds the HTML report from all stored data | no |
| `Restore` | restores backed-up registry values, tasks and service start types of a run | yes |
| `Rules` | lists all rules with their risk | no |
| `Hardware` | cooling, fans, temperatures, drives, battery; with `-CoolingTest [-Seconds 90]` additionally a cooling test under load | no |
| `Update` | checks GitHub for a newer release, shows the release notes and (after confirmation, or with `-Yes`) installs it | yes (WinTidy itself) |

Examples:

```powershell
.\WinTidy.ps1 -Mode Scan -OpenReport
.\WinTidy.ps1 -Mode Scan -Deep                 # additionally offers SFC and a file system scan
.\WinTidy.ps1 -Mode Apply                      # interactive
.\WinTidy.ps1 -Mode Apply -Yes                 # unattended: only risk "Low"
.\WinTidy.ps1 -Mode Apply -Yes -IncludeMedium  # unattended including "Medium" items the rule releases (reversible ones)
.\WinTidy.ps1 -Mode Apply -Rule STA-HEAVY,DBL-APPS-MS
.\WinTidy.ps1 -Mode Apply -ExcludeRule APP-UPDATES
.\WinTidy.ps1 -Mode Compare -From 20261021 -To 20261024
.\WinTidy.ps1 -Mode Restore -RunId 20261021-183100
.\WinTidy.ps1 -Mode Hardware -CoolingTest      # check cooling, 60 s full load
.\WinTidy.ps1 -Mode Scan -Language de          # German output and report
.\WinTidy.ps1 -Mode Update                     # look for a new WinTidy version and install it
```

## Profiles (save and reuse the rule selection)

```powershell
.\WinTidy.ps1 -Mode Rules -SavePreset mine.json           # writes the default selection
.\WinTidy.ps1 -Mode Rules -Rule CLN-TEMP,STA-HEAVY -SavePreset small.json
.\WinTidy.ps1 -Mode Preview -Preset mine.json             # use it
.\WinTidy.ps1 -Mode Apply -Preset Safe                    # built-in: default rules without anything that needs confirmation
```

A profile is a small JSON file (`Format`, `Version`, `Name`, `Regeln`) that you can copy to another PC. Unknown rule IDs are ignored with a note. `-Rule` takes precedence over `-Preset`. Risk levels, confirmations and the company-PC filter still apply, and `-Yes` still only runs risk Low.

## Report for sharing

`.\WinTidy.ps1 -Mode Report -Share` creates `WinTidy-Bericht-teilbar.html` next to the normal report. PC name, user name, profile folder name, domain and the data folder path are replaced by placeholders. With `-Pdf` a PDF is created as well (needs Microsoft Edge or Google Chrome; otherwise print the HTML file from the browser). The app has the same function on the Settings page ("Share report"). Please still read the report before you pass it on - other details (programs, hardware, drive sizes) stay in it.

## Risk levels

| Level | Meaning | Prompt | with `-Yes` |
|---|---|---|---|
| Low | safe and reversible, or pure cache | once per rule | is applied (except items the rule holds back, e.g. browser caches while the browser is open) |
| Medium | useful, but a matter of taste or not reversible (e.g. uninstalling) | per item | only with `-IncludeMedium`, and only items the rule releases: reversible changes such as disabling broken services, `HeavyStartup` entries, Windows.old after the waiting time. Never uninstalls, updates, deleting devices or driver packages |
| High | heuristic with possible false positives | always per item | never |
| Info | report/hint only | – | – |

At prompts: `y` yes · `n` no · `a` all of this rule · `s` skip rule. (`j`/`ja` also work for yes.)

## Rules (excerpt)

`.\WinTidy.ps1 -Mode Rules` shows the complete list.

- **Storage:** temp files (by age), Windows Disk Cleanup (update leftovers, error reports …; memory dumps of recent blue screens are kept), previous Windows version (Windows.old, own rule, preselected only after 10 days), WinSxS cleanup, crash dumps, old recycle bin items, recycle bins of deleted accounts, old driver packages, *(optional)* orphaned program folders (set aside first, deleted after 30 days by `CLN-QUARANTINE`; "Restore" brings them back until then), unpacked driver installers (`C:\AMD`, `C:\NVIDIA`), profile folders of deleted accounts (only shown), smaller hibernation file on desktop PCs (Fast Startup keeps working), large browser caches (`CLN-BROWSER`, see below), large and old files in your personal folders (`CLN-BIGFILES`, only shown)
- **Startup:** entries with a missing file, orphaned state values, active autostarts sorted by **measured** boot delay
- **Tasks/services:** tasks and services with a missing program file, harmful patterns in home-made maintenance scripts (deleting Prefetch, emptying the whole recycle bin, `winget --all` at every sign-in …)
- **Programs:** versions installed side by side (older main versions are marked), outdated programs (winget). Preinstalled Store apps are on the Debloat page.
- **Debloat** (own page, `-Rule DBL-ADS,DBL-PRIVACY,DBL-SHELL,DBL-COMFORT,DBL-APPS-PROMO,DBL-APPS-MS,DBL-APPS-OEM`): 24 per-user settings (ads, suggestions, tracking, taskbar, Explorer) and a catalog of 130 removable Store apps (advertising apps, Microsoft apps incl. the former `APP-BLOAT` list, PC maker apps). Nothing machine-wide, no services, no policies.
- **System:** ghost devices (only after 90 days unseen), storage for restore points, SSD TRIM switched off, drive optimization not running, restart overdue, system integrity (DISM/SFC), Game Bar background recording (never preselected)
- **Hardware & cooling:** processor and graphics card temperature, fan speeds (stopped CPU fan, full speed on a cool PC, pump), throttling due to heat or firmware, several fan tools at once, drive health/temperature/wear, SMART warnings, memory diagnostic and WHEA errors, battery wear, cooling policy, refresh rate
- **Hardware configuration:** only one RAM module, RAM speed (XMP/EXPO), monitor on the motherboard instead of the graphics card, graphics card with too narrow a PCIe link, missing or year-old graphics driver, devices with an error code, power plan limits the processor/turbo off, Intel 13th/14th gen with old microcode, LAN only 100 Mbit/s, system drive vs. free NVMe
- **Security health check, Storage Sense, AI features (info only):** drive encryption, security chip (TPM), memory integrity, Defender tamper protection; whether Storage Sense is on and deletes old downloads; Copilot app and Recall. WinTidy only shows the state, it changes nothing.
- **Security/stability:** Windows without support or without updates, Secure Boot and the new Secure Boot certificates, antivirus (third-party products too), firewall, UAC, BIOS age, too broad antivirus exclusions, PowerShell policy (never preselected), unfavorable tuning settings (pagefile off, Prefetch/SysMain off, Windows Search off, Defender off by policy, update servers blocked in the hosts file, Windows held at an old version by policy), warnings in the event log

## Browser caches and large files

- **Browser caches (`CLN-BROWSER`, risk Low, not preselected):** Edge, Chrome, Brave, Vivaldi, Opera/Opera GX and Firefox, all profiles. Offered per browser from `BrowserCacheMinMB` (default 500 MB). Only the cache folders are emptied (`Cache`, `Code Cache`, `GPUCache`, the shader caches and Firefox `cache2`) – you stay signed in, cookies, history, passwords, bookmarks and extensions are not touched. The browser must be closed: if it is still open (Edge and Chrome often keep running in the background), the item is skipped and nothing is deleted. Websites load a little slower the first time afterwards, which is why nothing is preselected. With `-Yes` only browsers that are closed are cleaned.
- **Large files (`CLN-BIGFILES`, info only):** lists the largest files (from `BigFileMinMB`, default 1 GB) in Downloads, Desktop, Documents and Videos and how much space files in Downloads older than `DownloadsOldDays` (default 90) take. WinTidy **never deletes** them – you decide. Files that OneDrive keeps "online only" are not counted, links are not followed.
- **Before/after:** the comparison (app result, console, report) now also shows temp files, recycle bin, crash reports and browser caches in MB – measured, not estimated.

## Did WinTidy help? (performance key figures)

- **Eight key figures**, all measured by Windows or WinTidy itself: start time until ready, waiting time after the desktop appears, programs starting with Windows, background processes at idle, memory in use at idle, processor load at idle, drive activity at idle and free space on the Windows drive.
- **Baseline and answer:** the first "before" snapshot of an optimization is compared with the latest check. The answer is one sentence (helped / mixed / no measurable change / no improvement) plus a table with before, now and rating.
- **Honest by design:** small changes inside the measurement noise count as "unchanged". Start times are only taken from restarts after the optimization (at least 2) and show "not measurable yet" until then. If the PC was still busy while measuring, processor and drive values are marked and not counted as worse. For a fair comparison, check with the PC idle and no big program open.
- Where: home page of the app (card), History page (trend per key figure), result page after an optimization, console after Scan/Apply/Compare and the HTML report.

## Reminder to check again

If the last check is older than `CheckReminderDays` (default 30) days, the app shows a banner with **Check now** and the command line menu shows a hint. Checking changes nothing. `"CheckReminderDays": 0` switches the reminder off. WinTidy does not create a scheduled task for this.

## Cooling and fans – what works and what doesn't

Fan curves are stored in the BIOS or in the motherboard firmware (or in vendor tools) and can neither be read nor set from Windows. WinTidy therefore measures the **effect**:

- **Without an additional program:** throttling by the firmware (event 37), ACPI thermal zones (mainly laptops), NVIDIA graphics cards via `nvidia-smi` (temperature, fan, throttle reasons), drive temperature and wear, battery capacity.
- **With [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) (0.9.5 or later; older versions use the WinRing0 driver that Defender flags) or HWiNFO** running in the background: additionally processor temperature and all fan speeds. WinTidy detects this automatically.
- **Cooling test:** briefly puts all cores but one under full load and judges whether performance drops due to heat, whether the processor reaches its temperature limit (TjMax per CPU family, e.g. Ryzen 7000/9000 = 95 °C) and whether the fans speed up. A drop in performance after the turbo phase without heat counts as normal (vendor limit). Stops on its own on overheating, heavy heat throttling or when the power adapter is unplugged. Does not run on battery, on servers or in VMs.
- **What is rated:** snapshots in time (current temperatures, throttling) appear as hints but do not count in the health score; lasting conditions (drive, memory errors, battery) do. The NVIDIA fan value is a target value – 0 % on a cool card is the intended fan stop.

## What WinTidy deliberately does **not** do

- no registry "cleaners", no "tweaks" without proof of effect
- no fan or BIOS settings (there is no vendor-neutral, safe way to do this)
- Defender, updates, UAC, firewall etc. are never switched off
- no drivers are removed with `/force`, no files in Documents/Pictures/Desktop/Downloads are deleted (the large-file overview only reads)
- nothing on a drive that is currently not connected counts as "orphaned"

## Data, logs, report

With admin rights everything is stored protected under `%ProgramData%\WinTidy\<COMPUTERNAME>\` (only administrators and SYSTEM may write there – programs without admin rights cannot change the backups that "Restore" applies). Without admin rights under `%LOCALAPPDATA%\WinTidy\<COMPUTERNAME>\`. Data of older versions (`WinTidy-Daten` next to the script) is taken over once at the first start. Can be changed with `-DataPath`.

The folder and file names are internal and stay German in both languages:

```
%ProgramData%\WinTidy\PC-NAME\
  WinTidy-Bericht.html              # report (score, boot time history, before/after, findings, action log)
  snapshots\<time>_<scan|vorher|nachher>.json
  kuehltest\<time>.json             # measurement series of the cooling tests
  runs\<time>_<scan|preview|apply|restore|hardware|kuehltest>\
      konsole.txt                   # complete console log
      actions.jsonl                 # every action as a JSON line (time, rule, object, status, bytes, message)
      zusammenfassung.json          # summary of the run
      backup\*.reg, backup\tasks\   # backups before every change (since 1.3 additionally single values in actions.jsonl)
```

Tip for shared PCs: put the WinTidy folder itself into `C:\Program Files\WinTidy`, so that the script can only be changed by administrators too.

## Undo

1. `Restore` resets every changed setting individually: autostarts, Run entries, Game DVR, TRIM, cooling policy, hibernation file, script policy, service start types (including delayed), disabled tasks and deleted startup shortcuts. Values that someone else has changed since are not overwritten. Only expected registry paths are touched.
2. For everything else: System Restore (`rstrui.exe`) → point "WinTidy <run>".
3. Deleted files, uninstalled programs and removed Store apps cannot be brought back via WinTidy (Store apps can be reinstalled from the Store).

## Updates

WinTidy can keep itself up to date. This is **off by default**.

- **App:** Settings → Updates → tick **Update WinTidy automatically**. WinTidy then checks GitHub for a new release at most once a day, downloads and installs it. Afterwards a banner offers **Restart now**; until you restart, the old version keeps running. **Check for updates now** does it on request and asks before installing.
- **Command line:** `.\WinTidy.ps1 -Mode Update` (or **[U]** in the menu).
- **What is installed:** only official releases of the configured repository (`nicoflbr/WinTidy`) from GitHub, downloaded over HTTPS. WinTidy compares the download with the SHA-256 checksum of the release and checks the package (allowed files, PowerShell syntax, version) before it touches anything.
- **Safety net:** the replaced files are kept under `update\backup\<version>` in the data folder. If something goes wrong during the installation (or the PC loses power), the old files are put back automatically. Your `WinTidy.config.json` and `WinTidy.config.local.json` are not overwritten.
- **Requirements:** administrator rights and the normal protected data folder (not `-DataPath`). Updates are not possible for a git clone (use `git pull`) or when WinTidy runs from a network drive or a folder it cannot write to; the app then shows the reason.
- **Switch off completely** (e.g. on managed PCs): `"UpdateEnabled": false` in `WinTidy.config.json` or `WinTidy.config.local.json`.
- **Limits:** releases are not code-signed. An update is as trustworthy as the GitHub account behind the release. Version 1.4.1 and older cannot update themselves – install 1.5.0 manually once.

## Configuration

WinTidy reads its settings in three layers – later ones win:

1. the defaults in the script,
2. `WinTidy.config.json` – shipped with WinTidy, contains only **deviations** from the default,
3. `WinTidy.config.local.json` – optional, your **personal** settings for this PC. This file is not part of the repository (it is in `.gitignore`) and is never overwritten by an update.

All keys with their default values are listed in `WinTidy.config.example.json` (not loaded). Keys you don't set come from the script – that way improved defaults take effect automatically after an update.

Example `WinTidy.config.local.json` – never update KeePassXC and DaVinci Resolve via winget on this PC:

```json
{
  "WingetExclude": ["KeePassXC", "DaVinci"]
}
```

Lists replace the default list completely (copy the default entries from `WinTidy.config.example.json` if you only want to add to them); tables such as `DiskTempWarnC` are merged key by key.

## Requirements

Windows 10 (2004+) or Windows 11, Windows PowerShell 5.1. Admin rights for `Apply` and for complete scans; without admin rights e.g. the boot times are missing.

Development: see [DEVELOPMENT.md](DEVELOPMENT.md).
