# CLAUDE.md – Hinweise für KI-Assistenten

Projekt: **WinTidy**, ein allgemeingültiges Windows-Bereinigungs- und Optimierungstool (PowerShell 5.1). Engine + Kommandozeile: `WinTidy.ps1`. Grafische App: `WinTidy-App.ps1` (WPF, lädt die Engine in einen Hintergrund-Runspace).

Vor jeder Änderung `ENTWICKLUNG.md` lesen. Dort stehen Grundsätze, Architektur, Regel-Vertrag, Datenformate, Tests und die Erkenntnisse aus dem ersten Einsatz.

Kurzfassung der harten Regeln:
- Keine festen Pfade, Benutzer oder Programme in der Logik. Gerätespezifisches gehört in `WinTidy.config.json` (nur Abweichungen; Standardwerte in `$Script:DefaultConfig`, Übersicht in `WinTidy.config.beispiel.json` – bei neuen Schlüsseln neu erzeugen).
- Kein Snake Oil, keine Sicherheitsfunktionen abschalten, Treiber nie mit `/force` entfernen.
- `Detect` ändert nie etwas. `Fix` sichert vorher und wirft bei Fehlern. Erwartbares „geht nicht“ als `throw 'SKIP:<Text>'` (wird als Übersprungen gewertet).
- Registry-Änderungen nur über `Set-RegValueWithUndo` (Einzelwert-Undo); neue Schlüssel in `$Script:RestoreKeyAllow` aufnehmen. Ordner nur mit `Remove-TreeNoFollow`/`Get-OldFiles` löschen (folgen keinen Junctions).
- Hardware-Punkte: `Stufe` ok|warn|krit|'' und `Wertung` dauer|moment (Momentaufnahmen zählen nicht im Score).
- PowerShell-5.1-kompatibel bleiben: kein `?:`, `??`, keine Klassen, kein `-Parallel`.
- Snapshot-Felder nur ergänzen, nie umbenennen.
- Dateien als UTF-8 mit BOM speichern. Keine typografischen Anführungszeichen („ “) in PowerShell-Strings – sie beenden den String.
- Neue Regel → auch Laien-Text in `$Script:Friendly` ergänzen.
- Nach Änderungen ausführen: `pwsh ./tests/Test-Parse.ps1`, `pwsh ./tests/Test-Report.ps1`, `pwsh ./tests/Test-Hardware.ps1` und `pwsh ./tests/Test-GuiApi.ps1`.
- Hardware: Lüfterkurven sind für Windows nicht lesbar – nur Wirkung messen, nichts am BIOS/an Lüftern ändern. Neue Datenquellen als eigene `Get-*`-Funktion, damit `Test-Hardware.ps1` sie ersetzen kann.
- `$Script:Version` und `CHANGELOG.md` gemeinsam pflegen.

Auf echten PCs Änderungen nur über das Tool mit Vorschau und Rückfragen ausführen, nie direkt.
