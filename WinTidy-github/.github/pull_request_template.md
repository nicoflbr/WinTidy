## What and why

<!-- What does this change, and what problem does it solve? -->

## Checklist

- [ ] Tests pass locally (`pwsh ./tests/Test-Parse.ps1`, `Test-Report`, `Test-Hardware`, `Test-GuiApi`)
- [ ] Still compatible with Windows PowerShell 5.1, files saved as UTF-8 with BOM
- [ ] New or changed rule: `Detect` changes nothing, `Fix` backs up first, entry in `$Script:Friendly`
- [ ] Registry changes only via `Set-RegValueWithUndo` (new keys added to `$Script:RestoreKeyAllow`)
- [ ] `CHANGELOG.md` updated
- [ ] Tested on a real PC (Windows version: …)
