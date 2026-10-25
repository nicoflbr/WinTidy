# WinTidy – Entwicklerdokumentation

Dieses Dokument ist die Grundlage für die Weiterentwicklung. Es beschreibt Ziel und Grundsätze, die Architektur, den Regel-Vertrag, die Datenformate, die Tests, die Erkenntnisse aus dem ersten Einsatz und die offenen Ideen.

Stand: Version 1.3.0, 23.10.2026.

---

## 1. Ziel und Grundsätze

WinTidy soll auf **jedem** Windows-10/11-PC eine **sichtbare, messbare** Verbesserung bringen, ohne Schaden anzurichten. Daraus folgen die Regeln, die bei jeder Änderung gelten:

1. **Messen vor Ändern.** Jede Änderung braucht einen Befund mit Begründung (`Warum`) und wird im Vorher/Nachher sichtbar.
2. **Allgemeingültig.** Keine festen Pfade, Benutzernamen oder Programmnamen in der Logik. Gerätespezifisches gehört in `WinTidy.config.json`.
3. **Kein Snake Oil.** Keine Registry-Cleaner und keine „Tweaks“ ohne Wirkungsnachweis (z. B. Prefetch löschen, SysMain abschalten, Pagefile entfernen, Netzwerk-„Booster“).
4. **Sicherheit nie verschlechtern.** Defender, Updates, UAC, Firewall, Secure Boot und VBS/HVCI werden nie abgeschaltet.
5. **Umkehrbar, wo möglich.** Erst sichern (`Backup-RegKey`, `Backup-Task`, Undo-Info im Aktionslog), dann ändern. Nicht Umkehrbares (Löschen, Deinstallieren) bekommt mindestens Risiko „Mittel“, außer es handelt sich um reinen Cache bzw. Temp.
6. **Vorsicht bei Unsicherheit.** Ziele auf einem gerade fehlenden Laufwerk sind nie „verwaist“ (`Get-TargetState` → `LaufwerkFehlt`). Treiber nie mit `/force` entfernen. Heuristiken bekommen Risiko „Hoch“ und `Standard = $false`.
7. **PowerShell 5.1, keine Abhängigkeiten.** Nichts nachinstallieren müssen. Kein `?:`, kein `??`, keine Klassen, kein `ForEach-Object -Parallel`.
8. **Lokalisierungsfest.** Keine lokalisierten Texte parsen, wenn es eine Alternative gibt: CIM-Klassen statt Leistungsindikatoren, `dism /English`, `Repair-WindowsImage` statt `sfc`-Text. Wenn Parsen unvermeidbar ist (pnputil, winget), mindestens Deutsch und Englisch abdecken.

---

## 2. Projektstruktur

```
WinTidy\
  WinTidy.ps1            # Engine + Kommandozeile (eine Datei, bewusst); per Dot-Sourcing auch Bibliothek
  WinTidy-App.ps1        # grafische Oberflaeche (WPF), laedt WinTidy.ps1 in einen Hintergrund-Runspace
  WinTidy App.cmd        # Starter fuer die App (versteckte Konsole, App holt sich Adminrechte selbst)
  WinTidy.cmd            # Starter Kommandozeile: holt Adminrechte, reicht Parameter durch
  WinTidy.config.json    # nur eigene Abweichungen vom Standard (wird mit $Script:DefaultConfig zusammengeführt)
  WinTidy.config.beispiel.json  # alle Schlüssel mit Standardwerten (wird nicht geladen, aus DefaultConfig erzeugt)
  README.md              # GitHub-Startseite (englisch)
  ANLEITUNG.md           # Anwenderdoku (deutsch)
  LICENSE                # MIT
  .github\workflows\tests.yml  # automatische Tests (Windows PowerShell 5.1 und PowerShell 7)
  ENTWICKLUNG.md         # dieses Dokument
  CLAUDE.md              # Kurzanweisung für KI-Assistenten (verweist hierher)
  CHANGELOG.md
  tests\
    Test-Parse.ps1       # Syntax aller .ps1 + eindeutige Regel-IDs
    Test-Report.ps1      # künstliche Snapshots -> Vergleich + HTML-Bericht (läuft auch unter Linux/pwsh)
    Test-Hardware.ps1    # Hardware-Bewertung, Score, Kühlungstest mit künstlichen Messwerten
    Test-GuiApi.ps1      # Schnittstelle Engine <-> App mit Testregeln
    Probe-Hardware.ps1   # Diagnose auf echten PCs: welche Sensorquellen liefern was (schreibt probe-hardware.json)
    Probe-Display.ps1    # Diagnose: Bildwiederholraten laut Treiber und EDID
  WinTidy-Daten\         # Laufzeitdaten bis 1.2 (in .gitignore); ab 1.3 siehe unten
```

**Laufzeitdaten (ab 1.3):** mit Adminrechten `%ProgramData%\WinTidy\<PC>` mit geschützter ACL (`Protect-WtDataRoot`: Vererbung aus, SYSTEM/Administratoren Vollzugriff, Benutzer Lesen, Besitzer Administratoren), ohne Adminrechte `%LOCALAPPDATA%\WinTidy\<PC>`. Grund: „Wiederherstellen“ spielt Sicherungen mit Adminrechten ein – liegen sie in einem für Benutzer beschreibbaren Ordner, ist das eine Rechteausweitung. Alte Daten (`WinTidy-Daten` neben dem Skript) werden beim ersten Admin-Start kopiert (`$Script:DataMigrated`). Bei jedem Start prüft `Test-WtDataRootSafe` den ganzen Ordner (Besitzer SYSTEM/Administratoren, keine Schreibrechte für andere, keine Verknüpfungen) und setzt ihn sonst per `icacls /reset` + `/setowner` zurück; bleibt er unsicher (`$Script:DataDirProtected = $false`), ist Restore gesperrt.

Eine einzige Skriptdatei ist Absicht: kopieren und starten, kein Modulpfad, keine Signaturketten. Die Engine hat inzwischen > 2.500 Zeilen – die Aufteilung in ein Modul steht in der Roadmap.

---

## 3. Architektur

```
Show-Header
  └─ Invoke-Mode <Scan|Preview|Apply|Compare|Report|Restore|Rules|Hardware>
        Scan    : Start-RunLog → Invoke-Rules($false) → New-Snapshot('scan', Befunde) → Score → Show-Compare(vorheriger) → New-Report
        Preview : Start-RunLog → Invoke-Rules($false)
        Apply   : Start-RunLog → New-Snapshot('vorher') → New-RestorePoint → Invoke-Rules($true)
                  → Cache leeren → New-Snapshot('nachher', Befunde) → Show-Compare → zusammenfassung.json → New-Report
        Compare : Get-Snapshots → Show-Compare(a, b)
        Report  : New-Report (aus allen Snapshots + allen actions.jsonl)
        Restore : *.reg importieren, Aufgaben aus XML registrieren, Dienst-Starttypen aus Undo-Infos
```

### Zentrale Bausteine

| Funktion | Aufgabe |
|---|---|
| `Merge-Config` | Defaults (`$Script:DefaultConfig`) + `WinTidy.config.json` (Schlüssel mit `_` werden ignoriert). Die mitgelieferte config.json ist bewusst fast leer: eine Vollkopie würde neue Standardwerte aus Updates überdecken (so passiert in 1.1.1 mit `GhostDeviceExclude`). |
| `Invoke-Rules` | Für jede ausgewählte Regel: Adminprüfung → `Detect` → Ausgabe → bei Apply Rückfrage nach Risikostufe → `Fix` pro Objekt → `Add-ActionRecord` |
| `Confirm-Item` | Rückfrage-Logik inkl. `-Yes`/`-IncludeMedium`, „alle“ (`$Script:AllYes`) und „Regel überspringen“ (wirft `SKIPRULE`) |
| `New-Snapshot` | Misst den Systemzustand (siehe Abschnitt 5) und speichert JSON |
| `Get-HealthScore` | 100 minus nachvollziehbare Abzüge (Liste wird im Bericht angezeigt) |
| `Get-CompareMetrics` / `Show-Compare` | Kennzahlen-Delta mit Bewertung `besser`/`schlechter` (Richtung je Kennzahl) |
| `New-Report` | Selbsttragende HTML-Datei, SVG-Diagramme, Hell/Dunkel per `prefers-color-scheme` |
| `$Script:Cache` | Ergebnis-Cache pro Modus-Lauf (Startup, Treiber, Boot-Events, WinSxS-Analyse). **Nach Änderungen leeren!** |

### Datenquellen-Helfer

`Get-InstalledApps` (Uninstall-Schlüssel, ohne SystemComponent), `Get-StartupItems` (Run-Schlüssel, Autostart-Ordner, Store-App-StartupTasks inkl. StartupApproved-Zustand und gemessener Verzögerung), `Get-BootEvents` / `Get-BootOffenders` (Diagnostics-Performance 100 bzw. 101–109), `Get-DriverPackages` (pnputil, de/en), `Get-VolumeInfo` (Volume + Medium/Bus), `Get-RecycleBinOld` (Shell-COM, Löschdatum), `Resolve-CommandTarget` (echte Zieldatei aus Befehlszeilen, auch hinter rundll32/powershell/wscript), `Get-TargetState` (`ok` | `fehlt` | `LaufwerkFehlt` | `unbekannt`).

### Grafische Oberflaeche (WinTidy-App.ps1)

```
UI-Thread (WPF, STA)                         Hintergrund-Runspace (STA)
  Start-Op '<Skripttext>' {OnDone}  ───────►   . WinTidy.ps1  (einmalig beim Start, Bibliotheksmodus)
  DispatcherTimer (150 ms)                     Invoke-GuiScan / Invoke-FixSelection / Get-HistoryData / Invoke-GuiRestore
     ◄── $Sync.Log  (ConcurrentQueue) ◄─────    W -> $Script:UiSink -> Queue (+ runs\<lauf>\protokoll.txt)
     ◄── $Sync.Progress @{I;N;Text}   ◄─────    OnProgress-Callback
     ──► $Sync.Selection / Expert / Deep / RestorePoint
```

- **Bibliotheksmodus:** Wird `WinTidy.ps1` per Dot-Sourcing geladen (`$MyInvocation.InvocationName -eq '.'`), endet es vor dem Menue.
- **GUI-API in der Engine:** `Get-WtContext`, `Get-AllFindings`, `Invoke-GuiScan` (→ Findings, Snapshot, Report, Context), `Invoke-FixSelection`, `Get-HistoryLight`/`Get-HistoryData`, `Get-RestorePreview`, `Invoke-GuiRestore` (→ Wiederhergestellt, Fehler, Details), `Invoke-GuiCoolingTest`. Die Befunde bleiben im Runspace (`$Script:LastFindings`), die App schickt nur Regel-IDs und Item-Indizes zurueck.
- **`Invoke-FixSelection Selection RestorePoint OnProgress Control OhneRP`:** Auswahl = `@{Id; Indexes}`. Ablauf: Kontext pruefen (Server/keine Adminrechte → `Status = 'GESPERRT'`) → Wiederherstellungspunkt (Fehlschlag ohne `OhneRP` → `Status = 'RP-FEHLT'`, **nichts geaendert**, Laufordner wird entfernt; die App fragt nach und ruft mit `OhneRP = $true` erneut auf) → Snapshot vorher → Schritte (zwischen den Schritten `$Control.Cancel` pruefen → `ABGEBROCHEN`; Regeln mit `Dauer` im Akkubetrieb ueberspringen) → Snapshot nachher → `Details [{Titel, Objekt, Status, Meldung}]`, `ComputerschutzEingeschaltet`, `Umkehrbar`.
- **Kontext (`Get-WtContext`):** `Server` (ProductType ≠ 1) sperrt Aenderungen; `Verwaltet` (Domaene oder Intune/MDM) zeigt nur Info-Regeln, Niedrig-Regeln der Kategorie Speicher und SYS-TRIM (`Test-RuleAllowed`); `AnderesKonto` (App laeuft als anderer Benutzer als der angemeldete), `NeustartAusstehend`, `Akku`.
- **Optionale Regelfelder fuer die App:** `Dauer` (Text, z. B. '5-15 Minuten'), `Endgueltig`, `Einzeln`, `Umkehrbar`. Info-Items tragen `Data.Stufe` (ok/warn/krit) fuer das Ampel-Symbol.
- **Laien-Texte:** `$Script:Friendly[<RegelId>] = @(Titel, Erklaerung)`. Jede neue Regel braucht einen Eintrag.
- **Vorauswahl:** Niedrig = an, Mittel = an, wenn in `$Script:GuiPreselectMedium` oder gemessen bremsend/`AutoOk`, Hoch = aus und nur im Expertenmodus sichtbar, Info = Abschnitt „Gut zu wissen“.
- **Hell/Dunkel:** Alle Farben sind `SolidColorBrush`-Ressourcen im XAML. `Apply-Theme` ersetzt die Pinsel (Paletten `$ThemeLight` = Werte aus dem XAML, `$ThemeDark`). Pinsel nicht verändern – WPF friert die von Styles/Vorlagen benutzten ein. Im XAML immer `{DynamicResource …}`, im Code immer `Set-Brush $el 'Foreground' 'Key'` (SetResourceReference), nie `$el.Foreground = B 'Key'`. Neue Farben immer als Ressource anlegen und in `$ThemeDark` ergänzen – nie Farbwerte direkt im Code oder XAML-Element setzen. Titelleiste über `DwmSetWindowAttribute` (Attribut 20/19).
- **Fehler** der App landen in `%TEMP%\WinTidy-App-Fehler.log`.
- **Oberflaeche** wird im Code aufgebaut (Karten, Checkboxen) statt per Datenbindung, weil Bindings auf PSCustomObjects in PowerShell 5.1 unzuverlaessig sind.

---

## 4. Regel-Vertrag

Jede Regel ist ein `[pscustomobject]` in `$Script:Rules`:

| Feld | Typ | Bedeutung |
|---|---|---|
| `Id` | string | eindeutig, Schema `BEREICH-NAME` (CLN, STA, TSK, SVC, APP, SYS, SEC, HW, EVT) |
| `Kategorie` | string | Gruppierung im Bericht |
| `Titel` | string | kurz, sagt was gefunden wird |
| `Warum` | string | Begründung für den Anwender; wird bei jedem Befund angezeigt |
| `Risiko` | `Niedrig` \| `Mittel` \| `Hoch` \| `Info` | steuert Rückfragen und `-Yes` (siehe ANLEITUNG) |
| `Wirkung` | string | Speicher, Startzeit, Leistung, Hygiene, Sicherheit, Stabilität |
| `Admin` | bool | Regel wird ohne Adminrechte übersprungen |
| `Standard` | bool | `$false` = nur mit `-Rule <Id>` |
| `Detect` | scriptblock | gibt 0..n Items zurück (`New-Item2 Label Bytes Data`); **darf nichts ändern** |
| `Fix` | scriptblock oder `$null` | `param($it)`; ändert genau ein Item, gibt eine kurze Meldung zurück, wirft bei Fehler |
| `Dauer`, `Endgueltig`, `Einzeln`, `Umkehrbar` | optional | Hinweise für die App (Dauer anzeigen, „kann nicht rückgängig gemacht werden“, nur einzeln wählbar …). `Dauer` = im Akkubetrieb nicht ausführen |

**Item:** `[pscustomobject]@{ Label; Bytes; Data }`. `Label` ist für Menschen, `Data` trägt alles, was `Fix` braucht. `Bytes` ist eine Schätzung, die im Bericht als „freigegeben (geschätzt)“ summiert wird. Die tatsächliche Wirkung zeigt der Snapshot-Vergleich.

**Regeln für `Detect`:**
- keine Ausgabe außer Items (Rückgaben anderer Befehle mit `| Out-Null` bzw. `$null =` schlucken)
- teure Ergebnisse in `$Script:Cache` ablegen
- `-Deep` für langsame Prüfungen respektieren

**Hilfen, die jede Regel benutzen soll (seit 1.3):**
- `Set-RegValueWithUndo Rule Objekt Key Name Value Type [-Remove]` – ändert einen Registry-Wert und schreibt Vorher/Nachher als Undo-Info. Neue Schlüssel in `$Script:RestoreKeyAllow` eintragen, sonst setzt Restore sie nicht zurück.
- `Get-OldFiles`, `Remove-EmptyDirs`, `Remove-TreeNoFollow`, `Test-SafeDeleteRoot` – löschen nie über Junctions/Symlinks und nie Laufwerkswurzeln, Windows-, Profil- oder Programmordner.
- `Get-TargetState` – `fehlt` nur bei lokalem Laufwerksbuchstaben; Netzwerkpfade und `\??\`-Formen sind `unbekannt` bzw. werden normalisiert.
- `throw 'SKIP:<Text>'` – erwartbares Nichtgelingen (Treiber in Benutzung, Deinstallation abgebrochen) erscheint als „Übersprungen“, nicht als Fehler.
- `AutoOk` am Item – Vorauswahl in der App und Freigabe für `-Yes` (gilt jetzt für alle Regeln, nicht nur STA-HEAVY).
- Info-Items: `New-Item2 Text 0 @{ Stufe = 'ok'|'warn'|'krit'|'' }` – Texte für Laien, mit Umlauten.

**Regeln für `Fix`:**
- vorher sichern (`Backup-RegKey`, `Backup-Task`; Dienste/Energieeinstellungen: Undo-Info per `Add-ActionRecord … 'Undo-Info' … @{Typ='Dienst'|'PowerSetting';…}` – `Invoke-Restore` und `Get-RestorePreview` kennen beide Typen)
- Zustand frisch ermitteln statt einer veralteten Liste zu vertrauen (siehe CLN-TEMP)
- bei Teilerfolg eine Meldung zurückgeben, bei echtem Fehler `throw`

### Vorlage für eine neue Regel

```powershell
[pscustomobject]@{ Id = 'CLN-BEISPIEL'; Kategorie = 'Speicher'; Titel = 'Beispiel-Cache'; Risiko = 'Niedrig'; Wirkung = 'Speicher'; Admin = $false; Standard = $true
    Warum = 'Warum das sicher ist und was es bringt.'
    Detect = { $p = Join-Path $env:LOCALAPPDATA 'Beispiel\Cache'; $s = Get-DirSize $p; if ($s -gt 100MB) { New-Item2 "$p" $s $p } }
    Fix    = { param($it) Remove-Item -LiteralPath $it.Data -Recurse -Force -ErrorAction Stop; 'geleert' }
}
```

Danach einen Eintrag in `$Script:Friendly` (verstaendlicher Titel + Erklaerung fuer die App) ergaenzen, `tests\Test-Parse.ps1` ausführen, die Regel in ANLEITUNG (Auszug) und CHANGELOG ergänzen und auf einem Test-PC oder einer VM `-Mode Preview -Rule CLN-BEISPIEL` laufen lassen.

---

## 5. Datenformate

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
Leerlauf   { CpuProzent, RamBelegtProzent, RamBelegtGB, Prozesse, Threads, Handles }
Speicher   { PapierkorbBytes, TempBytes, CrashDumpsBytes }
Sicherheit { SecureBoot, DefenderEchtzeit, AndererVirenschutz (1.2), AusfuehrungsrichtlinieCU, WindowsSupportEnde (1.3, yyyy-MM-dd), TageSeitUpdate (1.3), WindowsUpdateAus (1.3) }
Hardware   (1.2) { Laptop, Sensorquelle, CpuTempC, Luefter [ {Name, Upm} ], Gpu {Name, TempC, LuefterProzent, Gruende},
                   Laufwerke [ {Name, Art, TempC, Verschleiss, Zustand} ], Drosselung30T, Thermalzonen [ {Name, TempC, PassivLimit, Gruende} ],
                   AkkuVerschleiss, Punkte [ {Stufe warn|krit, Text} ] }
Stabilitaet (1.2) { Warnsignale [ {Text, Anzahl} ] }
(1.3) Hardware.Punkte[].Wertung = 'dauer' | 'moment'; Befunde[].Stufen = Stufe je Objekt (für die Ampel nach App-Neustart)
Befunde    [ {Regel, Kategorie, Titel, Risiko, Anzahl, Bytes, Objekte[max 50]} ]
Score      { Wert, Abzuege [ {Punkte, Grund} ] }
```

Neue Felder **nur hinzufügen**, nie umbenennen. Der Bericht liest alte Snapshots mit, fehlende Felder müssen dort tolerant behandelt werden.

### Aktionslog (`runs\<lauf>\actions.jsonl`)

Eine JSON-Zeile pro Aktion: `Zeit, Lauf, Regel, Objekt, Status (OK|Fehler|Uebersprungen|Undo-Info), Bytes, Meldung, Undo`.

Undo-Typen: `RegValue {Key, Name, Vorher, Nachher}` (Vorher/Nachher = `{Art, Wert}` bzw. `null` = Wert fehlte; Binary als Base64), `Dienst {Name, StartMode, Verzoegert}`, `PowerSetting {Schema, Sub, Setting, AC}`, `ExecPolicy {Scope, Vorher}`, `Hiber {Vorher}`, `Datei {Quelle, Ziel}` (gelöschte Autostart-Verknüpfung, Kopie unter `backup\startup`). Restore nimmt sie in umgekehrter Reihenfolge zurück und überschreibt nichts, was seit dem Lauf geändert wurde (`Nachher` ≠ aktueller Wert). `.reg`-Sicherungen werden nur noch für Läufe ohne Einzelwert-Undo (vor 1.3) bzw. für entfernte App-Autostart-Schlüssel (`appxkey_*`) eingespielt – und nur, wenn jeder Schlüssel darin auf der Whitelist steht. `rueckgaengig.json` im Laufordner markiert einen zurückgenommenen Lauf.

### Boot-Messung

Quelle: `Microsoft-Windows-Diagnostics-Performance/Operational`, Event 100 (`BootTime`, `MainPathBootTime`, `BootPostBootTime`). Das Log ist nur mit Adminrechten lesbar. Windows schreibt den Eintrag erst einige Minuten nach der Anmeldung. Event 101 (Apps), 102 (Treiber) und 103 (Dienste) liefern die Startbremsen. Achtung: Die Verzögerungen überlappen sich und dürfen nicht addiert werden.

---

## 6. Health-Score

Start bei 100, Abzüge (siehe `Get-HealthScore`):

| Bedingung | Abzug |
|---|---|
| Windows-Laufwerk < 10 GB frei oder (< 10 % und < 20 GB) / (< 15 % und < 50 GB) | 20 / 8 |
| Windows-Version ohne Sicherheitsupdates (`WindowsSupportEnd`) | 20 |
| Windows Update abgeschaltet / seit > 40 Tagen keine Updates | 15 / 10 |
| Start Ø5 > 90 s / > 60 s / > 40 s | 15 / 10 / 5 |
| aktive Autostarts > 15 / > 10 | 10 / 5 |
| verwaiste Autostarts | je 1, max. 5 |
| Fehler in System- und Anwendungslog (7 Tage) > 200 / > 50 | 5 / 3 |
| alte Treiberpakete > 10 | 3 |
| Geistergeräte > 50 | 2 |
| Secure Boot aus | 8 |
| Defender-Echtzeitschutz aus **und** kein anderer Virenschutz aktiv | 15 |
| PowerShell-Richtlinie Unrestricted/Bypass | 3 |
| Papierkorb > 5 GB | 2 |
| Warnsignale im Ereignisprotokoll (`Stabilitaet.Warnsignale`; alte Snapshots: EVT-HEALTH-Befunde) | 2 je Art, max. 10 |
| Hardware: kritische Punkte mit `Wertung = dauer` (Laufwerk, Speicherfehler, Akku, stehender Lüfter …) | 5 je Punkt, max. 10 |
| Hardware: Auffälligkeiten mit `Wertung = dauer` | 1 je Punkt, max. 3 |

Momentaufnahmen (aktuelle Temperatur, aktuelle Drosselung, Ereignis 37) zählen bewusst nicht: Sie hängen davon ab, was der PC gerade tut, und würden Vorher/Nachher verfälschen.

Wichtig: Alles, was in den Score eingeht, misst der Snapshot **selbst**. Bis 1.1.1 kamen die Warnsignale aus den Befunden des Scans; der Snapshot „vorher“ einer Optimierung hatte keine Befunde und bekam deshalb einen zu guten Wert (87 → 83 nach einer Optimierung, obwohl sich nichts verschlechtert hatte).

Gewichte bei Bedarf anpassen. Der Score ist ein Gesprächseinstieg und keine absolute Wahrheit. Die Abzüge stehen deshalb immer im Bericht.

---

## 7. Tests

```powershell
pwsh ./tests/Test-Parse.ps1     # Syntax + eindeutige Regel-IDs (Exitcode = Anzahl Fehler)
pwsh ./tests/Test-Report.ps1    # baut Bericht aus Testdaten im Temp-Ordner (prüft auch den Hardware-Abschnitt)
pwsh ./tests/Test-Hardware.ps1  # Szenarien für Kühlung/Lüfter/GPU/Laufwerke/Akku, Score, Kühlungstest
pwsh ./tests/Test-GuiApi.ps1    # App-Schnittstelle: Befunde, RP-FEHLT, OhneRP, Abbrechen, Akku, Server/Firmen-PC, Restore-Vorschau
```

Alle laufen auch unter Linux/macOS mit PowerShell 7. Funktionen werden über den AST geladen, damit Windows-spezifischer Startcode nicht ausgeführt wird. `Test-Hardware.ps1` ersetzt die Datenquellen (`Get-HwMonitorSensors`, `Get-NvidiaGpus`, `Get-ThermalZones`, `Get-DiskHealth`, `Get-CpuPerfSample` …) durch Funktionen mit künstlichen Werten – neue Hardware-Datenquellen deshalb immer als eigene `Get-*`-Funktion bauen.

**Manuelle Testmatrix vor einem Release** (am besten in einer Windows-VM mit Snapshot):

| Fall | Erwartung |
|---|---|
| Scan ohne Admin | läuft durch, Hinweis auf fehlende Adminrechte, Admin-Regeln übersprungen |
| Scan mit Admin | Startzeiten vorhanden, Bericht öffnet sich |
| Preview | keine Änderungen (Registry-/Task-Vergleich vorher/nachher) |
| Apply interaktiv | Rückfragen je Risikostufe, `s` überspringt Regel, `a` gilt nur für die Regel |
| Apply `-Yes` | nur Niedrig; mit `-IncludeMedium` auch Mittel; nie Hoch |
| Restore | Autostart-Status, Aufgaben und Dienst-Starttypen wieder wie vorher |
| deutsches und englisches Windows | pnputil-, winget- und robocopy-Auswertung funktioniert |
| Hardware ohne Sensorprogramm | Hinweis auf LibreHardwareMonitor, GPU (NVIDIA) und Drosselung werden bewertet |
| Hardware mit LibreHardwareMonitor | CPU-Temperatur und Lüfter erscheinen, Kühlungstest bewertet Lüfterreaktion |
| Kühlungstest abbrechen | Last endet sofort (`finally` → `WtBurn::Stop`), Ergebnis „abgebrochen“ |
| Laptop auf Akku | Kühlungstest verweigert, lange Schritte nicht vorausgewählt/übersprungen |

---

## 8. Erkenntnisse aus dem ersten Einsatz (21.10.2026)

Herkunft des Tools: Assessment und zwei Optimierungsrunden auf dem ersten Test-PC (Ryzen 9 5900X, Windows 11 25H2). Was daraus in die Regeln eingeflossen ist:

- **Eigene „Optimierungs“-Skripte sind oft das Problem:** Prefetch löschen, Papierkorb komplett leeren, Downloads ohne Altersgrenze löschen und `winget upgrade --all --force` bei jeder Anmeldung → Regel `TSK-ANTIPATTERN`.
- **`winget upgrade --all` erzeugt bei manchen Installern Nebeneinander-Versionen** (6× rekordbox) → `APP-SIDEBYSIDE` und `WingetExclude`.
- **Reste vom Vorgänger-PC:** Intel-Chipsatztreiber auf AMD-System, 97 Geistergeräte, Papierkörbe alter SIDs, Images unter altem PC-Namen → `CLN-DRIVERSTORE` (fremde Plattform), `SYS-GHOST`, `CLN-RECYCLE-ORPHAN`.
- **Laufwerksbuchstaben ändern sich:** Autostart auf `G:\` zeigte ins Leere, weil das Laufwerk inzwischen `E:` hieß → `Get-TargetState` unterscheidet `fehlt` und `LaufwerkFehlt`.
- **Startzeit misst man nur mit mehreren Neustarts.** Ein einzelner Start nach der Optimierung war sogar langsamer, weil eine neue App (Mobalytics) dazukam und der erste Start nach DISM noch Arbeit hatte → Bericht zeigt Verlauf und Apply-Markierungen statt eines einzelnen Werts.
- **Die gemessenen Startbremsen (Event 101) sind nicht additiv:** Spotify meldete 14–26 s, der Gewinn war deutlich kleiner.
- **Die großen Hebel sind oft Hardware/BIOS:** Windows auf SATA-SSD, 1-TB-NVMe leer, BIOS von 2022 mit fTPM-Fehlern, Secure Boot aus, RAID-Modus ohne Array → `HW-HINTS`, `SEC-CHECKS`.
- **Lokalisierung:** `vssadmin`/`sfc` geben lokalisierten oder UTF-16-Text aus → CIM (`Win32_ShadowStorage`), `Repair-WindowsImage`, `dism /English`.
- **Set-ExecutionPolicy meldet einen „Fehler“, obwohl gesetzt wurde,** wenn die Prozess-Policy Bypass ist → wird abgefangen.
- **Enable-ComputerRestore setzt das Schattenkopie-Limit zurueck** (bei uns von 15 GB auf 2 %). Darum `Invoke-Checkpoint`: erst Checkpoint versuchen, nur bei Fehler Systemwiederherstellung einschalten.
- **Kommentare in Skripten** loesten in `TSK-ANTIPATTERN` Fehlalarme aus („Prefetch wird NICHT geloescht“) → Kommentare werden vor der Musterpruefung entfernt, Treffer brauchen Loesch-Befehl und Stichwort in derselben Zeile.
- **cleanmgr raeumt den Delivery-Optimization-Cache nicht zuverlaessig** (10,7 GB blieben) → zusaetzlich `Delete-DeliveryOptimizationCache`, alte LiveKernelReports-Dumps (GPU-Watchdog) werden geloescht.
- **„Geschaetzt“ ≠ „gemessen“:** Die App zeigt den tatsaechlichen Zuwachs an freiem Speicher und die Schaetzung nur als Zusatz.
- **Automatische Wartung bricht ab, wenn man am PC arbeitet** (0x8007042B) – das ist normal. `SYS-MAINT` meldet nur noch, wenn sie laenger als 14 Tage nicht lief.
- **Bus-Typ hinter RAID-Treibern ist falsch** (NVMe wird als SATA gemeldet) → `HW-HINTS` erkennt zusaetzlich „groessere, fast leere SSD“ und aktive RAID-Treiber ohne Verbund.
- **WPF-Ressourcen nie mit PowerShell-Huellobjekten fuellen:** `$Win.Resources[$k] = (New-Object …)` speichert ein `PSObject`, WPF wirft dann beim Anzeigen "Unable to cast PSObject to Brush". Immer `.psobject.BaseObject` eintragen.
- **Typografische Anfuehrungszeichen („ “) sind in PowerShell Stringbegrenzer!** In Code-Strings nie verwenden (in XAML unkritisch).
- **Fernsteuerung/Automatisierung kann erhoehte Fenster nicht bedienen** (UIPI). Tests der App mit Adminrechten muessen von Hand geklickt werden.
- **Store-App-Autostarts** (z. B. Spotify) stehen nicht in den Run-Schlüsseln, sondern unter `SystemAppData\<Paket>\<Task>\State` (2/4 = an, 1 = vom Benutzer aus).

---

## 8a. Hardware & Kühlung (seit 1.2)

**Grundsatz:** Lüfterkurven liegen im BIOS/UEFI bzw. im Embedded Controller des Mainboards oder Laptops. Windows hat dafür keine herstellerunabhängige Schnittstelle (`Win32_Fan` ist auf fast allen PCs leer). WinTidy **misst die Wirkung** und ändert an Lüftern und BIOS nichts.

| Quelle | Funktion | Liefert | Hinweise |
|---|---|---|---|
| Kernel-Processor-Power, Ereignis 37 | `Get-ThrottleEventCount` | „Leistung durch Firmware begrenzt“ | laut Intel kein Defekt, aber Hinweis auf Kühlung/Leistungsgrenzen |
| `Win32_PerfFormattedData_Counters_ThermalZoneInformation` | `Get-ThermalZones` | ACPI-Temperatur, `PercentPassiveLimit` (< 100 = Windows bremst wegen Hitze) | meist nur Laptops; Kelvin (HighPrecisionTemperature in 1/10 K) |
| `Win32_PerfFormattedData_Counters_ProcessorInformation` (_Total) | `Get-CpuPerfSample` | `PercentProcessorPerformance` (> 100 = Turbo), `PercentPerformanceLimit` | Basis des Kühlungstests |
| `nvidia-smi --query-gpu=... --format=csv,noheader,nounits` | `Get-NvidiaGpus` / `ConvertFrom-NvidiaCsv` | Temperatur, Lüfter %, Leistung, Takt, Drosselgründe (Bitmaske) | `clocks_event_reasons.active`, Fallback `clocks_throttle_reasons.active`. 0x20/0x40 = Hitze, 0x80 = Power Brake, 0x8 = HW-Slowdown, 0x4 = Leistungsgrenze (normal), 0x1 = Leerlauf |
| LibreHardwareMonitor / OpenHardwareMonitor (`root\LibreHardwareMonitor`, `Sensor`/`Hardware`) | `Get-HwMonitorSensors` | CPU-Temperatur, alle Lüfter (Fan = U/min, Control = %) | nur solange das Programm läuft (bei LHM: WMI-Anbieter aktiv) |
| HWiNFO (`HKCU:\Software\HWiNFO64\VSB`) | `Get-HwMonitorSensors` | Werte mit „Report value in Gadget“ | Label/Value/ValueRaw/Sensor je Index |
| `Get-StorageReliabilityCounter`, `MSStorageDriver_FailurePredictStatus` | `Get-DiskHealth` | Temperatur, Verschleiß (NVMe), SMART-Warnung | hinter RAID-Treibern oft leer; `TemperatureMax` ist uneinheitlich → nicht bewertet |
| `root\wmi BatteryStaticData/BatteryFullChargedCapacity` | `Get-BatteryWear` | Kapazitätsverlust | |
| Energieplan-Registry (`SYSCOOLPOL`) | `Get-PowerSettingIndex` | Kühlrichtlinie AC/DC (0 = passiv, 1 = aktiv) | versteckte Einstellung, `powercfg /query` zeigt sie nicht → Registry: `User\PowerSchemes\<Schema>\<Sub>\<Setting>`, sonst `PowerSettings\...\DefaultPowerSchemeValues\<Schema>` |
| `WmiMonitorListedSupportedSourceModes` (EDID) + `Win32_VideoController` | `HW-DISPLAY` | höchste Bildwiederholrate des Monitors bei aktueller Auflösung | nur bei genau einem Monitor bewertet |

**Bewertung (`Get-HardwarePoints`, Grenzwerte in der Konfiguration, Stand 1.3):**
- CPU im Scan: Median aus 5 Werten, nur bewertet bei Auslastung ≤ 30 %; Desktop ≥ 80 °C warn, ≥ 90 °C krit (Laptop +5). Gemessen wird **vor** den teuren Regeln (DISM, winget), damit die CPU noch ruht. Bevorzugt Tdie, dann Package/Tctl.
- Ereignis 37: Episoden (verschiedene Minuten) statt Ereignisse, warn nur Desktop ≥ 3 in 7 Tagen, sonst Hinweis.
- Thermalzonen: `PercentPassiveLimit` ≤ 80 krit, < 100 warn, Ursache aus `ThrottleReasons` (0x1 Hitze, 0x2 Strom).
- Lüfter: CPU-Lüfter 0 U/min nur bei CPU ≥ 60 °C krit (sonst gewollter Lüfterstopp), Pumpe 0 U/min warn, Volllast-Steuerung ≥ 95 % bei CPU < 55 °C warn – Pumpen/GPU ausgenommen, nur wenn der Lüfter mit gleicher Nummer läuft. Mehrere Lüfter-Tools gleichzeitig warn.
- NVIDIA: `fan.speed` ist ein Sollwert. Krit bei 0x40 oder ≥ Slowdown-Temperatur der Karte; warn im Leerlauf ≥ 70 °C, unter Last ≥ MaxOp − 5 (bzw. Ziel + 3 / 83 °C), Lüfter 0 % bei ≥ 70 °C, 0x8/0x80; 0x20 nur Hinweis. Drosselgründe nur, wenn in 2 von 3 Proben gesetzt. PCIe-Breite < max: ≤ x4 warn, sonst Hinweis.
- Laufwerke: Unhealthy/Predictive Failure/SMART krit, Warning warn, Unknown ignoriert; Temperatur NVMe 70/80, SSD 60/70, HDD 50/60 °C; Verschleiß ≥ 80 % warn, ≥ 100 % krit.
- Speicherdiagnose 1202 (90 Tage) krit; WHEA 19/17 ≥ 5 in 30 Tagen warn. Akku ≥ 30 % warn, ≥ 50 % krit.

**Kühlungstest (`Invoke-CoolingTest`, Stand 1.3):** 3 Ruhewerte → Volllast mit `[WtBurn2]` (C#-Threads mit normaler Priorität auf allen logischen Prozessoren außer einem; EcoQoS per `SetProcessInformation(ProcessPowerThrottling)` für die Dauer abgeschaltet; Watchdog-Deadline im C#-Teil, damit die Last auch endet, wenn PowerShell hängt) und Messung alle 2 s → 3 Werte beim Abkühlen. Sicherheitsabbruch (`GESTOPPT`) bei CPU ≥ TjMax + 3, Thermalzone ≤ 80 % oder getrenntem Netzteil. Bewertung relativ zu `CpuTjMax`: Leistungsabfall ≥ 15/30 % ist nur zusammen mit TjMax − 1 oder einem Drosselsignal ein Kühlungsproblem (warn/krit); TjMax ohne Leistungsabfall ist ein Hinweis („regelt bewusst an der Grenze“). Lüfterreaktion je Lüfter (ohne GPU/Pumpe): ≥ +15 % ok, < +5 % bei +20 K und ≥ 85 °C warn. Vom Benutzer abgebrochene Tests werden nicht gespeichert; `Get-LastCoolingTest` liefert nur OK/GESTOPPT. Gesperrt auf Servern/VMs und im Akkubetrieb.

**Erkenntnisse vom ersten PC (Ryzen 9 5900X, ASRock B550, RTX 4070 Ti):** keine ACPI-Thermalzonen, kein `Win32_Fan`, Laufwerkszähler wegen RAID-Treiber leer, kein Ereignis 37 → ohne LibreHardwareMonitor bleiben GPU (36 °C, Lüfter 0 % im Leerlauf = Zero-RPM) und der Leistungsverlauf im Kühlungstest. Monitor: 84 Hz ist laut EDID das Maximum an diesem Anschluss.

---

## 9. Bekannte Grenzen

- `cleanmgr /sagerun` kann ein kleines Fortschrittsfenster zeigen und auf manchen Builds lange laufen (Timeout 60 Minuten).
- pnputil- und winget-Auswertung: Deutsch und Englisch getestet, andere Sprachen evtl. nicht (Detect liefert dann einfach nichts).
- Die Zuordnung von Startbremsen zu Autostarts erfolgt über den Dateinamen (Heuristik).
- `APP-SIDEBYSIDE` gruppiert über den Namen ohne Versionsnummern und den Herausgeber. Ausnahmen stehen in `SideBySideExclude`.
- `CLN-ORPHANDIR` ist eine Namensheuristik → nur auf ausdrücklichen Wunsch.
- Restore kann Löschungen und Deinstallationen nicht zurückholen (dafür ist der Wiederherstellungspunkt da).
- Lüfterkurven und BIOS-Einstellungen sind nicht lesbar. Desktop-Mainboards melden CPU-Temperatur und Lüfter nur über Zusatzprogramme (LibreHardwareMonitor, HWiNFO). AMD-/Intel-Grafikkarten: nur über diese Programme (kein Gegenstück zu `nvidia-smi` ohne Zusatzsoftware).
- `HW-DISPLAY` bewertet nur bei genau einem Monitor; Monitore, die hohe Raten nur in EDID-Erweiterungsblöcken melden, werden nicht erkannt (kein Fehlalarm, nur kein Hinweis).

---

## 10. Roadmap / Ideen

**Aus dem Review vom 23.10.2026 noch offen** (Details: Abschnitt 12)
- [ ] GPU-Temperatur und echte Lüfterdrehzahl herstellerneutral über `D3DKMTQueryAdapterInfo(KMTQAITYPE_ADAPTERPERFDATA)` (AMD/Intel Arc ohne Zusatzsoftware) – P/Invoke-Struktur auf echter Hardware verifizieren
- [ ] Ryzen X3D mit zwei CCDs: Core-Parking-Voraussetzungen (Chipsatztreiber, Game Bar, Energieplan)
- [ ] `SYS-GHOST` nur Geräte, die ≥ 90 Tage nicht gesehen wurden (`DEVPKEY_Device_LastRemovalDate`), NVMe-PCIe-Anbindung, GPU bleibt im Leerlauf im P0
- [ ] `SYS-TWEAKS` mit Fix (Auslagerungsdatei automatisch, Prefetch/SysMain an) inkl. Undo
- [ ] Autostart über geplante Aufgaben mit Anmelde-Trigger und Dienste von Herstellertools; Score nur ohne geschützte Einträge
- [ ] Fehlerzählung mit Ausschlussliste (DCOM 10016 u. a.) und pro Tag Laufzeit; Score-Deckel pro Kategorie; „Abdeckung“ (Admin/Sensoren) und Vergleichbarkeit vorher/nachher kennzeichnen
- [ ] Bericht „zum Teilen“ (Benutzername/PC-Name/Pfade anonymisieren)
- [ ] App: Banner ausblendbar, Zeitachse im Startzeit-Diagramm, Fokus nach Seitenwechsel, Live-Region für den Fortschritt, „Größere Schrift“, Ergebnis-Kacheln nur bei Änderung, Laien-/Technik-Text getrennt (`Technik`-Feld)
- [ ] Mehr als 64 logische Prozessoren (Prozessorgruppen) im Kühlungstest; Option „gründlich“ (300 s) und SIMD-Last

**Kurzfristig**
- [x] App: Dunkelmodus (1.3.1)
- [ ] App: eigenes Icon (.ico)
- [ ] Hardware: AMD-GPU über ADLX/`amdsmi` (wenn vorhanden), Verlaufsdiagramm des Kühlungstests in App und Bericht, GPU-Last im Kühlungstest
- [ ] App: Empfehlungen nach dem Umsetzen einzeln als „erledigt“ markieren statt neu pruefen zu lassen
- [ ] Pester-Tests für `Resolve-CommandTarget`, `Get-DriverPackages`-Parser, Score und Vergleich
- [ ] `-Mode Schedule`: monatlichen Scan als geplante Aufgabe anlegen (nur Scan, Bericht per Datei)
- [ ] CSV/JSON-Export der Befunde für Mehr-PC-Auswertung
- [ ] Regel: Browser-Caches (nur wenn der Browser nicht läuft; Chrome/Edge/Vivaldi/Brave/Firefox)
- [ ] Regel: WSL-/Docker-VHDX verkleinern (Optimize-VHD bzw. `diskpart compact`), nur mit Hinweis
- [ ] Regel: Steam-Shadercache/Download-Reste, Ubisoft/EA-Patch-Reste ohne installiertes Spiel
- [ ] Regel: OneDrive-Ordnersicherung uneinheitlich (zwei „Dokumente“-Ordner)
- [ ] Regel: PowerShell-Module in Profilen, die zu keiner installierten PowerShell-Version gehören

**Mittelfristig**
- [ ] Aufteilen in Modul (`WinTidy.psm1` + `Rules\*.ps1`), Regeln als einzelne Dateien
- [ ] Mehrsprachigkeit (Texte in `lang\de.psd1`, `lang\en.psd1`)
- [ ] Code-Signierung, damit RemoteSigned/AllSigned ohne `-ExecutionPolicy Bypass` reicht
- [ ] Sammelbericht über mehrere PCs (alle `WinTidy-Daten\*` einlesen)
- [ ] Benchmark-Modus (Disk sequenziell/4K mit `winsat` oder DiskSpd, App-Startzeit-Messung) für Vorher/Nachher jenseits der Bootzeit

**Bewusst nicht geplant:** Registry-Cleaner, Telemetrie-/Datenschutz-„Hardening“-Pakete, Abschalten von Sicherheitsfunktionen, Treiber-Updater aus Drittquellen.

---

## 11. Konventionen

- UI-Texte Deutsch, Code-Bezeichner gemischt (bestehende Namen beibehalten). Reine Konsolen-/Regeltexte ohne Umlaute (ae/oe/ue), damit die Ausgabe bei falscher Codepage lesbar bleibt; Texte, die die App zeigt (Friendly, Hardware-Punkte, Kontext-Meldungen), mit Umlauten. Dateien als **UTF-8 mit BOM** speichern (PowerShell 5.1 liest sonst ANSI).
- Ausgabe nur über `W`/`Section`/`Sub`, nie `Write-Output` in `Detect`.
- Jede neue Regel bekommt eine Begründung (`Warum`), die ein Laie versteht.
- Versionsnummer in `$Script:Version` und `CHANGELOG.md` gemeinsam erhöhen (SemVer: neue Regel = Minor, Fix = Patch, Datenformat-Bruch = Major).

---

## 12. Review vom 23.10.2026 (vier unabhängige Agents)

Geprüft wurden Code/PS-5.1-Kompatibilität, Sicherheit/Schadensrisiko, Bedienbarkeit für Laien und Fachlogik (inkl. Hardware/Kühlung). Die wichtigsten Lehren für künftige Regeln:

- **Vertrauensgrenze Datenordner:** Alles, was später mit Adminrechten eingespielt wird (Sicherungen, Undo-Infos), muss in einem Ordner liegen, den Nicht-Admins nicht beschreiben können – und Restore nimmt nur erwartete Pfade an.
- **`reg import` ist kein Undo:** Es setzt Werte, löscht aber keine neu angelegten. Deshalb Einzelwert-Undo mit Vorher/Nachher.
- **Löschen nie über Verknüpfungen:** Windows PowerShell 5.1 folgt Junctions bei `-Recurse`. Nur die eigenen Lösch-Helfer benutzen.
- **Fail-closed:** Lässt sich etwas nicht feststellen (Profilliste, Betriebssystem, Alter von Windows.old), wird nichts angeboten bzw. gesperrt.
- **Herstellerwerte statt fester Grenzen:** TjMax je CPU-Familie, Grenzwerte der Grafikkarte aus `nvidia-smi -q`. Viele aktuelle CPUs/GPUs regeln absichtlich an ihrer Grenze.
- **Sollwert ≠ Messwert:** `fan.speed` von NVIDIA ist die gewünschte Drehzahl. Lüfterstopp im Leerlauf ist gewollt.
- **„Unknown“ ist keine Warnung:** Unbekannter Zustand wird nicht bewertet.
- **Momentaufnahmen nicht in den Score:** Sie machen Vorher/Nachher unvergleichbar.
- **Laien sehen jeden Text:** Fortschritt ohne Aktionsverben, keine Registry-Pfade oder Paketnamen, keine gefährlichen BIOS-Ratschläge ohne Warnhinweis, Endgültiges nicht vorauswählen.
- **Tests ersetzen Datenquellen:** Jede neue Quelle als eigene `Get-*`-Funktion, damit `Test-Hardware.ps1`/`Test-GuiApi.ps1` sie mocken können.
