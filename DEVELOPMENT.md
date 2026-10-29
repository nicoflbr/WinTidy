# WinTidy – Developer documentation

This document is the basis for further development. It describes the goal and principles, the architecture, the rule contract, the data formats, the tests, the lessons learned from the first deployment and open ideas.

As of version 1.12.0, 2026-10-29.

---

## 1. Goal and principles

WinTidy should bring a **visible, measurable** improvement to **any** Windows 10/11 PC without causing harm. This results in the rules that apply to every change:

1. **Measure before changing.** Every change needs a finding with a reason (`Warum`) and becomes visible in the before/after comparison.
2. **Generic.** No device-specific or personal paths, user names or program names in the logic or in the shipped defaults (`$Script:DefaultConfig`). What only one PC needs belongs in `WinTidy.config.local.json`; shipped deviations in `WinTidy.config.json`. Vendor catalogs that apply to every PC (browser cache folders, OEM apps, driver installer folders as configuration keys) are fine.
3. **No snake oil.** No registry cleaners and no "tweaks" without proof of effect (e.g. deleting Prefetch, disabling SysMain, removing the pagefile, network "boosters").
4. **Never weaken security.** Defender, updates, UAC, firewall, Secure Boot and VBS/HVCI are never switched off.
5. **Reversible where possible.** Back up first (`Backup-RegKey`, `Backup-Task`, undo info in the action log), then change. Anything irreversible (deleting, uninstalling) gets at least risk "Medium" (`Mittel`), unless it is pure cache or temp, or something Windows itself deletes after a waiting time (recycle bin items older than 30 days, like Storage Sense). Diagnostic data that may still be needed (memory dumps of recent blue screens) is kept. Folders found by a heuristic are set aside first (`Move-ToQuarantine`), not deleted.
6. **Caution when in doubt.** Targets on a drive that is currently missing are never "orphaned" (`Get-TargetState` → `LaufwerkFehlt`). Never remove drivers with `/force`. Heuristics get risk "High" (`Hoch`) and `Standard = $false`.
7. **PowerShell 5.1, no dependencies.** Nothing to install. No `?:`, no `??`, no classes, no `ForEach-Object -Parallel`.
8. **Robust against localization.** Don't parse localized text when there is an alternative: CIM classes instead of performance counters, `dism /English`, `Repair-WindowsImage` instead of `sfc` text. If parsing is unavoidable (pnputil, winget), cover at least German and English.

---

## 2. Project structure

```
WinTidy\
  WinTidy.ps1            # engine + command line (one file, on purpose); also a library via dot-sourcing
  WinTidy-App.ps1        # graphical interface (WPF), loads WinTidy.ps1 into a background runspace
  WinTidy App.cmd        # launcher for the app (hidden console, the app requests admin rights itself)
  WinTidy.cmd            # command line launcher: requests admin rights, passes parameters through
  lang\de.psd1           # German texts (key = English text in the code, see section 3a)
  WinTidy.config.json    # shipped deviations from the defaults (merged with $Script:DefaultConfig)
  WinTidy.config.local.json      # optional personal settings for this PC (in .gitignore, never shipped)
  WinTidy.config.example.json    # all keys with default values (not loaded, generated from DefaultConfig)
  README.md              # GitHub start page
  USAGE.md               # user guide
  DEVELOPMENT.md         # this document
  CLAUDE.md              # short instructions for AI assistants (refers here)
  CONTRIBUTING.md, SECURITY.md, CHANGELOG.md, THIRD-PARTY-NOTICES.md, LICENSE (MIT)
  .github\workflows\tests.yml    # automatic tests (Windows PowerShell 5.1 and PowerShell 7)
  .github\workflows\release.yml  # tag v* -> ZIP + .sha256 + GitHub release with the CHANGELOG section
  tests\
    Test-Parse.ps1       # syntax of all .ps1, unique rule IDs, completeness of lang\de.psd1
    Test-Report.ps1      # synthetic snapshots -> comparison + HTML report in English and German (also runs on Linux/pwsh)
    Test-Hardware.ps1    # hardware rating, score, cooling test with synthetic values
    Test-GuiApi.ps1      # interface engine <-> app with test rules
    Test-Update.ps1      # updater offline: checksums, package checks, install, rollback (built ZIPs, mocked network)
    Test-Debloat.ps1     # Debloat page: catalog, allow-list, detection per build, fix, app removal, contexts (registry and apps replaced)
    Test-Storage.ps1     # browser caches, large-file overview, storage figures in before/after, check reminder (real temp folders)
    Test-Perf.ps1        # performance key figures: idle median, verdict with tolerance, start times after the optimization, history, report
    Test-Features.ps1    # SEC-HEALTH, SYS-STORAGESENSE, SYS-AI, profiles (export/import), shareable report
    Test-Rules.ps1       # rule review 1.10: unattended mode, quarantine, blue screen dumps, ghost devices, new checks, score
    Test-Exclusions.ps1  # exclusions 1.12: storage, item keys, filtered findings, fix defense, score with exclusions, history/report, GUI API, CLI
    Probe-Hardware.ps1   # diagnosis on real PCs: which sensor sources deliver what (writes probe-hardware.json)
    Probe-Display.ps1    # diagnosis: refresh rates according to driver and EDID
  WinTidy-Daten\         # runtime data up to 1.2 (in .gitignore); since 1.3 see below
```

**Runtime data (since 1.3):** with admin rights `%ProgramData%\WinTidy\<PC>` with a protected ACL (`Protect-WtDataRoot`: inheritance off, SYSTEM/Administrators full control, users read, owner Administrators), without admin rights `%LOCALAPPDATA%\WinTidy\<PC>`. Reason: "Restore" applies backups with admin rights – if they are in a folder writable by users, that is a privilege escalation. Old data (`WinTidy-Daten` next to the script) is copied at the first admin start (`$Script:DataMigrated`). At every start `Test-WtDataRootSafe` checks the whole folder (owner SYSTEM/Administrators, no write access for others, no links) and otherwise resets it via `icacls /reset` + `/setowner`; if it stays unsafe (`$Script:DataDirProtected = $false`), Restore is blocked. With `-DataPath`, Restore with admin rights only runs if that folder passes `Test-WtDataRootSafe` as well.

A single script file is intentional: copy and run, no module path, no signature chains. The engine now has > 3,000 lines – splitting it into a module is on the roadmap.

---

## 3. Architecture

```
Show-Header
  └─ Invoke-Mode <Scan|Preview|Apply|Compare|Report|Restore|Rules|Hardware|Exclusions>
        Scan    : Start-RunLog → Invoke-Rules($false) → New-Snapshot('scan', findings) → score → Show-Compare(previous) → New-Report
        Preview : Start-RunLog → Invoke-Rules($false)
        Apply   : Start-RunLog → New-Snapshot('vorher') → New-RestorePoint → Invoke-Rules($true)
                  → clear cache → New-Snapshot('nachher', findings) → Show-Compare → zusammenfassung.json → New-Report
        Compare : Get-Snapshots → Show-Compare(a, b)
        Report  : New-Report (from all snapshots + all actions.jsonl)
        Restore : single-value undo from actions.jsonl, register tasks from XML, service start types from undo info
        Exclusions : list / add / remove the points the user accepts (section 3h)
```

### Central building blocks

| Function | Task |
|---|---|
| `Merge-Config` | defaults (`$Script:DefaultConfig`) + `WinTidy.config.json` + `WinTidy.config.local.json` (later files win; keys starting with `_` are ignored; tables are merged per key, lists are replaced). `-ConfigPath` loads only that one file. The shipped config.json is deliberately almost empty: a full copy would hide new defaults from updates (this happened in 1.1.1 with `GhostDeviceExclude`). |
| `Invoke-Rules` | for each selected rule: admin check → `Detect` → output → with Apply a prompt depending on the risk level → `Fix` per item → `Add-ActionRecord` |
| `Confirm-Item` | prompt logic incl. `-Yes`/`-IncludeMedium`, "all" (`$Script:AllYes`) and "skip rule" (throws `SKIPRULE`) |
| `New-Snapshot` | measures the system state (see section 5) and saves JSON |
| `Get-HealthScore` | 100 minus traceable deductions (the list is shown in the report) |
| `Get-CompareMetrics` / `Show-Compare` | key figure delta with rating `besser`/`schlechter` (better/worse; direction per key figure) |
| `New-Report` | self-contained HTML file, SVG charts, light/dark via `prefers-color-scheme`, `<html lang>` = current language |
| `$Script:Cache` | result cache per mode run (startup, drivers, boot events, WinSxS analysis). **Clear it after changes!** |

### Data source helpers

`Get-BrowserCacheDirs` (cache folders per browser and profile from `$Script:BrowserCatalog`, sizes), `Get-PersonalFolders` / `Get-PersonalFileStats` (large and old files in Downloads/Desktop/Documents/Videos, no links, no cloud-only files, max. 50,000 files), `Get-CheckReminder` (last snapshot older than `CheckReminderDays`), `Get-InstalledApps` (Uninstall keys, without SystemComponent), `Get-StartupItems` (Run keys, startup folders, Store app StartupTasks incl. StartupApproved state and measured delay), `Get-BootEvents` / `Get-BootOffenders` (Diagnostics-Performance 100 and 101–109), `Get-DriverPackages` (pnputil, de/en), `Get-VolumeInfo` (volume + media/bus), `Get-RecycleBinOld` (Shell COM, deletion date), `Resolve-CommandTarget` (real target file from command lines, also behind rundll32/powershell/wscript), `Get-TargetState` (`ok` | `fehlt` | `LaufwerkFehlt` | `unbekannt`).

### Graphical interface (WinTidy-App.ps1)

```
UI thread (WPF, STA)                         background runspace (STA)
  Start-Op '<script text>' {OnDone}  ──────►   . WinTidy.ps1 -Language <de|en>  (once at start, library mode)
  DispatcherTimer (150 ms)                     Invoke-GuiScan / Invoke-FixSelection / Get-HistoryData / Invoke-GuiRestore
     ◄── $Sync.Log  (ConcurrentQueue) ◄─────    W -> $Script:UiSink -> queue (+ runs\<run>\protokoll.txt)
     ◄── $Sync.Progress @{I;N;Text}   ◄─────    OnProgress callback
     ──► $Sync.Selection / Expert / Deep / RestorePoint / Lang
```

- **Library mode:** if `WinTidy.ps1` is loaded via dot-sourcing (`$MyInvocation.InvocationName -eq '.'`), it ends before the menu.
- **GUI API in the engine:** `Get-WtContext`, `Get-AllFindings`, `Invoke-GuiScan` (→ findings, snapshot, report, context), `Invoke-FixSelection`, `Get-HistoryLight`/`Get-HistoryData`, `Get-RestorePreview`, `Invoke-GuiRestore` (→ Wiederhergestellt, Fehler, Details), `Invoke-GuiCoolingTest`. The findings stay in the runspace (`$Script:LastFindings`); the app only sends back rule IDs and item indexes.
- **`Invoke-FixSelection Selection RestorePoint OnProgress Control OhneRP`:** selection = `@{Id; Indexes}`. Flow: check the context (server/no admin rights → `Status = 'GESPERRT'`) → restore point (failure without `OhneRP` → `Status = 'RP-FEHLT'`, **nothing changed**, the run folder is removed; the app asks and calls again with `OhneRP = $true`) → snapshot before → steps (between steps check `$Control.Cancel` → `ABGEBROCHEN`; skip rules with `Dauer` on battery) → snapshot after → `Details [{Titel, Objekt, Status, Meldung}]`, `ComputerschutzEingeschaltet`, `Umkehrbar`.
- **Context (`Get-WtContext`):** `Server` (ProductType ≠ 1) blocks changes; `Verwaltet` (managed: domain or Intune/MDM) shows only info rules, low-risk rules of the category Speicher and SYS-TRIM (`Test-RuleAllowed`); `AnderesKonto` (app runs as a different user than the signed-in one), `NeustartAusstehend` (restart pending), `Akku` (battery).
- **Optional rule fields for the app:** `Dauer` (text, e.g. '5-15 minutes'), `Endgueltig` (permanent), `Einzeln` (select individually), `Umkehrbar` (reversible). Info items carry `Data.Stufe` (ok/warn/krit) for the traffic light symbol.
- **Plain-language texts:** `$Script:Friendly[<RuleId>] = @(title, explanation)`. Every new rule needs an entry.
- **Preselection:** Low = on, Medium = on if in `$Script:GuiPreselectMedium` or measured as slowing down/`AutoOk`, High = off and only visible in expert mode, Info = section "Good to know".
- **Groups:** `Get-Group` returns German group keys (`Aufräumen`, `Schneller starten`, …) that are also used for sorting (`$GroupOrder`); `Get-GroupText` turns them into the display text.
- **Light/dark:** all colors are `SolidColorBrush` resources in the XAML. `Apply-Theme` replaces the brushes (palettes `$ThemeLight` = values from the XAML, `$ThemeDark`). Don't modify brushes – WPF freezes the ones used by styles/templates. In XAML always `{DynamicResource …}`, in code always `Set-Brush $el 'Foreground' 'Key'` (SetResourceReference), never `$el.Foreground = B 'Key'`. Always add new colors as a resource and add them to `$ThemeDark` – never set color values directly in code or on a XAML element. Title bar via `DwmSetWindowAttribute` (attribute 20/19).
- **App settings** (`%APPDATA%\WinTidy\app-einstellungen.json`): `Darstellung` (Auto|Hell|Dunkel) and `Sprache` (Auto|de|en). The language is read at the very top of the script, before the first message box.
- **Errors** of the app go to `%TEMP%\WinTidy-App-Fehler.log`, after the start to the data folder.
- **The interface** is built in code (cards, checkboxes) instead of data binding, because bindings to PSCustomObjects are unreliable in PowerShell 5.1.

### 3a. Languages (since 1.4)

WinTidy speaks English and German. The code contains the **English** texts; `lang\de.psd1` maps each English text to German.

- **`T 'English text' [args]`** returns the text in the current language and formats it with `-f` if arguments are given: `T 'Step {0} of {1}' $i $n`. Use only literal texts as the first argument – `Test-Parse.ps1` collects them and checks the dictionary.
- **Language selection:** `Set-WtLanguage auto|en|de` (engine). `auto` = German if `CurrentUICulture` is German, otherwise English. CLI: `-Language`. App: setting `Sprache`, passed to the engine via `$Sync.Lang`.
- **`lang\de.psd1`** is read by `Read-WtLangFile` via the PowerShell AST into an ordinal `Dictionary` (`Import-PowerShellDataFile` fails with several hundred entries). Only `'key' = 'value'` string pairs. Keys must be unique **ignoring case** (PowerShell hashtable rule) – if two texts differ only in case, rephrase one of them.
- **XAML:** texts in the XAML are English; when German is active, `Convert-XamlLanguage` replaces `Text`, `Content`, `ToolTip`, `Header`, `Title`, `AutomationProperties.Name` and text nodes (whitespace-normalized) before loading.
- **Report:** `HT` = `T` + HTML encoding. Date formats are texts too (`T 'yyyy-MM-dd HH:mm'` → `dd.MM.yyyy HH:mm`).
- **Internal values stay German** and must never be translated: rule fields `Kategorie`, `Risiko` (`Niedrig`/`Mittel`/`Hoch`/`Info`), `Stufe`, status codes (`OK`, `Fehler`, `Uebersprungen`, `GESPERRT`, `RP-FEHLT` …), snapshot labels (`scan`/`vorher`/`nachher`), undo types, snapshot field names, folder and file names in the data folder. For display use `Get-RiskText`, `Get-CategoryText`, `Get-SnapshotLabelText`, `Get-StatusText` (engine) or `Get-GroupText` (app).
- **New text:** write it in English in the code with `T`, add the German translation to `lang\de.psd1` (alphabetical order is not required, but keep it tidy), run `Test-Parse.ps1`. It reports missing, unused and duplicate keys and placeholders `{0}` … that differ between English and German.
- **Parsing localized tool output** (pnputil, winget, robocopy) is independent of the WinTidy language – always cover German and English Windows.

### 3b. Updates (since 1.5)

Opt-in self-update from GitHub releases. Code: section "Updates" in `WinTidy.ps1` (before the modes), UI in `WinTidy-App.ps1` (card "Updates", banner), CLI `-Mode Update`. Three steps, each one a function that returns a `pscustomobject` with a German status code and a translated `Meldung`:

| Step | Function | Status | Does |
|---|---|---|---|
| check | `Invoke-GuiUpdateCheck` | `AKTUELL` `NEU` `GESPERRT` `FEHLER` | blockers, repairs an unfinished installation (`Undo-WtUpdateFiles`), asks `Get-LatestRelease`, remembers the release in `$Script:PendingUpdate` |
| stage | `Invoke-GuiUpdateStage` | `BEREIT` `GESPERRT` `FEHLER` | checks the addresses, requires a checksum, downloads to `<data>\update\download`, compares SHA-256, unpacks into `<data>\update\staged\files` (`Expand-WtUpdateZip`), checks the package (`Test-WtUpdatePackage`), writes `staged.json` with a hash per file. Changes nothing in the program folder |
| apply | `Invoke-GuiUpdateApply` | `OK` `GESPERRT` `FEHLER` | re-checks the staged files against `staged.json`, backs up the old files to `update\backup\<oldversion>`, copies the new ones next to their targets as `*.wtnew`, writes `journal.json`, then swaps file by file (`[IO.File]::Replace/Move`), engine last |

Security design (do not weaken):
- **Network:** `Open-WtHttp` only accepts `https` and the hosts in `$Script:UpdateHostPattern` (`github.com`, `*.githubusercontent.com`); redirects are followed by hand, each hop is checked again. Size limits everywhere. `Get-WtHttpText`/`Save-WtHttpFile`/`Get-LatestRelease` are separate functions so that tests can replace them.
- **Authenticity:** the ZIP must match GitHub's `digest` of the asset and/or the `.sha256` asset (at least one, both must agree). The release must belong to `UpdateRepo` (download URL prefix is checked). No pre-releases or drafts. There is **no code signing**: whoever controls the GitHub release controls the update. Say so in the docs, never claim more.
- **Package:** one optional top folder; every entry must pass `Test-WtUpdatePath` (a few text types in the root or one subfolder such as `lang/`, no `..`, no device names), unique names, max. 100 files and 10 MB per file / 20 MB total, required files present, every `.ps1`/`.psd1` parses, `$Script:Version` in the package equals the tag and is newer than the installed one.
- **Local tampering:** staging happens in the protected data folder (`Test-WtDataRootSafe`), so that only admins can swap the files between the steps. Updates therefore need admin rights and are refused with `-DataPath`.
- **Blockers** (`Get-WtUpdateBlocker`): `UpdateEnabled=false`, no admin, unprotected data folder, network drive, git clone, folder not writable.
- **Rollback:** `journal.json` lists the touched files (`Von`, `Nach`, `Fertig`, `Dateien` with `Pfad`/`Vorhanden`). `Undo-WtUpdateFiles` restores from the backup, removes new files and `*.wtnew`; it runs after a failed swap and at the start of every check (power loss). Once all swaps are done the journal gets `Fertig` and a failing cleanup never rolls back.
- **User files:** `WinTidy.config.json` is never overwritten if it exists; `WinTidy.config.local.json` is not part of the package; identical files are skipped (a running launcher `.cmd` is not touched).

App flow: setting `AutoUpdate` and the time of the last check `UpdateGeprueft` in `app-einstellungen.json`; after the start a silent check (once per `UpdateIntervalHours`), then stage and apply as separate silent operations (`updatecheck`, `updatestage`, `updateapply`); closing the window is blocked while `updateapply` runs; a banner offers **Restart now** (`Restart-App`). The manual button asks before installing. The first update from 1.4.1 or older is manual - those versions have no updater.

Tests: `tests/Test-Update.ps1` (offline, builds ZIP packages with `System.IO.Compression`, mocks the network and `Test-WtDataRootSafe`).

### 3c. Debloat page (since 1.6)

Own page in the app (nav item **Debloat**) with its own check and its own "Apply selected" button. Same rule contract, same cards, same undo - only the grouping differs.

- **Rules:** `DBL-ADS`, `DBL-PRIVACY`, `DBL-SHELL`, `DBL-COMFORT` (settings, category System, Low, reversible, no admin rights needed) and `DBL-APPS-PROMO`, `DBL-APPS-MS`, `DBL-APPS-OEM` (Store apps, category Programme, Medium/Medium/High, permanent, admin rights, OEM only individually). All have `Standard = $false` and `Seite = 'Debloat'`.
- **Rule fields `Seite` / `Vorwahl`:** a rule with `Seite` is not part of the normal check (`Get-AllFindings` without `-Page` skips it); `Get-AllFindings -Page 'Debloat'` returns only those rules. `Vorwahl = $false` switches off the preselection of a Low-risk rule (default: Low is preselected). The findings of both pages are merged in `$Script:LastFindings`, so `Invoke-FixSelection` finds the rule of either page. `Invoke-GuiDebloatScan` = `Get-AllFindings -Page` + hint for server / managed PC / other account.
- **Catalog:** `$Script:DebloatTweaks` (Id, Gruppe = rule, Min = first Windows build, Titel, Werte = `Dv key name value [type]`) and `$Script:DebloatApps` (Gruppe PROMO|MS|OEM, Id = package name prefix, Name). A tweak counts as done only if all its values already have the target value. `$Script:DebloatNever` = apps that are never removed (prefix match in both directions); `Remove-DebloatApp` checks it again.
- **Rules for new entries:** per-user only (HKCU), only settings that Windows Settings or Explorer options offer too, no policy keys for the whole PC, no services, no security features, no telemetry policies. Every key must match `$Script:RestoreKeyAllow` (`Test-Debloat` checks it), otherwise the undo refuses it. Apps: package name prefix (`Get-AppxPackage -Name 'Prefix*'`), never frameworks / `NonRemovable`, never on the never-remove list. A matter of taste is never preselected.
- **Not offered** on managed PCs, Windows Server and when WinTidy runs under a different account (HKCU and the app list would be the wrong profile).
- **Source:** the selection was compiled with the help of Win11Debloat (MIT) - see `THIRD-PARTY-NOTICES.md`. No code copied.
- **App side:** `Start-DebloatScan` (kind `scan`, so it can be cancelled), `Build-Debloat`, `Update-DebloatSummary`, `Confirm-Apply <page>`, `Start-Fix <ohneRP> <page>`; `$State.DebloatFindings`, `$State.LastFixPage` tells `Show-Result` which page to refresh. Opening the page scans automatically once; after applying, the page must be checked again.


### 3d. Browser caches, large files, check reminder (since 1.7)

- **`CLN-BROWSER`** (Speicher, Low, `Endgueltig`, `Vorwahl = $false`): catalog `$Script:BrowserCatalog` (name, process, root below `%LOCALAPPDATA%`, kind Chromium/Single/Firefox). Only the folder names in `$Script:BrowserCacheProfileDirs`, `$Script:BrowserCacheRootDirs` and `$Script:BrowserCacheFirefoxDirs` are ever emptied - never `Network`, `Cookies`, `Login Data`, `History`, `Local Storage`, `IndexedDB` or `Service Worker` (site data and sign-ins). `Clear-BrowserCache` checks everything again before deleting: the root must be a catalog root, every folder must have a known cache name and lie below the root without a link on the way (`Test-PathChainNoReparse`), the browser must not run (`Test-BrowserRunning`, otherwise `SKIP:`). Only the contents are deleted (via `Remove-TreeNoFollow`), the folders stay. `AutoOk` = browser closed, so `-Yes` does not end in a skip. Not offered when WinTidy runs under another account (`Test-DebloatUserHive`).
- **`CLN-BIGFILES`** (Info, no `Fix`): `Get-PersonalFileStats` walks the personal folders once (own stack, no links, no cloud-only files via the attributes Offline/RecallOnOpen/RecallOnDataAccess, max. 50,000 files) and reports the largest files and the old files in Downloads. Deleting personal files stays out of WinTidy on purpose.
- **Snapshot:** `Speicher.BrowserCacheBytes` (new field). `Get-CompareMetrics` shows the storage fields in MB (temp, recycle bin, crash reports, browser caches); old snapshots without a field give no delta.
- **Check reminder:** `Get-CheckReminder` reads only the file names of the snapshots. App: `init` passes `Erinnerung`, `Update-Banners` shows it until the next check (`$State.Reminder`). CLI: hint above the menu. No scheduled task, no background process.

### 3e. Performance key figures: "did WinTidy help?" (since 1.8)

- **Definition:** `Get-PerfDefs` (a function, not a `$Script:` table, because the tests load functions via the AST). Eight figures: `BootGesamt`, `BootNach`, `Autostart`, `Prozesse`, `Ram`, `Cpu`, `Platte`, `Frei`. Each has `Besser` (lower|higher), a noise tolerance (`Abs` absolute, `Rel` share of the old value, the larger one counts), `Boot` (comes from the boot events) and `Ruhe` (only reliable if the PC was idle). Choose figures that (1) Windows or WinTidy measure themselves, (2) a cleanup can really influence and (3) a user understands. Do not add figures that only describe the system (counts of installed programs, driver packages ...) - those stay in the detailed before/after table (`Get-CompareMetrics`).
- **Verdict:** `Get-PerfEffect $base $cur $boots`. `$base` = first snapshot with label `vorher`, `$cur` = latest snapshot. Rating per figure: `besser` | `schlechter` | `=` (inside the tolerance) | `offen` (not measurable). Verdict `Urteil`: `besser` (some better, none worse), `gemischt`, `schlechter`, `gleich`, `offen`. Ready-made, translated texts (`Kopfzeile`, `BootHinweis`, `*Text`) come from the engine because the app UI thread does not load the engine.
- **Start times:** only from boot events **after** `$base.Zeit`, newest 5, at least 2 - otherwise `offen`. A start right after the optimization still shows the old state; the old `Mittel5` of the "after" snapshot is therefore never used for the verdict.
- **Idle measurement:** `Get-IdleSample` waits up to 8 s until the CPU is at most 15 %, takes 6 readings and uses the median (`Get-Median`); `Ruhig` = median CPU at most 25 %. If `Ruhig` is false in the base or the current snapshot, CPU and drive differences count as `=` and are flagged `Unsicher`. Raw readings come from `Get-IdleCounters` (replaceable in tests). The idle sample is taken first in `New-Snapshot`, before the heavy queries.
- **History:** `Read-SnapshotHistory` reads all snapshots once (`Punkte` per snapshot via `Get-PerfPoint`, merged `Boots`, `Effekt`). Used by `Get-HistoryData`/`Get-HistoryLight`, the CLI and the app (`Load-Effect`, `Draw-Perf`). New snapshot fields only get added (`Leerlauf.PlatteProzent`, `PlatteOpsProSek`, `Ruhig`); older snapshots without them give `offen` / count as calm.
- **Display:** console `Show-PerfEffect`; report sections "Did WinTidy help?", "Trend of the key figures" (`New-PerfSpark`) and "Health score over time" (`New-ScoreSvg`, fixed scale 0-100, points colored by the rating limits 85/65); app: `EffectCard` (home), `PerfCard` and the score card (`Draw-Score` from `Scores` of `Get-HistoryLight`, history), `ResultEffect` (result page). `Get-CompareMetrics` rows have an `Id` - look results up by `Id`, never by the (translated) `Kennzahl`.

---

### 3f. Security check, Storage Sense, AI inventory, profiles, report for sharing (since 1.9)
- `SEC-HEALTH`, `SYS-STORAGESENSE` and `SYS-AI` are info rules (`Fix = $null`, `Stufe` ok|warn|krit|''), no influence on the score. Data sources are their own `Get-*` functions (`Get-BitLockerState`, `Get-MemoryIntegrityState`, `Get-TpmState`, `Get-DefenderTamperState`, `Get-StorageSenseState`, `Get-AiFeatureState`) that return `$null` when something is unreadable, so `Test-Features.ps1` can replace them. Deliberately no switches: Recall removal cannot be undone, the Debloat page forbids policies for the whole PC and security switches, and the Storage Sense registry semantics are only partly documented.
- Profiles: JSON `{ Format = 'WinTidy-Profil', Version = 1, WinTidy, Name, Regeln = [rule IDs] }` (field names stay German like the other stored data). `Resolve-WtPreset` (built-in `Safe`/`Standard` or a file; unknown IDs are dropped and reported, errors throw readable texts), `Save-WtPreset`. `Invoke-Mode` sets `$Script:Rule` from `-Preset` unless `-Rule` is given; an empty result aborts instead of falling back to the default selection.
- Report for sharing: `New-ShareableReport` builds the normal report first and derives `WinTidy-Bericht-teilbar.html` from it (`Get-ShareReplacements` + `ConvertTo-ShareableHtml`: text and attribute values, never the `<style>` block, terms shorter than 3 characters are skipped, longest term first). PDF via `Convert-HtmlToPdf` (headless Edge/Chrome with its own temporary profile folder, 90 s limit, readable message instead of an exception). Anything new that could identify the person or PC in the report needs an entry in `Get-ShareReplacements`.

### 3g. Rule review (since 1.10)
Every rule was challenged against the principles in section 1 (details: section 13).
- **Unattended mode fails closed:** `-Yes -IncludeMedium` only applies Medium items whose rule sets `AutoOk = $true` (`Test-UnattendedItem`). Before, every Medium item without `AutoOk` ran - including all uninstallers (`APP-SIDEBYSIDE`), all updates (`APP-UPDATES`, effectively `winget upgrade --all`) and all ghost devices. `$Script:GuiPreselectMedium` is empty; the items say it themselves.
- **Quarantine:** `CLN-ORPHANDIR` sets folders aside instead of deleting them (`Move-ToQuarantine`, `Get-QuarantineDirs`, `Test-QuarantinePath`, undo type `Ordner`); `CLN-QUARANTINE` deletes them after `QuarantineDays`.
- **Diagnostics are kept:** `CLN-WINCLEAN` keeps MEMORY.DMP/Minidump while there are dumps younger than `SystemDumpKeepDays` (`Test-RecentSystemDumps`), decided again at the time of the fix.
- **Waiting times instead of "everything at once":** `SYS-GHOST` only offers devices unseen for `GhostDeviceMinDays` (`Get-DeviceLastSeen`, unknown = not offered).
- **One cause, one finding:** `SYS-TRIM` only reports TRIM switched off; a drive optimization that does not run is `SYS-MAINT`, whose fix runs TRIM on SSDs right away. The fast-startup restart hint moved from `HW-HINTS` to `SYS-REBOOT`.
- **One philosophy for apps:** the former `APP-BLOAT` list is part of the Debloat catalog (group MS, nothing preselected); `BloatApps` only adds package names to that group.
- **Honest texts and preselection:** `SYS-GAMEDVR` and `SEC-EXECPOLICY` are never preselected (`AutoOk = $false`) - both are off/restrictive by default, so "on" means someone chose it. `APP-SIDEBYSIDE` marks older main versions ("may be installed on purpose"). `STA-HEAVY` matches `HeavyStartup` as whole words (`Test-WordMatch`: "Teams" no longer hits TeamSpeak).
- **New checks:** `CLN-DRIVERINSTALL` (unpacked driver installers from `DriverInstallerDirs`), `CLN-PROFILE-ORPHAN` (info), `SYS-REBOOT` (info), too broad Defender exclusions in `SEC-CHECKS` (`Get-DefenderExclusions`, `Get-BroadDefenderExclusions`), Windows Search off / hosts file blocking updates / Windows held by policy in `SYS-TWEAKS` (`Select-HostsUpdateBlocks`, `Get-UpdatePolicyPin`), graphics driver age in `HW-HINTS` (`GpuDriverMaxAgeDays`). `SEC-HEALTH` no longer warns if BitLocker is only paused until the next restart (`Get-BitLockerSuspendCount`).
- **No personal defaults:** `WingetExclude` and `BloatApps` are empty by default; entries that only one PC needs belong in its `WinTidy.config.local.json`.

### 3h. Exclusions (since 1.12)
Users can accept points as they are. An exclusion only ever **reduces** what WinTidy shows, changes and counts - it never adds an action.
- **Kinds (`Art`, internal German values):** `Objekt` = one item of a rule (`Regel` + `Schluessel`), `Regel` = a whole rule, `Abzug` = one deduction of the health score (`Regel` holds the deduction Id, see section 6).
- **Storage:** `ausnahmen.json` in `$Script:DataDir` (`Get-WtExclusionPath`, `Read-WtExclusions`, `Save-WtExclusions`, `Add-WtExclusion`, `Remove-WtExclusion`; cached in `$Script:Exclusions`, set it to `$null` to read again). Written atomically (tmp file + `Move-Item`), UTF-8 without BOM. A damaged, foreign or newer file means "no exclusions" plus a warning; writing over it first keeps a copy `.defekt`. Entries with an invalid kind or rule Id are skipped.
- **Item keys:** an item is identified by `Schluessel`, which must not depend on the display language. Rules set it explicitly (5th parameter of `New-Item2`, e.g. `SEC-CHECKS` `uac-off`, `firewall-public`, `defender-exclusion-<Art>-<Wert>`; `Get-StartupKey` for startup entries). Fallback `Get-WtItemKey`: `Technik`, string/number `Data`, `Key`/`Name`/`Pfad`/`Path`/`Id` of `Data`, then `Label`. A new rule whose items users may want to exclude should set `Schluessel`.
- **Findings:** `Get-AllFindings` removes excluded items (and rules whose last item was excluded), sets `Schluessel` on the kept items and `Ausgeschlossen` (count) on the rule, and collects what it removed in `$Script:LastExcludedHits` (the app shows "still found / no longer found" from it; `$Script:ExclChecked[$Page]` says that a page was checked). `Invoke-Rules` filters the same way and prints a gray line. `Invoke-FixSelection` reads the exclusions again and skips excluded items with status `Uebersprungen` - a point excluded after the check is never changed.
- **Score:** `Get-HealthScoreCore` produces the deductions (each with `Id`, `Punkte`, `Grund`, `Quelle`); `Get-HealthScore($s, $Exclusions)` returns `Wert`, `Abzuege`, `Ausgeschlossen` (accepted ones, with `Quelle` Objekt|Regel|Abzug) and `WertOhneAusnahmen`. `Get-ScoreItemLinks` maps items to deductions (`SEC-CHECKS|uac-off` = `SCORE-UAC`), `Get-ScoreRuleLinks` maps rules to deductions with another Id (`SCORE-AUTOSTART` = `STA-HEAVY`). Startup entries excluded via `STA-HEAVY` / `STA-ORPHAN` are subtracted before the thresholds; warning kinds (`EVT-HEALTH`) and hardware points (`HW-COOLING`) are excluded one by one. Snapshots on disk are never rewritten: `Get-SnapshotScore`, `Read-SnapshotHistory`, `Get-CompareMetrics` and `New-Report` recompute the score with the current exclusions.
- **GUI API:** `Get-GuiExclusions`, `Invoke-GuiExclude`, `Invoke-GuiInclude`, `Invoke-GuiIncludeAll` return `{ Eintraege[], Score, Fehler }` and never throw (readable text in `Fehler`, nothing changed then). `Invoke-GuiScan` / `Invoke-GuiDebloatScan` carry the same data as `.Ausnahmen`. The app keeps it in `$State.Exclusions` and replaces `$State.Snapshot.Score` with the returned score. Click handlers get their data via `.Tag` (`Start-Exclude`, `Start-Include` in `WinTidy-App.ps1`).
- **Command line:** `-Mode Exclusions` (`Invoke-ExclusionsMode`, `Show-WtExclusions`), `-AddExclusion RULE-ID|SCORE:ID`, `-RemoveExclusion n|all`, menu entry [E]. Input is validated completely first; on any error nothing is written. `-ExcludeRule` stays a per-run switch.
- **What cannot be excluded (`Get-ScoreFixedIds`):** `SCORE-ANTIVIRUS` (no active antivirus), `SCORE-WINSUPPORT` (Windows without security updates) and `SCORE-HWCRIT` (failing drive, memory errors, critical battery or cooling) are never a wanted state. Reason: WinTidy never weakens security and never hides a dying drive. `Add-WtExclusion` refuses an `Abzug` exclusion of them with a readable error, `Read-WtExclusions` drops such entries from a hand-edited file, the CLI refuses `-AddExclusion SCORE:...` (nothing is written), `Test-WtScoreExcluded` returns '' by every route, and the app gets `Fest = $true` on those entries of `Score.Abzuege` (no "Accept" link). Hardware points with `Stufe = 'krit'` are not subtracted by an `Objekt` exclusion either, and an `Objekt` exclusion never hides a critical item (`Test-WtExcluded -Stufe 'krit'`, `Get-WtItemStufe`; no "Exclude" link for them in the app). The hint itself is still shown.
- **A whole-rule exclusion only covers its own deduction:** `Regel` covers the deduction with the same Id or the one in `Get-ScoreRuleLinks` (`SCORE-AUTOSTART` = `STA-HEAVY`, `SCORE-HWWARN` = `HW-COOLING`). `Get-ScoreItemLinks` (`SEC-CHECKS|uac-off` = `SCORE-UAC` ...) only counts `Objekt` exclusions. So hiding the `SEC-CHECKS` hints ("Security basics") leaves every security deduction in the score.
- **Stable keys for hardware and warning signs:** every point of `Get-HardwarePoints` has a `Schluessel` that names the cause without measured values or text (`cpu-temp-high`, `gpu-fan-zero:<GPU name>`, `drive-temp-warm:<drive name>`, `pump-stopped`, `fan-tools-board` ...; set with `P ... -Key`), every entry of `Get-WarningSignals` has an Id per check (`power-loss`, `bluescreen`, `hardware-errors`, `drive-errors`, `gpu-driver-crash`, `tpm-errors`, `restore-points-lost`). They are the item keys of `HW-COOLING` / `EVT-HEALTH`, are stored in the snapshot (`Hardware.Punkte[].Schluessel`, `Stabilitaet.Warnsignale[].Schluessel`) and used by `Get-HealthScoreCore`; snapshots without the field fall back to the text. New points need a key, and keys are never renamed.
- **Tests:** `tests/Test-Exclusions.ps1`.

## 4. Rule contract

Every rule is a `[pscustomobject]` in `$Script:Rules`:

| Field | Type | Meaning |
|---|---|---|
| `Id` | string | unique, scheme `AREA-NAME` (CLN, STA, TSK, SVC, APP, SYS, SEC, HW, EVT) |
| `Kategorie` | string | grouping in the report (internal German value, displayed via `Get-CategoryText`) |
| `Titel` | string | short, says what is found – `(T '...')` |
| `Warum` | string | reason for the user; shown with every finding – `(T '...')` |
| `Risiko` | `Niedrig` \| `Mittel` \| `Hoch` \| `Info` | controls prompts and `-Yes` (see USAGE) |
| `Wirkung` | string | effect: Speicher, Startzeit, Leistung, Hygiene, Sicherheit, Stabilität |
| `Admin` | bool | rule is skipped without admin rights |
| `Standard` | bool | `$false` = only with `-Rule <Id>` |
| `Detect` | scriptblock | returns 0..n items (`New-Item2 Label Bytes Data`); **must not change anything** |
| `Fix` | scriptblock or `$null` | `param($it)`; changes exactly one item, returns a short message, throws on error |
| `Dauer`, `Endgueltig`, `Einzeln`, `Umkehrbar` | optional | hints for the app (show duration, "cannot be undone", select individually only …). `Dauer` = don't run on battery |

**Item:** `[pscustomobject]@{ Label; Bytes; Data }`. `Label` is for humans, `Data` carries everything `Fix` needs. `Bytes` is an estimate that is summed up in the report as "freed (estimated)". The real effect is shown by the snapshot comparison.

**Rules for `Detect`:**
- changes nothing on the PC - the only exception are WinTidy's own cache files in the data folder (e.g. the WinSxS analysis)
- no output except items (swallow return values of other commands with `| Out-Null` or `$null =`)
- store expensive results in `$Script:Cache`
- respect `-Deep` for slow checks

**Helpers every rule should use (since 1.3):**
- `Set-RegValueWithUndo Rule Objekt Key Name Value Type [-Remove]` – changes a registry value and writes before/after as undo info. Add new keys to `$Script:RestoreKeyAllow`, otherwise Restore does not reset them.
- `Get-OldFiles`, `Remove-EmptyDirs`, `Remove-TreeNoFollow`, `Test-SafeDeleteRoot` – never delete through junctions/symlinks and never drive roots, Windows, profile or program folders.
- `Get-TargetState` – `fehlt` (missing) only for a local drive letter; network paths and `\??\` forms are `unbekannt` (unknown) or normalized.
- `throw 'SKIP:<text>'` – an expected failure (driver in use, uninstall cancelled) appears as "Skipped", not as an error.
- `AutoOk` on the item – preselection in the app and release for `-Yes` (applies to all rules). Since 1.10 it fails closed (`Test-UnattendedItem`): risk Low runs unattended unless `AutoOk = $false`; risk Medium only with `AutoOk = $true`; High never. Set `$true` only for reversible changes (SVC-ORPHAN, HW-COOLPOLICY, STA-HEAVY for `HeavyStartup`, CLN-WINOLD after the waiting time, CLN-HIBERFIL), set `$false` for anything a person switched on on purpose or that is a matter of taste.
- `Move-ToQuarantine Rule Path` – renames a folder directly below Program Files/ProgramData/AppData in place to `<name>.WinTidy-removed-<yyyyMMdd>` and writes undo type `Ordner`; Restore renames it back, `CLN-QUARANTINE` deletes it after `QuarantineDays`.
- Info items: `New-Item2 (T 'Text') 0 @{ Stufe = 'ok'|'warn'|'krit'|'' }` – texts for non-technical users.

**Rules for `Fix`:**
- back up first (`Backup-RegKey`, `Backup-Task`; services/power settings: undo info via `Add-ActionRecord … 'Undo-Info' … @{Typ='Dienst'|'PowerSetting';…}` – `Invoke-Restore` and `Get-RestorePreview` know both types)
- determine the state freshly instead of trusting an outdated list (see CLN-TEMP)
- return a message on partial success, `throw` on a real error

### Template for a new rule

```powershell
[pscustomobject]@{ Id = 'CLN-EXAMPLE'; Kategorie = 'Speicher'; Titel = (T 'Example cache'); Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
    Warum = (T 'Why this is safe and what it brings.')
    Detect = { $p = Join-Path $env:LOCALAPPDATA 'Example\Cache'; $s = Get-DirSize $p; if ($s -gt 100MB) { New-Item2 "$p" $s $p } }
    Fix    = { param($it) Remove-TreeNoFollow $it.Data; (T 'emptied') }
}
```

Then add an entry to `$Script:Friendly` (plain-language title + explanation for the app), add the German texts to `lang\de.psd1`, run the tests (`tests\Test-Parse.ps1` reports missing translations), add the rule to USAGE (excerpt) and CHANGELOG, and run `-Mode Preview -Rule CLN-EXAMPLE` on a test PC or a VM.

---

## 5. Data formats

Field names are German and stay that way (compatibility with existing data).

### Snapshot (`snapshots\<yyyyMMdd-HHmmss>_<label>.json`)

```
Tool, Label (scan|vorher|nachher), Zeit (ISO), Admin, Computer, Benutzer
System     { OS, Build, Version, CPU, Kerne, Threads, RamGB, Board, BIOS, LetzterStart, LaufzeitStd }
Laufwerke  [ { LW, Label, FS, GroesseGB, FreiGB, FreiProzent, Medium, Bus, Disk } ]
Boot       { Verlauf [ {Zeit, GesamtMs, HauptpfadMs, NachDesktopMs} ], Mittel5, Bremser [ {Typ, Datei, Name, Anzahl, MittelMs, MaxMs} ] }
Autostart  { Gesamt, Aktiv, Verwaist, Liste [ {Name, Art, Ort, Ziel, Zustand, Aktiv, DegradationMs} ] }
Dienste    { Gesamt, Laufend, AutoDrittanbieter }
Aufgaben   { Gesamt, Eigene }
Programme  { Installiert, StoreApps }
Treiber    { Pakete, Duplikate, Geistergeraete }
Ereignisse { FehlerSystem7T, FehlerAnwendung7T, Top [ {Quelle, Anzahl} ] }
Leerlauf   { CpuProzent, RamBelegtProzent, RamBelegtGB, Prozesse, Threads, Handles, PlatteProzent (1.8), PlatteOpsProSek (1.8), Ruhig (1.8, false = PC was busy) }  (values are medians of 6 readings)
Speicher   { PapierkorbBytes, TempBytes, CrashDumpsBytes, BrowserCacheBytes (1.7) }
Sicherheit { SecureBoot, DefenderEchtzeit, AndererVirenschutz (1.2), AusfuehrungsrichtlinieCU, WindowsSupportEnde (1.3, yyyy-MM-dd), TageSeitUpdate (1.3), WindowsUpdateAus (1.3) }
Hardware   (1.2) { Laptop, Sensorquelle, CpuTempC, Luefter [ {Name, Upm} ], Gpu {Name, TempC, LuefterProzent, Gruende},
                   Laufwerke [ {Name, Art, TempC, Verschleiss, Zustand} ], Drosselung30T, Thermalzonen [ {Name, TempC, PassivLimit, Gruende} ],
                   AkkuVerschleiss, Punkte [ {Stufe warn|krit, Text, Wertung, Schluessel (1.12)} ] }
Stabilitaet (1.2) { Warnsignale [ {Text, Anzahl, Schluessel (1.12)} ] }
(1.3) Hardware.Punkte[].Wertung = 'dauer' | 'moment'; Befunde[].Stufen = level per item (for the traffic light after an app restart)
Befunde    [ {Regel, Kategorie, Titel, Risiko, Anzahl, Bytes, Objekte[max 50], Schluessel[] (1.12, parallel to Objekte), Ausgeschlossen (1.12, only if > 0)} ]
Score      { Wert, Abzuege [ {Id (1.12), Punkte, Grund, Fest (1.12, only in the recomputed score: cannot be accepted)} ], Ausgeschlossen (1.12) [ {Id, Punkte, Grund, Quelle} ], WertOhneAusnahmen (1.12) }
```

### Exclusion list (`ausnahmen.json`, since 1.12)

```
{ Format = 'WinTidy-Ausnahmen', Version = 1, WinTidy = '<version>',
  Eintraege = [ { Art (Objekt|Regel|Abzug), Regel, Schluessel, Anzeige, Titel, Zeit (ISO) } ] }
```

`Regel` is a rule Id or (for `Abzug`) a deduction Id from `Get-ScoreInfo`; `Schluessel` is only set for `Objekt`. Rule Ids, deduction Ids and item keys are never renamed because stored exclusions refer to them.

Only **add** new fields, never rename them. The report also reads old snapshots; missing fields must be handled tolerantly there. Texts stored in snapshots (`Titel`, `Text`, `Grund`) are in the language of the run that wrote them.

### Action log (`runs\<run>\actions.jsonl`)

One JSON line per action: `Zeit, Lauf, Regel, Objekt, Status (OK|Fehler|Uebersprungen|Undo-Info), Bytes, Meldung, Undo`.

Undo types: `RegValue {Key, Name, Vorher, Nachher}` (before/after = `{Art, Wert}` or `null` = value was missing; binary as Base64), `Dienst {Name, StartMode, Verzoegert}`, `PowerSetting {Schema, Sub, Setting, AC}`, `ExecPolicy {Scope, Vorher}`, `Hiber {Vorher}`, `Datei {Quelle, Ziel}` (deleted startup shortcut, copy under `backup\startup`). Restore takes them back in reverse order and overwrites nothing that has been changed since the run (`Nachher` ≠ current value). `.reg` backups are only imported for runs without single-value undo (before 1.3) or for removed app autostart keys (`appxkey_*`) – and only if every key in them is on the allow list. `rueckgaengig.json` in the run folder marks a run that has been undone.

### Boot measurement

Source: `Microsoft-Windows-Diagnostics-Performance/Operational`, event 100 (`BootTime`, `MainPathBootTime`, `BootPostBootTime`). The log is only readable with admin rights. Windows writes the entry only a few minutes after sign-in. Events 101 (apps), 102 (drivers) and 103 (services) provide the boot slowdowns. Caution: the delays overlap and must not be added up.

---

## 6. Health score

Start at 100, deductions (see `Get-HealthScore`):

| Condition | Deduction |
|---|---|
| Windows drive < 10 GB free or (< 10 % and < 20 GB) / (< 15 % and < 50 GB) | 20 / 8 |
| Windows version without security updates (`WindowsSupportEnd`) | 20 |
| Windows Update switched off / no updates for > 40 days | 15 / 10 |
| boot average of 5 > 90 s / > 60 s / > 40 s | 15 / 10 / 5 |
| active autostarts > 15 / > 10 | 10 / 5 |
| orphaned autostarts | 1 each, max. 5 |
| errors in system and application log (7 days) > 200 / > 50 | 5 / 3 |
| old driver packages > 10 | 3 |
| ghost devices > 50 | 2 |
| Secure Boot off | 4 (until 1.9: 8 – WinTidy itself advises non-experts not to switch it on) |
| User Account Control off (`Sicherheit.UacAus`, since 1.10) | 8 |
| firewall off for at least one network profile and no other firewall active (`Sicherheit.FirewallProfileAus`, since 1.10) | 10 |
| Defender real-time protection off **and** no other antivirus active | 15 |
| PowerShell policy Unrestricted/Bypass | 3 |
| recycle bin > 5 GB | 2 |
| warning signs in the event log (`Stabilitaet.Warnsignale`; old snapshots: EVT-HEALTH findings) | 2 per kind, max. 10 |
| hardware: critical points with `Wertung = dauer` (drive, memory errors, battery, stopped fan …) | 5 per point, max. 10 |
| hardware: irregularities with `Wertung = dauer` | 1 per point, max. 3 |

Each deduction has a stable Id (`Get-ScoreInfo`, stored in `Score.Abzuege[].Id`) so that it can be accepted (section 3h): `SCORE-FREESPACE`, `SCORE-BOOT`, `SCORE-AUTOSTART`, `STA-ORPHAN`, `SCORE-ERRORS`, `CLN-DRIVERSTORE`, `SYS-GHOST`, `SCORE-SECUREBOOT`, `SCORE-UAC`, `SCORE-FIREWALL`, `SCORE-ANTIVIRUS`, `SEC-EXECPOLICY`, `SCORE-WINSUPPORT`, `SCORE-WINUPDATE`, `CLN-RECYCLE`, `EVT-HEALTH`, `SCORE-HWCRIT`, `SCORE-HWWARN`. Three of them cannot be accepted (`SCORE-ANTIVIRUS`, `SCORE-WINSUPPORT`, `SCORE-HWCRIT`, see 3h). Accepted deductions count 0; the report shows them and "Without exclusions the score would be N".

Snapshots in time (current temperature, current throttling, event 37) deliberately don't count: they depend on what the PC is doing at the moment and would distort before/after.

Important: everything that goes into the score is measured by the snapshot **itself**. Up to 1.1.1 the warning signs came from the findings of the scan; the "before" snapshot of an optimization had no findings and therefore got a value that was too good (87 → 83 after an optimization, although nothing had gotten worse).

Adjust weights if needed. The score is a conversation starter, not an absolute truth. That is why the deductions are always shown in the report.

---

## 7. Tests

```powershell
pwsh ./tests/Test-Parse.ps1     # syntax, BOM, PS7 operators, unique rule IDs, German dictionary complete (exit code = number of errors)
pwsh ./tests/Test-Report.ps1    # builds the report from test data in the temp folder, in English and German (also checks the hardware section)
pwsh ./tests/Test-Hardware.ps1  # scenarios for cooling/fans/GPU/drives/battery, score, cooling test (English and German texts)
pwsh ./tests/Test-GuiApi.ps1    # app interface: findings, RP-FEHLT, OhneRP, cancel, battery, server/company PC, restore preview
pwsh ./tests/Test-Update.ps1    # updater: checksums, package checks, zip-slip, install, rollback, journal repair (offline)
pwsh ./tests/Test-Debloat.ps1   # Debloat page: catalog, detection per Windows build, fix, app removal, never-remove list, contexts
pwsh ./tests/Test-Storage.ps1   # browser caches (only cache folders, browser open, links, unknown paths), large files, comparison, reminder
pwsh ./tests/Test-Perf.ps1      # performance key figures: idle median/calm, verdict + tolerance, starts after the optimization, history, report (EN/DE)
pwsh ./tests/Test-Features.ps1  # security health check, Storage Sense, AI inventory, profiles round trip and errors, anonymized report, PDF fallback
pwsh ./tests/Test-Rules.ps1     # rule review 1.10: -Yes fails closed, quarantine, dumps kept, ghost devices by age, new checks, score
pwsh ./tests/Test-Exclusions.ps1 # exclusions 1.12: storage, item keys, filtered findings, fix defense, score, history/report, GUI API, CLI
```

All of them also run on Linux/macOS with PowerShell 7. Functions are loaded via the AST so that Windows-specific startup code is not executed. `Test-Hardware.ps1` replaces the data sources (`Get-HwMonitorSensors`, `Get-NvidiaGpus`, `Get-ThermalZones`, `Get-DiskHealth`, `Get-CpuPerfSample` …) with functions returning synthetic values – so always build new hardware data sources as their own `Get-*` function.

**Manual test matrix before a release** (ideally in a Windows VM with a snapshot):

| Case | Expectation |
|---|---|
| scan without admin | runs through, notice about missing admin rights, admin rules skipped |
| scan with admin | boot times present, report opens |
| Preview | no changes (registry/task comparison before/after) |
| Apply interactive | prompts per risk level, `s` skips a rule, `a` applies only to the rule |
| Apply `-Yes` | only Low; with `-IncludeMedium` also Medium; never High |
| Restore | autostart state, tasks and service start types back as before |
| German and English Windows | pnputil, winget and robocopy parsing works; app language follows Windows |
| app language switch | Settings → Language → restart → all texts in the chosen language |
| hardware without a sensor program | hint about LibreHardwareMonitor, GPU (NVIDIA) and throttling are rated |
| hardware with LibreHardwareMonitor | CPU temperature and fans appear, cooling test rates fan reaction |
| cancel the cooling test | load ends immediately (`finally` → `WtBurn::Stop`), result "cancelled" |
| laptop on battery | cooling test refused, long steps not preselected/skipped |

---

## 8. Lessons from the first deployment (2026-10-21)

Origin of the tool: assessment and two optimization rounds on the first test PC (Ryzen 9 5900X, Windows 11 25H2). What went into the rules:

- **Home-made "optimization" scripts are often the problem:** deleting Prefetch, emptying the whole recycle bin, deleting Downloads without an age limit and `winget upgrade --all --force` at every sign-in → rule `TSK-ANTIPATTERN`.
- **`winget upgrade --all` creates side-by-side versions with some installers** (6× rekordbox) → `APP-SIDEBYSIDE` and `WingetExclude`.
- **Leftovers from the previous PC:** Intel chipset drivers on an AMD system, 97 ghost devices, recycle bins of old SIDs, images under the old PC name → `CLN-DRIVERSTORE` (foreign platform), `SYS-GHOST`, `CLN-RECYCLE-ORPHAN`.
- **Drive letters change:** an autostart on `G:\` pointed nowhere because the drive was now called `E:` → `Get-TargetState` distinguishes `fehlt` (missing) and `LaufwerkFehlt` (drive missing).
- **Boot time can only be measured over several restarts.** A single boot after the optimization was even slower, because a new app (Mobalytics) had been added and the first boot after DISM still had work to do → the report shows the history and apply markers instead of a single value.
- **The measured boot slowdowns (event 101) are not additive:** Spotify reported 14–26 s, the gain was much smaller.
- **The big levers are often hardware/BIOS:** Windows on a SATA SSD, 1 TB NVMe empty, BIOS from 2022 with fTPM errors, Secure Boot off, RAID mode without an array → `HW-HINTS`, `SEC-CHECKS`.
- **Localization:** `vssadmin`/`sfc` output localized or UTF-16 text → CIM (`Win32_ShadowStorage`), `Repair-WindowsImage`, `dism /English`.
- **Set-ExecutionPolicy reports an "error" although the policy was set** when the process policy is Bypass → is caught.
- **Enable-ComputerRestore resets the shadow copy limit** (for us from 15 GB to 2 %). Hence `Invoke-Checkpoint`: try the checkpoint first, only switch on System Restore on failure.
- **Comments in scripts** caused false alarms in `TSK-ANTIPATTERN` ("Prefetch is NOT deleted") → comments are removed before the pattern check, hits need a delete command and the keyword on the same line.
- **cleanmgr does not reliably clean the Delivery Optimization cache** (10.7 GB remained) → additionally `Delete-DeliveryOptimizationCache`; old LiveKernelReports dumps (GPU watchdog) are deleted.
- **"Estimated" ≠ "measured":** the app shows the real increase in free space and the estimate only as an addition.
- **Automatic maintenance stops when someone works on the PC** (0x8007042B) – that is normal. `SYS-MAINT` only reports when it hasn't run for more than 14 days.
- **The bus type behind RAID drivers is wrong** (NVMe reported as SATA) → `HW-HINTS` additionally detects a "larger, almost empty SSD" and active RAID drivers without an array.
- **Never fill WPF resources with PowerShell wrapper objects:** `$Win.Resources[$k] = (New-Object …)` stores a `PSObject`, WPF then throws "Unable to cast PSObject to Brush" when displaying. Always store `.psobject.BaseObject`.
- **Typographic quotes are string delimiters in PowerShell!** “ ” „ end double-quoted strings, ‘ ’ ‚ end single-quoted strings. Never use them in code strings (`Test-Parse.ps1` checks this). In XAML they are harmless; in `lang\de.psd1` the values are single-quoted, so German „…“ quotes are fine there, but not ‘…’.
- **Remote control/automation cannot operate elevated windows** (UIPI). Tests of the app with admin rights have to be clicked by hand.
- **Store app autostarts** (e.g. Spotify) are not in the Run keys but under `SystemAppData\<package>\<task>\State` (2/4 = on, 1 = off by the user).

---

## 8a. Hardware & cooling (since 1.2)

**Principle:** fan curves live in the BIOS/UEFI or in the embedded controller of the motherboard or laptop. Windows has no vendor-neutral interface for this (`Win32_Fan` is empty on almost all PCs). WinTidy **measures the effect** and changes nothing on fans or the BIOS.

| Source | Function | Delivers | Notes |
|---|---|---|---|
| Kernel-Processor-Power, event 37 | `Get-ThrottleEventCount` | "performance limited by firmware" | according to Intel not a defect, but a hint about cooling/power limits |
| `Win32_PerfFormattedData_Counters_ThermalZoneInformation` | `Get-ThermalZones` | ACPI temperature, `PercentPassiveLimit` (< 100 = Windows throttles due to heat) | mostly laptops only; Kelvin (HighPrecisionTemperature in 1/10 K) |
| `Win32_PerfFormattedData_Counters_ProcessorInformation` (_Total) | `Get-CpuPerfSample` | `PercentProcessorPerformance` (> 100 = turbo), `PercentPerformanceLimit` | basis of the cooling test |
| `nvidia-smi --query-gpu=... --format=csv,noheader,nounits` | `Get-NvidiaGpus` / `ConvertFrom-NvidiaCsv` | temperature, fan %, power, clock, throttle reasons (bit mask) | `clocks_event_reasons.active`, fallback `clocks_throttle_reasons.active`. 0x20/0x40 = heat, 0x80 = power brake, 0x8 = HW slowdown, 0x4 = power limit (normal), 0x1 = idle |
| LibreHardwareMonitor / OpenHardwareMonitor (`root\LibreHardwareMonitor`, `Sensor`/`Hardware`) | `Get-HwMonitorSensors` | CPU temperature, all fans (Fan = RPM, Control = %) | only while the program is running (with LHM: WMI provider active) |
| HWiNFO (`HKCU:\Software\HWiNFO64\VSB`) | `Get-HwMonitorSensors` | values with "Report value in Gadget" | Label/Value/ValueRaw/Sensor per index |
| `Get-StorageReliabilityCounter`, `MSStorageDriver_FailurePredictStatus` | `Get-DiskHealth` | temperature, wear (NVMe), SMART warning | often empty behind RAID drivers; `TemperatureMax` is inconsistent → not rated |
| `root\wmi BatteryStaticData/BatteryFullChargedCapacity` | `Get-BatteryWear` | capacity loss | |
| power plan registry (`SYSCOOLPOL`) | `Get-PowerSettingIndex` | cooling policy AC/DC (0 = passive, 1 = active) | hidden setting, `powercfg /query` doesn't show it → registry: `User\PowerSchemes\<scheme>\<sub>\<setting>`, otherwise `PowerSettings\...\DefaultPowerSchemeValues\<scheme>` |
| `WmiMonitorListedSupportedSourceModes` (EDID) + `Win32_VideoController` | `HW-DISPLAY` | highest refresh rate of the monitor at the current resolution | only rated with exactly one monitor |

**Rating (`Get-HardwarePoints`, limits in the configuration, as of 1.3):**
- CPU in the scan: median of 5 values, only rated at load ≤ 30 %; desktop ≥ 80 °C warn, ≥ 90 °C crit (laptop +5). Measured **before** the expensive rules (DISM, winget), so that the CPU is still idle. Prefers Tdie, then Package/Tctl.
- Event 37: episodes (different minutes) instead of events, warn only on desktops with ≥ 3 in 7 days, otherwise a hint.
- Thermal zones: `PercentPassiveLimit` ≤ 80 crit, < 100 warn, cause from `ThrottleReasons` (0x1 heat, 0x2 power).
- Fans: CPU fan at 0 RPM only crit at CPU ≥ 60 °C (otherwise intended fan stop), pump at 0 RPM warn, full-speed control ≥ 95 % at CPU < 55 °C warn – pumps/GPU excluded, only if the fan with the same number is running. Several fan tools at the same time warn.
- NVIDIA: `fan.speed` is a target value. Crit at 0x40 or ≥ the card's slowdown temperature; warn at idle ≥ 70 °C, under load ≥ MaxOp − 5 (or target + 3 / 83 °C), fan 0 % at ≥ 70 °C, 0x8/0x80; 0x20 only a hint. Throttle reasons only if set in 2 of 3 samples. PCIe width < max: ≤ x4 warn, otherwise a hint.
- Drives: Unhealthy/Predictive Failure/SMART crit, Warning warn, Unknown ignored; temperature NVMe 70/80, SSD 60/70, HDD 50/60 °C; wear ≥ 80 % warn, ≥ 100 % crit.
- Memory diagnostics 1202 (90 days) crit; WHEA 19/17 ≥ 5 in 30 days warn. Battery ≥ 30 % warn, ≥ 50 % crit.

**Cooling test (`Invoke-CoolingTest`, as of 1.3):** 3 idle values → full load with `[WtBurn2]` (C# threads with normal priority on all logical processors except one; EcoQoS switched off for the duration via `SetProcessInformation(ProcessPowerThrottling)`; watchdog deadline in the C# part so that the load also ends if PowerShell hangs) and a measurement every 2 s → 3 values while cooling down. Safety stop (`GESTOPPT`) at CPU ≥ TjMax + 3, thermal zone ≤ 80 % or a disconnected power adapter. Rating relative to `CpuTjMax`: a performance drop ≥ 15/30 % is only a cooling problem (warn/crit) together with TjMax − 1 or a throttle signal; TjMax without a performance drop is a hint ("deliberately regulates at the limit"). Fan reaction per fan (without GPU/pump): ≥ +15 % ok, < +5 % at +20 K and ≥ 85 °C warn. Tests cancelled by the user are not saved; `Get-LastCoolingTest` only returns OK/GESTOPPT. Blocked on servers/VMs and on battery.

**Findings from the first PC (Ryzen 9 5900X, ASRock B550, RTX 4070 Ti):** no ACPI thermal zones, no `Win32_Fan`, drive counters empty because of the RAID driver, no event 37 → without LibreHardwareMonitor the GPU (36 °C, fan 0 % at idle = zero RPM) and the performance curve in the cooling test remain. Monitor: according to EDID 84 Hz is the maximum on this connection.

---

## 9. Known limits

- `cleanmgr /sagerun` may show a small progress window and run for a long time on some builds (timeout 60 minutes).
- pnputil and winget parsing: German and English tested, other languages maybe not (Detect then simply returns nothing).
- Boot slowdowns are matched to autostarts via the file name (heuristic).
- `APP-SIDEBYSIDE` groups by the name without version numbers and by the publisher. Exceptions are in `SideBySideExclude`.
- `CLN-ORPHANDIR` is a name heuristic → only on explicit request.
- Restore cannot bring back deletions and uninstalls (that's what the restore point is for). Exception since 1.10: folders set aside by `CLN-ORPHANDIR`, until `CLN-QUARANTINE` deletes them.
- `SYS-GHOST` needs the last arrival/removal date of a device (`DEVPKEY_Device_LastRemovalDate`/`LastArrivalDate`); devices without a date are not offered.
- Exclusion keys of info items without an explicit `Schluessel` fall back to their display text (`Label`), which depends on the language; such an exclusion may stop matching after a language change. Rules that users are likely to exclude set a language-independent `Schluessel` (section 3h). Hardware points and warning signs have one since 1.12 (`Get-HardwarePoints`, `Get-WarningSignals`); snapshots from before that only match by text. The cooling test result ("Last cooling test") has the fixed key `last-cooling-test`.
- `CLN-PROFILE-ORPHAN` only shows folders, it never deletes them (they may hold the only copy of personal files).
- Fan curves and BIOS settings are not readable. Desktop motherboards only report CPU temperature and fans via additional programs (LibreHardwareMonitor, HWiNFO). AMD/Intel graphics cards: only via these programs (no counterpart to `nvidia-smi` without additional software).
- `HW-DISPLAY` only rates with exactly one monitor; monitors that report high rates only in EDID extension blocks are not detected (no false alarm, just no hint).
- Languages: only English and German. Snapshots and run logs keep the language of the run that wrote them.
- Updates: releases are not code-signed, the checksum comes from the same GitHub release as the ZIP (it protects against damaged or swapped downloads, not against a compromised GitHub account). Versions up to 1.4.1 have no updater. A running app keeps using the old code until it is restarted.

---

## 10. Roadmap / ideas

**Still open from the review of 2026-10-23** (details: section 12)
- [ ] GPU temperature and real fan speed vendor-neutral via `D3DKMTQueryAdapterInfo(KMTQAITYPE_ADAPTERPERFDATA)` (AMD/Intel Arc without additional software) – verify the P/Invoke structure on real hardware
- [ ] Ryzen X3D with two CCDs: core parking prerequisites (chipset driver, Game Bar, power plan)
- [x] `SYS-GHOST` only devices not seen for ≥ 90 days (`DEVPKEY_Device_LastRemovalDate`) (1.10)
- [ ] NVMe PCIe link, GPU stays in P0 at idle
- [ ] `SYS-TWEAKS` with a fix (pagefile automatic, Prefetch/SysMain on) incl. undo
- [ ] Autostart via scheduled tasks with a logon trigger and services of vendor tools; score only without protected entries (partly done in 1.12: the user can exclude startup entries, section 3h; automatic detection of vendor entries is still open)
- [ ] Error counting with an exclusion list (DCOM 10016 etc.) and per day of uptime; score cap per category; mark "coverage" (admin/sensors) and comparability before/after
- [x] Report "for sharing" (anonymize user name/PC name/paths) (1.9.0, `-Share`/`-Pdf`; best effort - hardware and program names stay)
- [ ] App: banners can be hidden, time axis in the boot time chart, focus after page change, live region for progress, "larger font", result tiles only on change, plain/technical text separated (`Technik` field)
- [ ] More than 64 logical processors (processor groups) in the cooling test; option "thorough" (300 s) and SIMD load

**Short term**
- [x] App: dark mode (1.3.1)
- [x] English and German (1.4.0)
- [x] Opt-in automatic updates from GitHub releases (1.5.0)
- [ ] Updates: test on a real Windows PC with a real release (the 1.5.0 updater was only tested offline in CI); optionally a Windows service/scheduled task so that updates also happen when the app is not open
- [ ] App: own icon (.ico)
- [ ] Hardware: AMD GPU via ADLX/`amdsmi` (if present), history chart of the cooling test in app and report, GPU load in the cooling test
- [ ] App: mark recommendations as "done" individually after applying instead of asking for a new check
- [ ] Pester tests for `Resolve-CommandTarget`, the `Get-DriverPackages` parser, score and comparison
- [ ] `-Mode Schedule`: create a monthly scan as a scheduled task (scan only, report as a file)
- [ ] CSV/JSON export of the findings for multi-PC evaluation
- [x] Rule: browser caches (only when the browser is not running; Chrome/Edge/Vivaldi/Brave/Opera/Firefox) - `CLN-BROWSER` (1.7)
- [x] Large and old files in the personal folders, only shown - `CLN-BIGFILES` (1.7)
- [x] Reminder to check again after `CheckReminderDays` (app banner, CLI menu) - without a scheduled task (1.7)
- [ ] Rule: shrink WSL/Docker VHDX (Optimize-VHD or `diskpart compact`), only with a hint
- [ ] Rule: Steam shader cache/download leftovers, Ubisoft/EA patch leftovers without an installed game
- [ ] Rule: inconsistent OneDrive folder backup (two "Documents" folders)
- [ ] Rule: PowerShell modules in profiles that belong to no installed PowerShell version

**Medium term**
- [ ] Split into a module (`WinTidy.psm1` + `Rules\*.ps1`), rules as individual files
- [ ] More languages (`lang\<code>.psd1` with the same mechanism)
- [ ] Code signing, so that RemoteSigned/AllSigned is enough without `-ExecutionPolicy Bypass` - and so that updates can be verified by signature, not only by checksum
- [ ] Combined report across several PCs
- [ ] Benchmark mode (disk sequential/4K with `winsat` or DiskSpd, app start time measurement) as additional key figures. The passive key figures (start time, idle load, memory, drive activity ...) are done since 1.8 (section 3e)

**Deliberately not planned:** registry cleaners, telemetry/privacy "hardening" packs, switching off security features, driver updaters from third-party sources, cleaning `C:\Windows\Installer` (orphaned patch files - breaks repairs and uninstalls), emptying the thumbnail cache or Prefetch (rebuilt right away, no lasting effect).

---

## 11. Conventions

- Code, comments and documentation in English. User-facing texts in English with `T`, German in `lang\de.psd1`. Existing identifiers, data fields and internal values stay as they are (partly German) – don't rename them.
- Save files as **UTF-8 with BOM** and CRLF (PowerShell 5.1 otherwise reads ANSI).
- Output only via `W`/`Section`/`Sub`, never `Write-Output` in `Detect`.
- Every new rule gets a reason (`Warum`) that a non-technical user understands.
- Increase the version number in `$Script:Version` and `CHANGELOG.md` together (SemVer: new rule = minor, fix = patch, data format break = major).

---

## 12. Review of 2026-10-23 (four independent agents)

Checked were code/PS 5.1 compatibility, security/risk of damage, usability for non-technical users and domain logic (incl. hardware/cooling). The most important lessons for future rules:

- **Trust boundary data folder:** everything that is later applied with admin rights (backups, undo info) must be in a folder that non-admins cannot write to – and Restore only accepts expected paths.
- **`reg import` is not an undo:** it sets values but does not delete newly created ones. Hence single-value undo with before/after.
- **Never delete through links:** Windows PowerShell 5.1 follows junctions with `-Recurse`. Only use the own deletion helpers.
- **Fail closed:** if something cannot be determined (profile list, operating system, age of Windows.old), nothing is offered or it is blocked.
- **Vendor values instead of fixed limits:** TjMax per CPU family, limits of the graphics card from `nvidia-smi -q`. Many current CPUs/GPUs deliberately regulate at their limit.
- **Target value ≠ measured value:** NVIDIA's `fan.speed` is the requested speed. Fan stop at idle is intended.
- **"Unknown" is not a warning:** an unknown state is not rated.
- **Snapshots in time don't go into the score:** they make before/after incomparable.
- **Non-technical users see every text:** progress without action verbs, no registry paths or package names, no dangerous BIOS advice without a warning, don't preselect anything permanent.
- **Tests replace data sources:** every new source as its own `Get-*` function, so that `Test-Hardware.ps1`/`Test-GuiApi.ps1` can mock them.

## 13. Review of the rules (2026-10-28)

All rules were challenged one by one against the principles. Lessons for future rules:

- **Fail closed also applies to "unattended":** a missing flag must never mean "allowed". Unattended release is opt-in per item.
- **Don't delete the evidence you report:** if one rule reports a problem (blue screens), another must not delete what is needed to find its cause.
- **"Off by default" means "on" is a choice:** a setting that Windows ships switched off and that is now on was switched on by someone. Offer to change it, never preselect it.
- **One cause, one finding:** two rules that measure the same thing double the noise and the score effect.
- **Waiting times beat "all at once":** devices, folders and files that are only temporarily unused (dock, audio interface) must not be treated like leftovers.
- **Heuristics set aside, they don't delete:** what a name heuristic finds can be wrong; renaming in place is instant, keeps permissions and can be undone.
- **Substring matching is fail-safe only for protection lists:** for lists that trigger an action, match whole words.
- **The score should weigh real risks:** UAC and firewall off weigh more than a PowerShell execution policy; something WinTidy itself tells non-experts not to touch (Secure Boot) should not cost much.
- **Shipped defaults are for every PC:** entries that only one PC needs (programs excluded from updates, its own heavy startup apps) belong in `WinTidy.config.local.json`.
