# Contributing to WinTidy

Thanks for helping! Issues and pull requests are welcome in **English or German**.

## Before you start

- Read [DEVELOPMENT.md](DEVELOPMENT.md). It describes the architecture, the rule contract, data formats and lessons learned. [CLAUDE.md](CLAUDE.md) has the short version of the hard rules (also useful for humans).
- For larger changes or new rules, please open an issue first so we can agree on the approach.

## Ground rules

- **Evidence, not snake oil.** A new rule needs a measurable benefit or a clear problem it detects. Registry "cleaners", blanket "tweaks" and anything that weakens security (Defender, updates, UAC, firewall) will not be accepted.
- **Generic only.** No hard-coded paths, user names or programs in the logic. Device-specific settings belong in the configuration (`WinTidy.config.local.json` for your own PC).
- **`Detect` never changes anything.** `Fix` backs up first and throws on failure. Expected "can't do this here" cases throw `'SKIP:<reason>'`.
- **Registry changes only via `Set-RegValueWithUndo`.** Add new keys to `$Script:RestoreKeyAllow`. Delete folders only with `Remove-TreeNoFollow` / `Get-OldFiles`.
- **Every new rule** also needs a plain-language entry in `$Script:Friendly` (shown in the app).
- **Texts in English, translated to German.** Write user-facing texts in English with `T 'Text'` (placeholders: `T 'Step {0} of {1}' $i $n`) and add the German translation to `lang/de.psd1`. `Test-Parse.ps1` fails if a translation is missing. Internal values (categories, risk levels, status codes, snapshot fields) stay as they are. Details: DEVELOPMENT.md, section 3a.

## Code style

- Stay compatible with **Windows PowerShell 5.1**: no `?:`, `??`, `?.`, `&&`/`||`, classes or `ForEach-Object -Parallel`.
- Save `.ps1` files as **UTF-8 with BOM** and CRLF line endings.
- Do not use typographic quotes (`„ “ ‘ ’`) inside PowerShell strings; they end the string in PowerShell.
- Snapshot fields may be added, never renamed.

## Tests

The tests replace Windows functions with mocks and run on any OS with PowerShell 7:

```powershell
pwsh ./tests/Test-Parse.ps1     # syntax, BOM, PS7-only operators, typographic quotes, control characters, unique rule IDs, German translation complete
pwsh ./tests/Test-Report.ps1    # synthetic snapshots -> comparison + HTML report (English and German)
pwsh ./tests/Test-Hardware.ps1  # hardware rating, score, cooling test with synthetic readings
pwsh ./tests/Test-GuiApi.ps1    # engine <-> app interface with test rules
```

GitHub Actions also runs them on Windows PowerShell 5.1. `tests/Probe-*.ps1` are read-only diagnostics for real PCs. Their JSON output contains hardware details and is git-ignored, so please don't commit it.

## Releases

Bump `$Script:Version` in `WinTidy.ps1` and add a `CHANGELOG.md` entry with the same number (SemVer: new rule = minor, fix = patch, breaking data format = major). Then push a tag `vX.Y.Z`. The release workflow checks that the numbers match, runs the tests and publishes a ZIP.

## Reporting a security issue

Please don't open a public issue. See [SECURITY.md](SECURITY.md).
