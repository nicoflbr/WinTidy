# CLAUDE.md – Notes for AI assistants

Project: **WinTidy**, a generic Windows cleanup and tuning tool (PowerShell 5.1). Engine + command line: `WinTidy.ps1`. Graphical app: `WinTidy-App.ps1` (WPF, loads the engine into a background runspace). English and German (`lang/de.psd1`).

Read `DEVELOPMENT.md` before every change. It contains the principles, architecture, rule contract, languages, data formats, tests and the lessons from the first deployment.

Short version of the hard rules:
- No fixed paths, users or programs in the logic. Device-specific settings belong in the configuration (`WinTidy.config.json` = shipped deviations, `WinTidy.config.local.json` = personal, git-ignored; defaults in `$Script:DefaultConfig`, overview in `WinTidy.config.example.json` – regenerate it when adding keys).
- No snake oil, never switch off security features, never remove drivers with `/force`.
- `Detect` never changes anything. `Fix` backs up first and throws on errors. Expected "not possible" as `throw 'SKIP:<text>'` (counted as skipped).
- Registry changes only via `Set-RegValueWithUndo` (single-value undo); add new keys to `$Script:RestoreKeyAllow`. Delete folders only with `Remove-TreeNoFollow`/`Get-OldFiles` (they don't follow junctions).
- Hardware points: `Stufe` ok|warn|krit|'' and `Wertung` dauer|moment (snapshots in time don't count in the score).
- Stay compatible with PowerShell 5.1: no `?:`, `??`, no classes, no `-Parallel`.
- Only add snapshot fields, never rename them. Internal values (categories, risk levels, status codes, snapshot labels, undo types) stay German – translate only for display.
- User-facing texts in English with `T 'Text'` (literal first argument, placeholders `{0}`), German translation in `lang/de.psd1`. Keys must be unique ignoring case.
- Save `.ps1` files as UTF-8 with BOM and CRLF. No typographic quotes (“ ” „ ‘ ’) in PowerShell strings – they end the string.
- New rule → also add a plain-language text to `$Script:Friendly` (and its German translation).
- After changes run: `pwsh ./tests/Test-Parse.ps1`, `pwsh ./tests/Test-Report.ps1`, `pwsh ./tests/Test-Hardware.ps1` and `pwsh ./tests/Test-GuiApi.ps1`.
- Hardware: fan curves are not readable for Windows – only measure the effect, change nothing in the BIOS/on fans. New data sources as their own `Get-*` function so that `Test-Hardware.ps1` can replace them.
- Keep `$Script:Version` and `CHANGELOG.md` in sync.

On real PCs apply changes only via the tool with preview and prompts, never directly.
