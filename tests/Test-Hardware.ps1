# Test-Hardware.ps1 - prueft die Bewertung von Kuehlung, Luefter, Temperaturen, Laufwerken und den Kuehlungstest
# mit kuenstlichen Messwerten. Laeuft ohne Windows (auch mit pwsh unter Linux). Aufruf: pwsh ./tests/Test-Hardware.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-hwtest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TestData | Out-Null

# Funktionen und Konfiguration aus WinTidy.ps1 laden, ohne das Skript auszufuehren
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Friendly|GuiPreselectMedium|AreaNames|AppNames|DeviceClassNames|RestoreKeyAllow|Guid\w+|CoolingTestMin)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:Cfg = $Script:DefaultConfig
$Script:DataDir = $TestData
$Script:Cache = @{}
$Script:CoolingTestMin = 3
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') {
    if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FEHLER $Name  $Detail" -ForegroundColor Red }
}
function Levels($pts, [string]$Bereich) { @($pts | Where-Object { -not $Bereich -or $_.Bereich -eq $Bereich } | ForEach-Object { $_.Stufe }) }

# ---------------------------------------------------------------- Zahlen und nvidia-smi
Check 'ConvertTo-WtNumber 41.85' ((ConvertTo-WtNumber ' 41.85') -eq 41.85)
Check 'ConvertTo-WtNumber [N/A]' ($null -eq (ConvertTo-WtNumber '[N/A]'))
$g = @(ConvertFrom-NvidiaCsv @('NVIDIA GeForce RTX 4070 Ti, 36, 0, 41.85, 285.00, 2610, 3105, 0x0000000000000001'))
Check 'nvidia-smi CSV: Name/Temp/Luefter/Maske' ($g.Count -eq 1 -and $g[0].TempC -eq 36 -and $g[0].LuefterProzent -eq 0 -and $g[0].Gruende -eq 1 -and $g[0].TaktMaxMHz -eq 3105)
$g2 = @(ConvertFrom-NvidiaCsv @('Quadro, 91, [N/A], 100, 120, 1200, 1800, 0x0000000000000040'))
Check 'nvidia-smi CSV: N/A-Luefter, Hitzegrund' ($null -eq $g2[0].LuefterProzent -and ($g2[0].Gruende -band 0x40))

# ---------------------------------------------------------------- Szenario-Bausteine (ueberschreiben die Datenquellen)
$Script:Mock = @{}
function Get-HwMonitorSensors([switch]$NoCache) { @($Script:Mock.Sensors | Where-Object { $_ }) }
function Get-NvidiaGpus { @($Script:Mock.Gpus | Where-Object { $_ }) }
function Get-ThermalZones { @($Script:Mock.Zones | Where-Object { $_ }) }
function Get-ThrottleEventCount([int]$Days = 30, [datetime]$Since = [datetime]::MinValue) { if ($Since -gt [datetime]::MinValue) { [int]$Script:Mock.Neu37 } else { [int]$Script:Mock.Ev37 } }
function Get-DiskHealth { @($Script:Mock.Disks | Where-Object { $_ }) }
function Get-ChassisInfo { [pscustomobject]@{ Laptop = [bool]$Script:Mock.Laptop; Akku = [bool]$Script:Mock.Akku; HatAkku = [bool]$Script:Mock.HatAkku; Typen = @(); VM = [bool]$Script:Mock.VM; CpuName = [string]$Script:Mock.Cpu } }
function Get-WtContext { [pscustomobject]@{ Server = [bool]$Script:Mock.Server; Verwaltet = $false; Akku = [bool]$Script:Mock.Akku } }
function Get-EventCount([hashtable]$Filter) { if ($Filter.Id -eq 1202) { [int]$Script:Mock.MemDiag } elseif ($Filter.Id -eq 19) { [int]$Script:Mock.Whea19 } else { 0 } }
function Get-FanToolPoints { @() }
function Get-BatteryWear { $Script:Mock.Wear }
function S($Name, $Typ, $Wert, $GTyp = 'Motherboard') { [pscustomobject]@{ Quelle = 'LibreHardwareMonitor'; Name = $Name; Typ = $Typ; Wert = [double]$Wert; Geraet = 'Board'; GeraeteTyp = $GTyp } }
function Gpu($T, $F, $M = 1, $U = 50, $W = $null) { [pscustomobject]@{ Name = 'RTX'; TempC = $T; LuefterProzent = $F; LeistungW = 40; LimitW = 285; TaktMHz = 2600; TaktMaxMHz = 3100; Auslastung = $U; PcieBreite = $W; PcieBreiteMax = $(if ($W) { 16 } else { $null }); Gruende = [int64]$M; GruendeStabil = [int64]$M; SlowdownC = $null; MaxOpC = $null; ZielC = $null } }
function Disk($Name, $Art, $T, $Wear = $null, $Zustand = 'Healthy') { [pscustomobject]@{ Name = $Name; Art = $Art; Bus = ''; Zustand = $Zustand; TempC = $T; Verschleiss = $Wear; Betriebsstunden = 100; Ausfallwarnung = $false } }
function Run([hashtable]$m) { $Script:Mock = $m; $Script:Cache = @{}; @(Get-HardwarePoints) }

# 1) Erster Test-PC: keine Mainboard-Sensoren, GPU im Leerlauf mit stehendem Luefter, keine Drosselung
$p = Run @{ Gpus = @(Gpu 36 0 1); Disks = @(Disk 'Samsung SSD' 'SSD' $null) }
Check 'Ohne Sensoren: Hinweis auf LibreHardwareMonitor' (@($p | Where-Object { $_.Bereich -eq 'Lüfter' -and $_.Text -match 'LibreHardwareMonitor' }).Count -eq 1) ($p | ConvertTo-Json -Depth 4)
Check 'GPU 36 Grad, Luefter 0 % = ok (Zero-RPM)' ((Levels $p 'Grafikkarte') -contains 'ok' -and -not ((Levels $p 'Grafikkarte') -match 'warn|krit'))
Check 'Keine Drosselung = ok' ((Levels $p 'CPU') -contains 'ok')
Check 'Keine warn/krit insgesamt' (-not ((Levels $p) -match 'warn|krit')) ((Levels $p) -join ',')

# 2) CPU-Luefter steht
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 65 'Cpu'), (S 'CPU Fan' 'Fan' 0), (S 'System Fan #1' 'Fan' 800)) }
Check 'CPU-Luefter 0 U/min bei 65 Grad = krit' ((Levels $p 'Lüfter') -contains 'krit')
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 42 'Cpu'), (S 'CPU Fan' 'Fan' 0), (S 'System Fan #1' 'Fan' 800)) }
Check 'CPU-Luefter steht bei 42 Grad = nur Hinweis (Luefterstopp)' (-not ((Levels $p 'Lüfter') -match 'warn|krit') -and ($p | Where-Object { $_.Text -match 'Lüfterstopp' }))
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 38 'Cpu'), (S 'CPU Fan' 'Fan' 900), (S 'AIO Pump' 'Fan' 2700), (S 'AIO Pump' 'Control' 100)) }
Check 'Pumpe auf 100 % ist keine zu scharfe Kurve' (-not ((Levels $p 'Lüfter') -match 'warn|krit')) (($p | ForEach-Object Text) -join ' | ')
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 45 'Cpu'), (S 'CPU Fan' 'Fan' 900), (S 'Pump' 'Fan' 0)) }
Check 'Pumpe 0 U/min = warn (nicht krit)' ((Levels $p 'Lüfter') -contains 'warn' -and -not ((Levels $p 'Lüfter') -contains 'krit'))

# 3) Luefter voll bei kuehler CPU
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 40 'Cpu'), (S 'CPU Fan' 'Fan' 2400), (S 'CPU Fan' 'Control' 100)) }
Check 'Volllast bei 40 Grad = warn (Kurve zu scharf)' ((Levels $p 'Lüfter') -contains 'warn')

# 4) Heisse CPU im Leerlauf, GPU drosselt thermisch, NVMe heiss, SSD verschlissen, Drosselereignisse
$p = Run @{ Sensors = @((S 'Core (Tctl/Tdie)' 'Temperature' 92 'Cpu'), (S 'CPU Fan' 'Fan' 1500)); Gpus = @(Gpu 84 60 0x20); Disks = @((Disk 'WD NVMe' 'NVMe' 82 85), (Disk 'HDD' 'HDD' 45)); Ev37 = 12 }
Check 'CPU 92 Grad bei wenig Last = krit' ((Levels $p 'CPU') -contains 'krit')
Check 'Drosselereignisse = warn' (($p | Where-Object { $_.Bereich -eq 'CPU' -and $_.Text -match '12-mal' }).Stufe -eq 'warn')
Check 'GPU 84 Grad unter Last mit 0x20 = warn an der Grenze, kein krit' ((Levels $p 'Grafikkarte') -contains 'warn' -and -not ((Levels $p 'Grafikkarte') -contains 'krit'))
$p = Run @{ Gpus = @(Gpu 80 70 0x40) }
Check 'GPU Hardware-Hitzedrosselung 0x40 = krit' ((Levels $p 'Grafikkarte') -contains 'krit')
$p = Run @{ Gpus = @(Gpu 75 60 0x20) }
Check 'GPU regelt an Temperaturgrenze (0x20) = nur Hinweis' (-not ((Levels $p 'Grafikkarte') -match 'warn|krit'))
$p = Run @{ Gpus = @(Gpu 72 30 1 3) }
Check 'GPU im Leerlauf 72 Grad = warn' ((Levels $p 'Grafikkarte') -contains 'warn')
$p = Run @{ Gpus = @(Gpu 40 0 1 2 4) }
Check 'GPU nur mit x4 angebunden = warn' (($p | Where-Object { $_.Text -match 'x4 statt x16' }).Stufe -eq 'warn')
$p = Run @{ Disks = @((Disk 'WD NVMe' 'NVMe' 82 85), (Disk 'HDD' 'HDD' 45)) }
Check 'NVMe 82 Grad = krit, Verschleiss 85 % = warn' ((Levels $p 'Laufwerke') -contains 'krit' -and (Levels $p 'Laufwerke') -contains 'warn')
Check 'HDD 45 Grad = ok' (($p | Where-Object { $_.Text -match '^Laufwerk HDD' }).Stufe -eq 'ok')

# 5) GPU-Luefter steht trotz 72 Grad; Thermalzone bremst; Laptop-Akku verschlissen
$p = Run @{ Gpus = @(Gpu 72 0 0); Zones = @([pscustomobject]@{ Name = 'TZ00'; TempC = 95; PassivLimit = 60; Gruende = 1 }); Laptop = $true; HatAkku = $true; Wear = 55 }
Check 'GPU-Luefter steht bei 72 Grad = warn' ((Levels $p 'Grafikkarte') -contains 'warn')
Check 'Thermalzone passiv 60 % = krit' (($p | Where-Object { $_.Text -match 'wegen Hitze' }).Stufe -eq 'krit')
Check 'Akku 55 % Verlust = krit' ((Levels $p 'Akku') -contains 'krit')

# 6) Laufwerk meldet Fehlerzustand
$p = Run @{ Disks = @(Disk 'Alt' 'HDD' 40 $null 'Warning') }
Check 'Laufwerkszustand Warning = warn' ((Levels $p 'Laufwerke') -contains 'warn' -and -not ((Levels $p 'Laufwerke') -contains 'krit'))
$p = Run @{ Disks = @(Disk 'Alt' 'HDD' 40 $null 'Unhealthy') }
Check 'Laufwerkszustand Unhealthy = krit' ((Levels $p 'Laufwerke') -contains 'krit')
$p = Run @{ Disks = @(Disk 'USB' 'HDD' $null $null 'Unknown') }
Check 'Laufwerkszustand Unknown = kein Alarm' (-not ((Levels $p 'Laufwerke') -match 'warn|krit'))
$p = Run @{ MemDiag = 1; Whea19 = 7 }
Check 'Speicherdiagnose-Fehler = krit, WHEA 19 = warn' ((Levels $p 'Speicher') -contains 'krit' -and ($p | Where-Object { $_.Text -match 'korrigierte Fehler' }).Stufe -eq 'warn')
$p = Run @{ Ev37 = 2; Laptop = $true }
Check 'Drosselung auf Laptop = nur Hinweis' (-not ((Levels $p 'CPU') -match 'warn|krit'))

# ---------------------------------------------------------------- TjMax, Zahlen
Check 'TjMax Ryzen 9 7950X = 95' ((Get-CpuTjMax 'AMD Ryzen 9 7950X 16-Core Processor') -eq 95)
Check 'TjMax Ryzen 7 7800X3D = 89' ((Get-CpuTjMax 'AMD Ryzen 7 7800X3D 8-Core Processor') -eq 89)
Check 'TjMax Ryzen 9 5900X = 90' ((Get-CpuTjMax 'AMD Ryzen 9 5900X 12-Core Processor') -eq 90)
Check 'TjMax i9-14900K = 100' ((Get-CpuTjMax '13th Gen Intel(R) Core(TM) i9-14900K') -eq 100)
Check 'TjMax Core Ultra 9 285K = 105' ((Get-CpuTjMax 'Intel(R) Core(TM) Ultra 9 285K') -eq 105)
Check 'ConvertTo-WtNumber 45,5 = 45.5' ((ConvertTo-WtNumber '45,5') -eq 45.5)
Check 'ConvertTo-WtNumber 1.234 (Tausender) = 1234' ((ConvertTo-WtNumber '1.234') -eq 1234)
$g3 = @(ConvertFrom-NvidiaCsv @('NVIDIA GeForce RTX 4070 Ti, 36, 0, 41.85, 285.00, 2610, 3105, 3, 16, 16, 0x0000000000000001'))
Check 'nvidia-smi CSV neues Format: Auslastung/PCIe' ($g3[0].Auslastung -eq 3 -and $g3[0].PcieBreite -eq 16 -and $g3[0].Gruende -eq 1)

# ---------------------------------------------------------------- Score mit Hardware-Abschnitt
$snapOk = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $false; AndererVirenschutz = $true }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @() }; Hardware = @{ Punkte = @() } }
Check 'Score 100: Defender aus, aber anderer Virenschutz aktiv' ((Get-HealthScore $snapOk).Wert -eq 100) (Get-HealthScore $snapOk | ConvertTo-Json -Depth 4)
$snapBad = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @(@{ Text = 'TPM'; Anzahl = 30 }) }; Hardware = @{ Punkte = @(@{ Stufe = 'krit'; Text = 'x' }, @{ Stufe = 'warn'; Text = 'y' }) } }
Check 'Score: 1 Warnsignal (-2), 1 krit (-5), 1 warn (-1) = 92' ((Get-HealthScore $snapBad).Wert -eq 92) ((Get-HealthScore $snapBad).Wert)
$snapMom = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @() }; Hardware = @{ Punkte = @(@{ Stufe = 'krit'; Text = 'heiss'; Wertung = 'moment' }) } }
Check 'Score: Momentaufnahmen (Temperatur) zaehlen nicht' ((Get-HealthScore $snapMom).Wert -eq 100) ((Get-HealthScore $snapMom).Wert)
$snapWin = @{ Zeit = '2026-10-23T10:00:00'; Laufwerke = @(@{ LW = 'C'; FreiGB = 300; FreiProzent = 14 }); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true; WindowsSupportEnde = '2026-10-13'; TageSeitUpdate = 3 }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @() } }
$env:SystemDrive = 'C:'
Check 'Score: Windows ohne Support -20, 300 GB frei bei 14 % kein Abzug' ((Get-HealthScore $snapWin).Wert -eq 80) ((Get-HealthScore $snapWin).Abzuege | ConvertTo-Json -Compress)
# Altes Snapshot-Format (ohne Stabilitaet) zaehlt weiter ueber die Befunde
$snapOld = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true }; Speicher = @{}; Befunde = @(@{ Regel = 'EVT-HEALTH'; Anzahl = 2 }) }
Check 'Score altes Format: 2 Warnsignale = 96' ((Get-HealthScore $snapOld).Wert -eq 96) ((Get-HealthScore $snapOld).Wert)

# ---------------------------------------------------------------- Kuehlungstest (kurz, mit kuenstlichen Messwerten)
function Start-Sleep([int]$Milliseconds = 0, [int]$Seconds = 0) { [Threading.Thread]::Sleep(60) }
$Script:PerfSeq = New-Object System.Collections.Generic.Queue[object]
function Get-CpuPerfSample { $v = if ($Script:PerfSeq.Count) { $Script:PerfSeq.Dequeue() } else { $Script:PerfLast }; $Script:PerfLast = $v; [pscustomobject]@{ Leistung = $v; Limit = 100; MHz = 4000; Auslastung = 100 } }
function Set-Perf([double[]]$v) { $Script:PerfSeq.Clear(); foreach ($x in $v) { $Script:PerfSeq.Enqueue($x) }; $Script:PerfLast = $v[-1] }

# a) Leistung bleibt stabil, keine Sensoren
$Script:Mock = @{ Ev37 = 0; Neu37 = 0 }
Set-Perf (@(120, 120, 120) + @(1..60 | ForEach-Object { 118 }))
$r = Invoke-CoolingTest 3
Check 'Kuehlungstest stabil: ok' ($r.Status -eq 'OK' -and @($r.Punkte | Where-Object Stufe -eq 'ok').Count -ge 1 -and -not @($r.Punkte | Where-Object { $_.Stufe -in 'warn', 'krit' })) ($r.Punkte | ConvertTo-Json)
Check 'Kuehlungstest speichert JSON' (@(Get-ChildItem (Join-Path $TestData 'kuehltest') -Filter *.json).Count -ge 1)

# b) Leistung faellt um 25 % ohne Hitze-/Drosselsignal und ohne Sensoren: nur Hinweis (Turbo-Limit), kein Alarm
Set-Perf (@(140, 140, 140) + @(1..8 | ForEach-Object { 140 }) + @(1..60 | ForEach-Object { 105 }))
$r = Invoke-CoolingTest 3
Check 'Turbo-Abfall 25 % ohne Signal: kein warn/krit' (-not ($r.Punkte | Where-Object { $_.Stufe -in 'warn', 'krit' })) ($r.Punkte | ConvertTo-Json)

# c) Leistung faellt um 40 %, Temperatur 99 Grad, Luefter drehen nicht hoch
$Script:TempSeq = 0
function Get-HwMonitorSensors([switch]$NoCache) { $Script:TempSeq++; $t = [math]::Min(99, 45 + 4 * $Script:TempSeq); @((S 'CPU Package' 'Temperature' $t 'Cpu'), (S 'CPU Fan' 'Fan' 900)) }
$Script:Mock = @{ Ev37 = 0; Neu37 = 2 }
Set-Perf (@(140, 140, 140) + @(1..8 | ForEach-Object { 140 }) + @(1..60 | ForEach-Object { 80 }))
$r = Invoke-CoolingTest 3
$st = @($r.Punkte | ForEach-Object { $_.Stufe })
Check 'Hitze + Abfall 40 %: krit' ($st -contains 'krit') ($r.Punkte | ConvertTo-Json)
Check 'Feste Luefterdrehzahl erkannt (warn Luefterkurve)' (@($r.Punkte | Where-Object { $_.Text -match 'Lüfterkurve' }).Count -eq 1) ($r.Punkte | ConvertTo-Json)
Check 'Firmware-Drosselung waehrend des Tests gemeldet' (@($r.Punkte | Where-Object { $_.Text -match '2-mal' }).Count -eq 1) ($r.Punkte | ConvertTo-Json)

# c2) Benutzer bricht ab: nicht gespeichert, kein "letzter Test"
$vorher = @(Get-ChildItem (Join-Path $TestData 'kuehltest') -Filter *.json).Count
$ctl = [hashtable]::Synchronized(@{ Cancel = $true })
$Script:Mock = @{ Ev37 = 0; Neu37 = 0 }
$r = Invoke-CoolingTest 3 $null $ctl
Check 'Abbruch: Status ABGEBROCHEN, nicht gespeichert' ($r.Status -eq 'ABGEBROCHEN' -and @(Get-ChildItem (Join-Path $TestData 'kuehltest') -Filter *.json).Count -eq $vorher)
Check 'Letzter Kuehlungstest ist ein vollstaendiger' ((Get-LastCoolingTest).Status -in 'OK', 'GESTOPPT')
# c3) Sicherheitsstopp bei Temperatur ueber TjMax+3
$Script:TempSeq = 0
function Get-HwMonitorSensors([switch]$NoCache) { $Script:TempSeq++; @((S 'CPU Package' 'Temperature' (60 + 10 * $Script:TempSeq) 'Cpu'), (S 'CPU Fan' 'Fan' 900)) }
$Script:Mock = @{ Ev37 = 0; Neu37 = 0; Cpu = 'AMD Ryzen 9 7950X' }
$r = Invoke-CoolingTest 3
Check 'Sicherheitsstopp bei Uebertemperatur: GESTOPPT + krit' ($r.Status -eq 'GESTOPPT' -and ($r.Punkte | Where-Object Stufe -eq 'krit'))
# c4) VM/Server gesperrt
$Script:Mock = @{ VM = $true }
Check 'VM: Kuehlungstest gesperrt' ((Invoke-CoolingTest 3).Status -eq 'GESPERRT')

# d) Akku: Test wird verweigert
$Script:Mock = @{ Akku = $true; Laptop = $true; HatAkku = $true }
$r = Invoke-CoolingTest 3
Check 'Akkubetrieb: Test verweigert' ($r.Status -eq 'AKKU')

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail Test(s) fehlgeschlagen" -ForegroundColor Red } else { Write-Host 'Alle Hardware-Tests bestanden' -ForegroundColor Green }
exit $fail
