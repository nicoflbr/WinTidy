# WinTidy – Anleitung

Evidenzbasierte Bereinigung und Optimierung für Windows 10/11 – mit Messung vorher, Rückfragen beim Ändern und belegtem Ergebnis nachher.

WinTidy ist ein einzelnes PowerShell-Skript ohne Installation und ohne Abhängigkeiten. Es läuft mit der eingebauten Windows PowerShell 5.1 und funktioniert auf jedem PC, weil es nur mit allgemeinen Regeln arbeitet und keine festen Pfade oder Programme kennt.

## Herunterladen

Neueste Version unter **Releases** herunterladen (oder **Code → Download ZIP**). Windows markiert heruntergeladene Dateien als „aus dem Internet“. Damit beim Start keine Sicherheitsabfragen kommen, vor dem Entpacken: Rechtsklick auf die ZIP-Datei → **Eigenschaften** → **Zulassen** anhaken. Alternativ im entpackten Ordner in PowerShell: `Get-ChildItem -Recurse | Unblock-File`.

## Die App (für alle)

`WinTidy App.cmd` doppelklicken → Windows-Abfrage mit **Ja** bestätigen → Fenster öffnet sich.

1. **Übersicht → „Jetzt prüfen“**: misst den PC, zeigt einen Gesundheitswert (0–100) und die wichtigsten Kennzahlen. Es wird nichts verändert.
2. **Empfehlungen**: jede Verbesserung in verständlichen Worten, mit Ampel („Sicher“, „Kurz prüfen“, „Nur für Profis“). Die sicheren Punkte sind schon angehakt. Unter „Details“ lassen sich einzelne Einträge abwählen.
3. **„Ausgewählte umsetzen“**: legt einen Wiederherstellungspunkt an, setzt um und zeigt danach Vorher/Nachher.
4. **Hardware** (Übersicht, „Für Fachleute“): Kühlung, Lüfter, Temperaturen von Prozessor, Grafikkarte und Laufwerken, Drosselung, Akku-Verschleiß und Bildwiederholrate. Mit **„Kühlung testen“** belastet WinTidy den Prozessor etwa eine Minute und prüft, ob die Kühlung mithält.
5. **Verlauf**: Startzeit-Diagramm über alle Neustarts, alle Prüfungen und Optimierungen.
6. **Einstellungen**: Darstellung (wie Windows, hell oder dunkel), Rückgängig machen, Desktop-Verknüpfung anlegen, gründliche Prüfung, Expertenmodus.

Die App nutzt dieselbe Logik und dieselben Daten wie die Kommandozeile – beide lassen sich abwechselnd verwenden.

## Kommandozeile (für Profis)

1. Ordner `WinTidy` irgendwohin kopieren (auch USB-Stick).
2. `WinTidy.cmd` doppelklicken → Adminrechte bestätigen → Menü.
3. **[1] Scan** → misst, prüft alle Regeln, öffnet den HTML-Bericht. Ändert nichts.
4. **[3] Anwenden** → Wiederherstellungspunkt, dann jede Regel mit Rückfrage.
5. PC 2–3 Mal normal neu starten, dann erneut **[1] Scan** → der Bericht zeigt Vorher/Nachher inkl. Startzeit-Verlauf.

## Modi

| Modus | Was passiert | Ändert etwas? |
|---|---|---|
| `Scan` | Snapshot + alle Regeln prüfen + Bericht | nein |
| `Preview` | zeigt, was `Apply` tun würde | nein |
| `Apply` | Snapshot vorher → Wiederherstellungspunkt → Regeln mit Rückfragen → Snapshot nachher → Vergleich → Bericht | ja |
| `Compare` | vergleicht zwei Snapshots in der Konsole | nein |
| `Report` | baut den HTML-Bericht aus allen gespeicherten Daten neu | nein |
| `Restore` | spielt gesicherte Registry-Schlüssel, Aufgaben und Dienst-Starttypen eines Laufs zurück | ja |
| `Rules` | listet alle Regeln mit Risiko | nein |
| `Hardware` | Kühlung, Lüfter, Temperaturen, Laufwerke, Akku; mit `-CoolingTest [-Seconds 90]` zusätzlich Kühlungstest unter Last | nein |

Beispiele:

```powershell
.\WinTidy.ps1 -Mode Scan -OpenReport
.\WinTidy.ps1 -Mode Scan -Deep                 # zusätzlich SFC-Angebot und Dateisystem-Scan
.\WinTidy.ps1 -Mode Apply                      # interaktiv
.\WinTidy.ps1 -Mode Apply -Yes                 # unbeaufsichtigt: nur Risiko "Niedrig"
.\WinTidy.ps1 -Mode Apply -Yes -IncludeMedium  # unbeaufsichtigt inkl. "Mittel"
.\WinTidy.ps1 -Mode Apply -Rule STA-HEAVY,APP-BLOAT
.\WinTidy.ps1 -Mode Apply -ExcludeRule APP-UPDATES
.\WinTidy.ps1 -Mode Compare -From 20261021 -To 20261024
.\WinTidy.ps1 -Mode Restore -RunId 20261021-183100
.\WinTidy.ps1 -Mode Hardware -CoolingTest      # Kühlung prüfen, 60 s Volllast
```

## Risikostufen

| Stufe | Bedeutung | Rückfrage | mit `-Yes` |
|---|---|---|---|
| Niedrig | sicher und umkehrbar bzw. reiner Cache | einmal pro Regel | wird ausgeführt |
| Mittel | sinnvoll, aber Geschmackssache oder nicht umkehrbar (z. B. Deinstallation) | pro Objekt | nur mit `-IncludeMedium` |
| Hoch | Heuristik mit möglichen Fehltreffern | immer pro Objekt | nie |
| Info | nur Bericht/Hinweis | – | – |

Bei Rückfragen: `j` ja · `n` nein · `a` alle dieser Regel · `s` Regel überspringen.

## Regeln (Auszug)

`.\WinTidy.ps1 -Mode Rules` zeigt die vollständige Liste.

- **Speicher:** Temp-Dateien (nach Alter), Windows-Datenträgerbereinigung (Update-Reste, Fehlerberichte …), vorherige Windows-Version (Windows.old, eigene Regel, erst nach 10 Tagen vorausgewählt), WinSxS-Bereinigung, Absturzabbilder, alte Papierkorb-Einträge, Papierkörbe gelöschter Konten, alte Treiberpakete, *(optional)* verwaiste Programmordner
- **Autostart:** Einträge mit fehlender Datei, verwaiste Statuswerte, aktive Autostarts sortiert nach **gemessener** Startverzögerung
- **Aufgaben/Dienste:** Aufgaben und Dienste mit fehlender Programmdatei, schädliche Muster in eigenen Wartungsskripten (Prefetch löschen, Papierkorb komplett leeren, `winget --all` bei jeder Anmeldung …)
- **Programme:** mehrfach installierte Versionen, Bloatware-Store-Apps, veraltete Programme (winget)
- **System:** Geistergeräte, Speicher für Wiederherstellungspunkte, SSD-TRIM, abgebrochene Wartung, Systemintegrität (DISM/SFC), Game-Bar-Hintergrundaufnahme
- **Hardware & Kühlung:** Prozessor- und Grafikkarten-Temperatur, Lüfterdrehzahlen (stehender CPU-Lüfter, Volllast bei kühlem PC, Pumpe), Drosselung durch Hitze oder Firmware, mehrere Lüfter-Tools gleichzeitig, Laufwerkszustand/-temperatur/-verschleiß, SMART-Warnungen, Speicherdiagnose- und WHEA-Fehler, Akku-Verschleiß, Kühlrichtlinie, Bildwiederholrate
- **Hardware-Konfiguration:** nur ein RAM-Riegel, RAM-Takt (XMP/EXPO), Monitor am Mainboard statt an der Grafikkarte, Grafikkarte mit zu schmaler PCIe-Anbindung, fehlender Grafiktreiber, Geräte mit Fehlercode, Energieplan begrenzt den Prozessor/Turbo aus, Intel 13./14. Gen mit altem Microcode, LAN nur 100 Mbit/s, Systemplatte vs. freie NVMe
- **Sicherheit/Stabilität:** Windows ohne Support oder ohne Updates, Secure Boot und neue Secure-Boot-Zertifikate, Virenschutz (auch Fremdprodukte), Firewall, UAC, BIOS-Alter, PowerShell-Richtlinie, ungünstige Tuning-Einstellungen (Auslagerungsdatei aus, Prefetch/SysMain aus, Defender per Richtlinie aus), Warnmeldungen im Ereignisprotokoll
- **Speicher (neu in 1.3):** Ruhezustandsdatei auf Desktop-PCs verkleinern (Schnellstart bleibt)

## Kühlung und Lüfter – was geht und was nicht

Lüfterkurven stehen im BIOS bzw. in der Firmware des Mainboards (oder in Hersteller-Tools) und sind für Windows weder lesbar noch einstellbar. WinTidy misst deshalb die **Wirkung**:

- **Ohne Zusatzprogramm:** Drosselung durch die Firmware (Ereignis 37), ACPI-Thermalzonen (vor allem Laptops), NVIDIA-Grafikkarte über `nvidia-smi` (Temperatur, Lüfter, Drosselgründe), Laufwerkstemperatur und -verschleiß, Akku-Kapazität.
- **Mit [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) (ab 0.9.5, ältere Versionen nutzen den von Defender gemeldeten Treiber WinRing0) oder HWiNFO** (läuft im Hintergrund): zusätzlich Prozessor-Temperatur und alle Lüfterdrehzahlen. WinTidy erkennt das automatisch.
- **Kühlungstest:** belastet alle Kerne bis auf einen kurz voll und bewertet, ob die Leistung wegen Hitze einbricht, ob der Prozessor seine Temperaturgrenze (TjMax je CPU-Familie, z. B. Ryzen 7000/9000 = 95 °C) erreicht und ob die Lüfter hochdrehen. Ein Leistungsabfall nach der Turbo-Phase ohne Hitze gilt als normal (Herstellerlimit). Bricht von selbst ab bei Übertemperatur, starker Hitzedrosselung oder wenn das Netzteil gezogen wird. Läuft nicht im Akkubetrieb, auf Servern und in VMs.
- **Was bewertet wird:** Momentaufnahmen (aktuelle Temperaturen, Drosselung) erscheinen als Hinweis, zählen aber nicht im Gesundheitswert; Dauerzustände (Laufwerk, Speicherfehler, Akku) schon. Der Lüfterwert von NVIDIA ist ein Sollwert – 0 % bei kühler Karte ist der gewollte Lüfterstopp.

## Was WinTidy bewusst **nicht** tut

- keine Registry-„Cleaner“, keine „Tweaks“ ohne Wirkungsnachweis
- keine Lüfter- oder BIOS-Einstellungen (dafür gibt es keinen herstellerunabhängigen, sicheren Weg)
- Defender, Updates, UAC, Firewall usw. werden nie abgeschaltet
- keine Treiber mit `/force` entfernen, keine Dateien in Dokumenten/Bildern/Desktop anfassen
- nichts, was auf einem gerade nicht angeschlossenen Laufwerk liegt, gilt als „verwaist“

## Daten, Logs, Bericht

Mit Adminrechten liegt alles geschützt unter `%ProgramData%\WinTidy\<COMPUTERNAME>\` (nur Administratoren und SYSTEM dürfen dort schreiben – Programme ohne Adminrechte können die Sicherungen, die „Wiederherstellen“ einspielt, nicht verändern). Ohne Adminrechte unter `%LOCALAPPDATA%\WinTidy\<COMPUTERNAME>\`. Daten älterer Versionen (`WinTidy-Daten` neben dem Skript) werden beim ersten Start einmalig übernommen. Änderbar mit `-DataPath`.

```
%ProgramData%\WinTidy\PC-NAME\
  WinTidy-Bericht.html              # Bericht (Score, Startzeit-Verlauf, Vorher/Nachher, Befunde, Aktionsprotokoll)
  snapshots\<zeit>_<scan|vorher|nachher>.json
  kuehltest\<zeit>.json            # Messreihen der Kühlungstests
  runs\<zeit>_<scan|preview|apply|restore|hardware|kuehltest>\
      konsole.txt                   # komplettes Konsolenprotokoll
      actions.jsonl                 # jede Aktion als JSON-Zeile (Zeit, Regel, Objekt, Status, Bytes, Meldung)
      zusammenfassung.json
      backup\*.reg, backup\tasks\   # Sicherungen vor jeder Änderung (ab 1.3 zusätzlich Einzelwerte im actions.jsonl)
```

Tipp für gemeinsam genutzte PCs: den WinTidy-Ordner selbst nach `C:\Program Files\WinTidy` legen, damit auch das Skript nur von Administratoren geändert werden kann.

## Rückgängig machen

1. `Restore` setzt jede geänderte Einstellung einzeln zurück: Autostarts, Run-Einträge, Game-DVR, TRIM, Kühlrichtlinie, Ruhezustandsdatei, Skript-Richtlinie, Dienst-Starttypen (inkl. verzögert), deaktivierte Aufgaben und gelöschte Autostart-Verknüpfungen. Werte, die seitdem jemand anders geändert hat, werden nicht überschrieben. Nur erwartete Registry-Pfade werden angefasst.
2. Für alles andere: Systemwiederherstellung (`rstrui.exe`) → Punkt „WinTidy <Lauf>“.
3. Gelöschte Dateien, deinstallierte Programme und entfernte Store-Apps sind nicht über WinTidy zurückholbar (Store-Apps lassen sich aus dem Store neu installieren).

## Konfiguration

`WinTidy.config.json` enthält nur **eigene Abweichungen** vom Standard (Altersgrenzen, Bloatware-Liste, Autostart-Schwergewichte, winget-Ausnahmen, Temperatur-Grenzwerte …). Alle Schlüssel mit ihren Standardwerten stehen in `WinTidy.config.beispiel.json` (wird nicht geladen). Nicht eingetragene Schlüssel kommen aus dem Skript – so wirken verbesserte Standardwerte nach einem Update automatisch.

## Voraussetzungen

Windows 10 (2004+) oder Windows 11, Windows PowerShell 5.1. Adminrechte für `Apply` und für vollständige Scans; ohne Adminrechte fehlen z. B. die Startzeiten.

Weiterentwicklung: siehe [ENTWICKLUNG.md](ENTWICKLUNG.md).
