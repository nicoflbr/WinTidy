# Changelog

## 1.3.4 – 2026-10-23
- Fix: Die gewählte Darstellung (Hell/Dunkel/Wie Windows) wurde nie gespeichert. Im Dateinamen stand durch einen Tippfehler ein unsichtbares Steuerzeichen (`\a`); Windows lehnte den Pfad ab. `Test-Parse.ps1` meldet Steuerzeichen jetzt.
- Dunkler Modus: Der ausgewählte Menüpunkt in der Seitenleiste war dunkelblau auf dunkelblau. Eigene Textfarbe `NavSelFg` (hell im dunklen Modus).
- Hardware-Hinweise zeigen eine Glühbirne statt eines Symbols, das wie ein leeres Kontrollkästchen aussah (dort lässt sich nichts auswählen).
- Versionsnummer der Engine auf dem Stand der App (zeigte noch 1.3.2).
- Veröffentlichung auf GitHub vorbereitet: englische `README.md`, Anwenderdoku jetzt in `ANLEITUNG.md`, MIT-Lizenz, `CONTRIBUTING.md`, `SECURITY.md`, Vorlagen für Issues und Pull Requests, automatische Tests (Windows PowerShell 5.1 und PowerShell 7) und ein Release-Workflow, der bei einem Tag `vX.Y.Z` ein fertiges ZIP veröffentlicht.

## 1.3.3 – 2026-10-23
- Fix: App startete nicht („Unable to cast object of type PSObject to type Brush“). `New-Object` liefert in PowerShell ein Hüllobjekt; als Ressource eingetragen kann WPF es nicht als Pinsel verwenden. Jetzt wird das eigentliche Objekt (`.psobject.BaseObject`) eingetragen.

## 1.3.2 – 2026-10-23
- Fix Dunkler Modus: Karten, Seitenleiste und Texte blieben hell, weil WPF von Styles benutzte Pinsel einfriert. Farben werden jetzt als Ressource ersetzt, im Code erzeugte Elemente verweisen per `Set-Brush` (SetResourceReference) auf den Schlüssel.
- Eigene, zum Design passende Kontrollkästchen (inkl. „teilweise ausgewählt“), Auswahlknöpfe für die Darstellung, schmale Bildlaufleisten und Tooltips – hell wie dunkel.

## 1.3.1 – 2026-10-23
- **App: Dunkler Modus.** Einstellungen › Darstellung: „Wie Windows“ (Standard, folgt Personalisierung › Farben auch bei offenem Fenster), „Hell“ oder „Dunkel“. Auch die Titelleiste wird dunkel. Die Wahl wird pro Benutzer in `%APPDATA%\WinTidy\app-einstellungen.json` gespeichert. Bei aktivem Windows-Kontrastdesign gelten weiterhin dessen Farben.
- Farben im dunklen Modus auf Lesbarkeit geprüft (Text ≥ 4,5:1, Rahmen ≥ 3:1); eigene Linkfarbe (`Link`) statt der Akzentfarbe.

## 1.3.0 – 2026-10-23
Ergebnis von vier unabhängigen Prüfungen (Code, Sicherheit, Bedienbarkeit, Fachlogik).

**Sicherheit und Datenschutz**
- Datenordner geschützt unter `%ProgramData%\WinTidy\<PC>` (nur Admins/SYSTEM schreiben), ohne Adminrechte unter `%LOCALAPPDATA%`; alte Daten werden übernommen. Vorher konnten Programme ohne Adminrechte Sicherungen manipulieren, die „Wiederherstellen“ mit Adminrechten einspielte.
- Löschen folgt keinen Verknüpfungen mehr (Junctions/Symlinks/OneDrive-Platzhalter); Schutzliste für Laufwerkswurzel, Windows, Profile, Programme. Alter = Änderungs- **und** Erstellungsdatum.
- `C:\Temp` nicht mehr fest eingetragen (nur noch über `ExtraTempPaths`).
- `CLN-WINOLD`: warnt bei persönlichen Dateien in `Windows.old\Users` und wählt dann nichts vor; Vorauswahl nur bei bekanntem Alter ≥ 10 Tage; die Dateien für „Diesen PC zurücksetzen“ bleiben.
- Server-/Firmen-PC-Sperre auch in der Kommandozeile; Erkennung fail-closed und zusätzlich Entra-Join und ConfigMgr.
- Restore: Einzelwert-Undo (Vorher/Nachher) statt `reg import` ganzer Schlüssel, überschreibt keine seitdem geänderten Werte, nur Whitelist-Pfade; Aufgaben werden wieder eingeschaltet statt aus XML neu registriert; eindeutige Lauf-IDs.
- Konfiguration wird geprüft (Mindestalter, keine Systemkomponenten in `BloatApps`, Schattenkopie-Ziel ≥ 3 %); Tabellen werden pro Unterschlüssel zusammengeführt.
- Mit Adminrechten: `PSModulePath` nur Systemordner, `winget` nur aus dem App-Installer-Paket, Deinstallationsbefehle nur aus HKLM; Berichte werden über den Explorer geöffnet (kein Browser mit Adminrechten); HTML-Werte konsequent maskiert.
- `cleanmgr`: liegengebliebene Kategorie-Flags werden vorher entfernt; `SystemRestorePointCreationFrequency` wird wiederhergestellt statt gelöscht.
- Netzwerkpfade (NAS/VPN) gelten nie als „verwaist“; `\??\`-Dienstpfade werden korrekt geprüft.
- Kühlungstest mit Watchdog im C#-Teil, Abbruch bei Übertemperatur/Hitzedrosselung/Netzteil gezogen, Timeouts für alle Messungen, gesperrt auf Servern und in VMs.
- Vorauswahl in der App: nur noch Endgültiges, das wirklich sicher ist. Nicht mehr vorausgewählt: Papierkörbe alter Konten, alte Treiber, Store-Apps, Programm-Updates, Geistergeräte; Autostarts nur noch aus `HeavyStartup`. `ProtectedStartup` deutlich erweitert (Virenschutz, VPN, Backup, Cloud, Eingabegeräte), Abgleich auch über Hersteller/Beschreibung der Datei.

**Fachlogik / Fehlalarme**
- Laufwerkszustand „Unknown“ ist kein Alarm mehr; Warning = warn, Unhealthy/Predictive Failure = krit. SMART-Vorhersage wird jetzt wirklich zugeordnet (vorher Präzedenzfehler).
- CPU-Temperatur relativ zur Temperaturgrenze der CPU-Familie (`CpuTjMax`); Scan-Temperatur als Median und nur bei Leerlauf bewertet; Tdie vor Tctl.
- Ereignis 37 als Episoden gezählt, Warnung nur Desktop ≥ 3 in 7 Tagen, sonst Hinweis.
- NVIDIA: Lüfterwert als Sollwert gedeutet, 0x20 (regelt an der Temperaturgrenze) ist normal, Drosselgründe nur bei 2 von 3 Proben, Grenzwerte der Karte aus `nvidia-smi -q`, Leerlauf-/Lastunterscheidung, PCIe-Anbindung.
- Lüfter: Lüfterstopp im Leerlauf ist kein Defekt, Pumpen auf 100 % sind normal, Pumpe 0 U/min nur Warnung, Volllast nur bei passendem laufendem Lüfter. Lüfterreaktion im Test je Lüfter (ohne GPU/Pumpe).
- Kühlungstest: EcoQoS für die Messung abgeschaltet, normale Thread-Priorität, Firmware-Leistungslimit ausgewertet, abgebrochene Tests werden nicht gespeichert.
- `HW-COOLPOLICY` nur bei ACPI-Aktivkühlung, keine automatische Vorauswahl mehr; `/setactive` nur für den noch aktiven Plan.
- `SYS-TRIM` nur bei echtem Problem (TRIM abgeschaltet oder > 14 Tage nicht gelaufen) statt Dauerbefund; `SYS-MAINT` erkennt abgeschaltete Laufwerkspflege.
- `CLN-WINSXS`-Analyse höchstens alle 7 Tage, nicht bei ausstehendem Neustart. `CLN-DRIVERSTORE` bietet keine Pakete an, die irgendein (auch abgestecktes) Gerät nutzt. `SEC-CHECKS` berücksichtigt fremden Virenschutz/Firewall und Legacy-BIOS.
- Laptop-Erkennung über `PCSystemType`/Gehäuse (USV zählt nicht als Akku), Akkubetrieb über `BatteryStatus.PowerOnline`.
- Gesundheitswert: Momentaufnahmen zählen nicht, freier Speicher mit absoluter Untergrenze, Fehlerzahl max. −5, neu: Windows ohne Support −20, Updates > 40 Tage −10, Windows Update aus −15.

**Neue Prüfungen**
- Hardware: nur ein RAM-Riegel, Monitor am Mainboard, Grafikkarte zu schmal angebunden, fehlender Grafiktreiber, Geräte mit Fehlercode, Energieplan begrenzt Prozessor/Turbo aus/Minimum 100 %, Intel 13./14. Gen mit Microcode < 0x12F, LAN nur 100 Mbit/s, mehrere Lüfter-Tools, Tuning-Programme, Speicherdiagnose-Fehler, WHEA 19/17, lange Laufzeit trotz Schnellstart.
- Sicherheit: Windows ohne Support/bald ohne Support, keine Updates seit > 40 Tagen, Windows Update abgeschaltet, Secure-Boot-Zertifikate 2023.
- `SYS-TWEAKS`: Auslagerungsdatei aus, Prefetch aus, SysMain aus, Defender per Richtlinie aus.
- `CLN-HIBERFIL`: Ruhezustandsdatei auf Desktops verkleinern (umkehrbar).

**App**
- Fortschritt zeigt den geprüften Bereich statt Aktionswörter („löschen“); kein „Schritt x von y“ bei Messungen und Kühlungstest.
- Laientexte für fast alle Befunde (Umlaute, keine Registry-Pfade/Paketnamen), Anzeigenamen für Store-Apps und Geräteklassen, entschärfte Hinweise zu Secure Boot/BIOS/Firewall.
- Rotes Banner bei drohendem Datenverlust (Laufwerk/RAM); eigenes Symbol und „Wichtig:“ für kritische Punkte; Ampel bleibt nach Neustart der App erhalten; Hardware-Karte mit Überschriften, Legende und „Was tun?“.
- Kühlungstest: Akku/Server/VM vorab abgefangen, ehrliches Ergebnis, wenn nichts messbar war, Laptop-Hinweis.
- Kein stilles „nichts passiert“ mehr während Hintergrundarbeit; Prüfen-Knopf erst nach dem Laden aktiv; Verlauf lädt nach.
- Wiederherstellungspunkt-Rückfrage mit „Nein“ als Standard; „Nichts umgesetzt“ statt „Fertig!“ bei 0 Änderungen; Übersprungenes getrennt von Fehlern (z. B. „Treiber wird noch benutzt“, „Deinstallation abgebrochen“).
- Verlauf zeigt „rückgängig gemacht am …“; Rückgängig-Vorschau mit verständlichen Namen.
- Gruppe „Windows pflegen“, Kontrast verbessert, Screenreader-Namen für die Navigation, Esc bricht ab, neue Hilfe-Fragen.

**Nachprüfung (fünfter, unabhängiger Agent)**
- Datenordner: Inhalt wird mitgeprüft (Besitzer, Schreibrechte, keine Verknüpfungen) und bei Bedarf zurückgesetzt; ist er nicht sicher, sperrt WinTidy „Wiederherstellen“.
- Restore normalisiert Dateipfade (kein `..`), Registry-Pfade mit `..` werden abgelehnt; Löschen prüft unmittelbar vorher die Pfadkette auf Verknüpfungen.
- `SYS-GAMEDVR` prüft und schaltet nur noch die Hintergrundaufnahme (`HistoricalCaptureEnabled`) – vorher Fehlalarm auf fast jedem PC.
- `CLN-HIBERFIL`: keine Vorauswahl, wenn hybrider Standby oder Ruhezustand per Taste genutzt wird; Hinweis im Text.
- Rotes Laufwerks-Banner nicht bei bloß warmen Laufwerken; Bereich/Wertung im Snapshot, damit es auch nach App-Neustart stimmt.
- Kleinigkeiten: Datenübernahme bei `[ ]` im Pfad, LibreHardwareMonitor-Sensor „Distance to TjMax“ ignoriert, Skript-Richtlinie-Undo erst nach Erfolg, App-Autostarts fail-closed, TRIM-Meldung nur mit SSD, VM-Fehlalarme, Windows-10-Enterprise-Supportende, `-Rule A,B` über WinTidy.cmd, Technik-Text im Expertenmodus.

**Tests**
- `Test-Parse.ps1` prüft zusätzlich UTF-8-BOM, PS7-Operatoren und typografische Anführungszeichen. `Test-Hardware.ps1` und `Test-GuiApi.ps1` stark erweitert (Lüfterstopp, Pumpe, GPU-Gründe, Laufwerkszustände, TjMax, Zahlenformate, Sicherheitsstopp, Abbruch, SKIP, RP-FEHLT mit Computerschutz, Einzelwert-Undo, Whitelist, Lauf-IDs).

## 1.2.0 – 2026-10-23
**Hardware & Kühlung**
- Neue Regel `HW-COOLING`: Prozessor-, Grafikkarten- und Laufwerkstemperaturen, Lüfterdrehzahlen (stehender CPU-Lüfter → kritisch, Volllast bei kühlem Prozessor → Lüfterkurve zu scharf), Drosselung durch Firmware (Ereignis 37) und Hitze (ACPI-Thermalzonen), NVIDIA-Drosselgründe über `nvidia-smi`, SSD-Verschleiß, SMART-Warnung, Laufwerkszustand, Akku-Verschleiß. Jeder Punkt mit Stufe ok/warn/krit.
- Sensoren aus LibreHardwareMonitor/OpenHardwareMonitor (WMI) oder HWiNFO (Gadget-Registry) werden automatisch mitgelesen, wenn eines davon läuft.
- **Kühlungstest** (App: „Kühlung testen“, CLI: `-Mode Hardware -CoolingTest [-Seconds n]`, Menü [9]): Volllast auf allen Kernen mit niedriger Priorität, bewertet Leistungsabfall (nur zusammen mit Hitze/Drosselung als Problem), Höchsttemperatur und Lüfterreaktion; Messreihe unter `kuehltest\`. Abbrechbar, nicht im Akkubetrieb.
- Neue Regel `HW-COOLPOLICY` (Mittel): Kühlrichtlinie im Netzbetrieb von „Passiv“ auf „Aktiv“ (nur mit ACPI-Thermalzonen); rückgängig über Wiederherstellen.
- Neue Regel `HW-DISPLAY`: Bildwiederholrate unter dem, was der Monitor laut EDID kann.
- Snapshot: neue Abschnitte `Hardware` und `Stabilitaet`; Bericht: Abschnitt „Hardware & Kühlung“ inkl. letztem Kühlungstest; Vergleich: Warnsignale und Hardware-Auffälligkeiten.
- Score: kritische Hardware-Befunde −5 (max. −10), Auffälligkeiten −1 (max. −3).

**Engine**
- `CLN-WINOLD` (neu, Mittel, endgültig): vorherige Windows-Version getrennt von `CLN-WINCLEAN`, vorausgewählt erst nach `WinOldMinAgeDays` (10) Tagen. `CLN-WINCLEAN` fasst Windows.old nicht mehr an.
- Fix: Score „vorher“ war zu hoch, weil Warnsignale nur aus den Befunden kamen – jetzt misst jeder Snapshot sie selbst (`Stabilitaet.Warnsignale`).
- Defender-Abzug nur, wenn kein anderer Virenschutz aktiv ist (`Sicherheit.AndererVirenschutz`).
- Geistergeräte: „Microsoft VHD Loopback Controller“ und andere virtuelle Microsoft-Geräte ausgenommen.
- `Get-WtContext`: Server, Firmen-PC (Domäne/Intune), anderes Konto, Neustart ausstehend, Akku. Firmen-PCs sehen nur sichere Aufräumpunkte; auf Servern sind Änderungen gesperrt.
- `Invoke-FixSelection`: Wiederherstellungspunkt **vor** jeder Änderung (bei Fehlschlag Status `RP-FEHLT`, nichts geändert), Abbrechen zwischen Schritten, Details pro Schritt, lange Schritte im Akkubetrieb übersprungen, meldet eingeschalteten Computerschutz.
- `Invoke-Restore` liefert ein Ergebnis (wiederhergestellt/Fehler/Details), neu `Get-RestorePreview`, `Get-HistoryLight`; Läufe kennen die Zahl umkehrbarer Änderungen.
- Regeln können `Dauer`, `Endgueltig`, `Einzeln`, `Umkehrbar` angeben (für die App).
- Konfiguration: `WinTidy.config.json` enthält nur noch eigene Abweichungen; alle Standardwerte in `WinTidy.config.beispiel.json`. Vorher überdeckte die mitgelieferte Vollkopie neue Standardwerte.

**App**
- Hardware-Karte mit Ampel je Messpunkt und Knopf „Kühlung testen“.
- Hinweisbanner (ohne Adminrechte, Server, Firmen-PC, anderes Konto, Neustart ausstehend, Akku), Abbrechen-Knopf, Fehlerseite statt Absturz, Hilfe-Seite mit FAQ, hoher Kontrast, „Warum nicht 100?“ zum Score, Ergebnis mit Details je Schritt, Rückfrage bei fehlendem Wiederherstellungspunkt, nur eine App-Instanz gleichzeitig.

**Tests**
- Neu `tests/Test-Hardware.ps1`: Bewertung von Sensoren, GPU, Laufwerken, Akku, Score und Kühlungstest mit künstlichen Messwerten (plattformunabhängig). `Test-Report.ps1` prüft den Hardware-Abschnitt im Bericht. Neu `tests/Test-GuiApi.ps1`: Schnittstelle zur App (Wiederherstellungspunkt-Fehler, Abbrechen, Akku, Server/Firmen-PC, Restore-Vorschau).

## 1.1.1 – 2026-10-21
- Geistergeräte: virtuelle Systemadapter (WAN Miniport, Hyper-V, Bluetooth u. a.) und Software-Geräte (`SWD\`, `ROOT\`) werden nicht mehr angeboten (neu: `GhostDeviceExclude`)
- WinSxS: kein erneuter Vorschlag, wenn die Bereinigung in den letzten 14 Tagen lief (DISM meldet sonst dauerhaft „empfohlen“); keine irreführende Platzschätzung mehr
- Fix: „Illegal characters in path“ bei ungewöhnlichen Autostart-Befehlszeilen

## 1.1.0 – 2026-10-21
- **Neu: WinTidy App** (`WinTidy-App.ps1`, Start über `WinTidy App.cmd`): grafische Oberfläche für Nicht-ITler mit Übersicht (Gesundheitswert, Kennzahlen, Hinweise), Empfehlungen mit Ampel und Vorauswahl, Fortschrittsanzeige mit Protokoll, Ergebnis mit gemessenem Vorher/Nachher, Verlauf mit Startzeit-Diagramm, Einstellungen (Rückgängig, Desktop-Verknüpfung, Expertenmodus, gründliche Prüfung)
- Engine als Bibliothek ladbar, GUI-API (`Invoke-GuiScan`, `Invoke-FixSelection`, `Get-HistoryData`, `Invoke-GuiRestore`), verständliche Texte für alle Regeln
- Fix: `-RunId` für Restore wurde durch die Lauf-ID überschrieben
- Fix: Wiederherstellungspunkt setzt das Schattenkopie-Limit nicht mehr zurück
- Fix: `TSK-ANTIPATTERN` ignoriert Kommentare (keine Fehlalarme mehr bei erklärenden Hinweisen)
- `CLN-WINCLEAN` leert zusätzlich Delivery-Optimization-Cache und alte LiveKernelReports
- `SYS-MAINT` meldet nur noch echte Wartungslücken (> 14 Tage)
- `HW-HINTS`: erkennt größere, kaum genutzte SSDs auch hinter RAID-Treibern und aktive RAID-Treiber ohne Verbund

## 1.0.0 – 2026-10-21
Erste Version, entstanden aus Assessment und zwei Optimierungsrunden auf dem ersten Test-PC.

- Modi: Menu, Scan, Preview, Apply, Compare, Report, Restore, Rules
- 28 Regeln in 9 Bereichen (Speicher, Autostart, Aufgaben, Dienste, Programme, System, Sicherheit, Hardware, Stabilität)
- Snapshots als JSON, Aktionslog als JSONL, Registry- und Aufgaben-Sicherungen pro Lauf
- Health-Score mit nachvollziehbaren Abzügen
- HTML-Bericht: Score, Startzeit-Verlauf mit Apply-Markierungen, Vorher/Nachher, Befunde, Startbremsen, Autostart, Laufwerke, Aufräumbilanz, Aktionsprotokoll, Snapshot-Verlauf
- Risikostufen Niedrig/Mittel/Hoch/Info mit `-Yes` / `-IncludeMedium`
- Wiederherstellungspunkt vor jedem Apply (24-h-Sperre wird kurz aufgehoben)
- Tests: Syntax/Regel-IDs, Bericht aus Testdaten (plattformunabhängig)
