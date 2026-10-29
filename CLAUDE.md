# CLAUDE.md – Notes for AI assistants

Project: **WinTidy**, a generic Windows cleanup and tuning tool (PowerShell 5.1). Engine + command line: `WinTidy.ps1`. Graphical app: `WinTidy-App.ps1` (WPF, loads the engine into a background runspace). English and German (`lang/de.psd1`).

Read `DEVELOPMENT.md` before every change. It contains the principles, architecture, rule contract, languages, data formats, tests and the lessons from the first deployment.

Short version of the hard rules:
- No device-specific or personal paths, users or programs in the logic, and none in the shipped defaults either (what only your own PC needs goes into `WinTidy.config.local.json`). Vendor catalogs that apply to every PC (browser cache folders, OEM apps) are fine. Device-specific settings belong in the configuration (`WinTidy.config.json` = shipped deviations, `WinTidy.config.local.json` = personal, git-ignored; defaults in `$Script:DefaultConfig`, overview in `WinTidy.config.example.json` – regenerate it when adding keys).
- No snake oil, never switch off security features, never remove drivers with `/force`.
- `Detect` never changes anything (except WinTidy's own cache files in the data folder). `Fix` backs up first and throws on errors. Expected "not possible" as `throw 'SKIP:<text>'` (counted as skipped).
- Unattended (`-Yes`): risk Low runs unless the item sets `AutoOk = $false`; risk Medium only if the item sets `AutoOk = $true` (fail closed, `Test-UnattendedItem`); High never. `AutoOk` is also the preselection in the app – set it to `$true` only for reversible changes, never for deleting, uninstalling or anything that is a matter of taste.
- Deleting folders found by a heuristic: set them aside with `Move-ToQuarantine` (renamed in place, undo type `Ordner`), `CLN-QUARANTINE` deletes them later.
- Registry changes only via `Set-RegValueWithUndo` (single-value undo); add new keys to `$Script:RestoreKeyAllow`. Delete folders only with `Remove-TreeNoFollow`/`Get-OldFiles` (they don't follow junctions).
- Hardware points: `Stufe` ok|warn|krit|'' and `Wertung` dauer|moment (snapshots in time don't count in the score).
- Stay compatible with PowerShell 5.1: no `?:`, `??`, no classes, no `-Parallel`.
- Only add snapshot fields, never rename them. Internal values (categories, risk levels, status codes, snapshot labels, undo types) stay German – translate only for display.
- User-facing texts in English with `T 'Text'` (literal first argument, placeholders `{0}`), German translation in `lang/de.psd1`. Keys must be unique ignoring case.
- Save `.ps1` files as UTF-8 with BOM and CRLF. No typographic quotes (“ ” „ ‘ ’) in PowerShell strings – they end the string.
- New rule → also add a plain-language text to `$Script:Friendly` (and its German translation).
- After changes run: `pwsh ./tests/Test-Parse.ps1`, `pwsh ./tests/Test-Report.ps1`, `pwsh ./tests/Test-Hardware.ps1`, `pwsh ./tests/Test-GuiApi.ps1`, `pwsh ./tests/Test-Update.ps1`, `pwsh ./tests/Test-Debloat.ps1`, `pwsh ./tests/Test-Storage.ps1` and `pwsh ./tests/Test-Perf.ps1`, `pwsh ./tests/Test-Features.ps1`, `pwsh ./tests/Test-Rules.ps1` and `pwsh ./tests/Test-Exclusions.ps1`.
- Hardware: fan curves are not readable for Windows – only measure the effect, change nothing in the BIOS/on fans. New data sources as their own `Get-*` function so that `Test-Hardware.ps1` can replace them.
- Keep `$Script:Version` and `CHANGELOG.md` in sync.
- Updater (section 3b in `DEVELOPMENT.md`): HTTPS + GitHub hosts only, checksum required, nothing is installed without the package checks, always with backup and rollback. Never weaken these checks; network access stays in replaceable `Get-*`/`Save-*` functions.
- Debloat page (section 3c in `DEVELOPMENT.md`): per-user settings and removable Store apps only, every key in `$Script:RestoreKeyAllow`, apps never on `$Script:DebloatNever`, nothing preselected that is a matter of taste. No policies for the whole PC, no services, no security or telemetry switches.
- Exclusions (section 3h in `DEVELOPMENT.md`): exclusions only ever reduce what WinTidy does. Items users may want to exclude need a stable, language-independent key (`Schluessel` on `New-Item2`); a new score deduction gets an Id in `Get-ScoreInfo`. Never rename ids or keys, stored exclusions refer to them.

On real PCs apply changes only via the tool with preview and prompts, never directly.
