# Test-Hardware.ps1 - checks the rating of cooling, fans, temperatures, drives and the cooling test
# with synthetic readings. Runs without Windows (also with pwsh on Linux). Usage: pwsh ./tests/Test-Hardware.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-hwtest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TestData | Out-Null

# Load functions and configuration from WinTidy.ps1 without running the script
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
    if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red }
}
function Levels($pts, [string]$Bereich) { @($pts | Where-Object { -not $Bereich -or $_.Bereich -eq $Bereich } | ForEach-Object { $_.Stufe }) }

# ---------------------------------------------------------------- Numbers and nvidia-smi
Check 'ConvertTo-WtNumber 41.85' ((ConvertTo-WtNumber ' 41.85') -eq 41.85)
Check 'ConvertTo-WtNumber [N/A]' ($null -eq (ConvertTo-WtNumber '[N/A]'))
$g = @(ConvertFrom-NvidiaCsv @('NVIDIA GeForce RTX 4070 Ti, 36, 0, 41.85, 285.00, 2610, 3105, 0x0000000000000001'))
Check 'nvidia-smi CSV: name/temp/fan/mask' ($g.Count -eq 1 -and $g[0].TempC -eq 36 -and $g[0].LuefterProzent -eq 0 -and $g[0].Gruende -eq 1 -and $g[0].TaktMaxMHz -eq 3105)
$g2 = @(ConvertFrom-NvidiaCsv @('Quadro, 91, [N/A], 100, 120, 1200, 1800, 0x0000000000000040'))
Check 'nvidia-smi CSV: N/A fan, heat reason' ($null -eq $g2[0].LuefterProzent -and ($g2[0].Gruende -band 0x40))

# ---------------------------------------------------------------- Scenario building blocks (replace the data sources)
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

# 1) First test PC: no motherboard sensors, idle GPU with stopped fan, no throttling
$p = Run @{ Gpus = @(Gpu 36 0 1); Disks = @(Disk 'Samsung SSD' 'SSD' $null) }
Check 'No sensors: hint about LibreHardwareMonitor' (@($p | Where-Object { $_.Bereich -eq 'Lüfter' -and $_.Text -match 'LibreHardwareMonitor' }).Count -eq 1) ($p | ConvertTo-Json -Depth 4)
Check 'GPU 36 degrees, fan 0 % = ok (zero RPM)' ((Levels $p 'Grafikkarte') -contains 'ok' -and -not ((Levels $p 'Grafikkarte') -match 'warn|krit'))
Check 'No throttling = ok' ((Levels $p 'CPU') -contains 'ok')
Check 'No warn/krit at all' (-not ((Levels $p) -match 'warn|krit')) ((Levels $p) -join ',')

# 2) CPU fan stopped
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 65 'Cpu'), (S 'CPU Fan' 'Fan' 0), (S 'System Fan #1' 'Fan' 800)) }
Check 'CPU fan 0 RPM at 65 degrees = krit' ((Levels $p 'Lüfter') -contains 'krit')
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 42 'Cpu'), (S 'CPU Fan' 'Fan' 0), (S 'System Fan #1' 'Fan' 800)) }
Check 'CPU fan stopped at 42 degrees = hint only (fan stop)' (-not ((Levels $p 'Lüfter') -match 'warn|krit') -and ($p | Where-Object { $_.Text -match 'fan stop' }))
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 38 'Cpu'), (S 'CPU Fan' 'Fan' 900), (S 'AIO Pump' 'Fan' 2700), (S 'AIO Pump' 'Control' 100)) }
Check 'Pump at 100 % is not an aggressive curve' (-not ((Levels $p 'Lüfter') -match 'warn|krit')) (($p | ForEach-Object Text) -join ' | ')
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 45 'Cpu'), (S 'CPU Fan' 'Fan' 900), (S 'Pump' 'Fan' 0)) }
Check 'Pump 0 RPM = warn (not krit)' ((Levels $p 'Lüfter') -contains 'warn' -and -not ((Levels $p 'Lüfter') -contains 'krit'))

# 3) Fans at full speed with a cool CPU
$p = Run @{ Sensors = @((S 'CPU Package' 'Temperature' 40 'Cpu'), (S 'CPU Fan' 'Fan' 2400), (S 'CPU Fan' 'Control' 100)) }
Check 'Full speed at 40 degrees = warn (curve too aggressive)' ((Levels $p 'Lüfter') -contains 'warn')

# 4) Hot CPU at idle, GPU throttles thermally, hot NVMe, worn SSD, throttling events
$p = Run @{ Sensors = @((S 'Core (Tctl/Tdie)' 'Temperature' 92 'Cpu'), (S 'CPU Fan' 'Fan' 1500)); Gpus = @(Gpu 84 60 0x20); Disks = @((Disk 'WD NVMe' 'NVMe' 82 85), (Disk 'HDD' 'HDD' 45)); Ev37 = 12 }
Check 'CPU 92 degrees at light load = krit' ((Levels $p 'CPU') -contains 'krit')
Check 'Throttling events = warn' (($p | Where-Object { $_.Bereich -eq 'CPU' -and $_.Text -match '12 times' }).Stufe -eq 'warn')
Check 'GPU 84 degrees under load with 0x20 = warn at the limit, no krit' ((Levels $p 'Grafikkarte') -contains 'warn' -and -not ((Levels $p 'Grafikkarte') -contains 'krit'))
$p = Run @{ Gpus = @(Gpu 80 70 0x40) }
Check 'GPU hardware heat throttling 0x40 = krit' ((Levels $p 'Grafikkarte') -contains 'krit')
$p = Run @{ Gpus = @(Gpu 75 60 0x20) }
Check 'GPU regulates at temperature limit (0x20) = hint only' (-not ((Levels $p 'Grafikkarte') -match 'warn|krit'))
$p = Run @{ Gpus = @(Gpu 72 30 1 3) }
Check 'GPU at idle 72 degrees = warn' ((Levels $p 'Grafikkarte') -contains 'warn')
$p = Run @{ Gpus = @(Gpu 40 0 1 2 4) }
Check 'GPU only connected with x4 = warn' (($p | Where-Object { $_.Text -match 'x4 instead of x16' }).Stufe -eq 'warn')
$p = Run @{ Disks = @((Disk 'WD NVMe' 'NVMe' 82 85), (Disk 'HDD' 'HDD' 45)) }
Check 'NVMe 82 degrees = krit, wear 85 % = warn' ((Levels $p 'Laufwerke') -contains 'krit' -and (Levels $p 'Laufwerke') -contains 'warn')
Check 'HDD 45 degrees = ok' (($p | Where-Object { $_.Text -match '^Drive HDD' }).Stufe -eq 'ok')

# 5) GPU fan stopped despite 72 degrees; thermal zone throttles; laptop battery worn
$p = Run @{ Gpus = @(Gpu 72 0 0); Zones = @([pscustomobject]@{ Name = 'TZ00'; TempC = 95; PassivLimit = 60; Gruende = 1 }); Laptop = $true; HatAkku = $true; Wear = 55 }
Check 'GPU fan stopped at 72 degrees = warn' ((Levels $p 'Grafikkarte') -contains 'warn')
Check 'Thermal zone passive 60 % = krit' (($p | Where-Object { $_.Text -match 'due to heat' }).Stufe -eq 'krit')
Check 'Battery 55 % loss = krit' ((Levels $p 'Akku') -contains 'krit')

# 6) Drive reports an error state
$p = Run @{ Disks = @(Disk 'Alt' 'HDD' 40 $null 'Warning') }
Check 'Drive state Warning = warn' ((Levels $p 'Laufwerke') -contains 'warn' -and -not ((Levels $p 'Laufwerke') -contains 'krit'))
$p = Run @{ Disks = @(Disk 'Alt' 'HDD' 40 $null 'Unhealthy') }
Check 'Drive state Unhealthy = krit' ((Levels $p 'Laufwerke') -contains 'krit')
$p = Run @{ Disks = @(Disk 'USB' 'HDD' $null $null 'Unknown') }
Check 'Drive state Unknown = no alarm' (-not ((Levels $p 'Laufwerke') -match 'warn|krit'))
$p = Run @{ MemDiag = 1; Whea19 = 7 }
Check 'Memory diagnostic errors = krit, WHEA 19 = warn' ((Levels $p 'Speicher') -contains 'krit' -and ($p | Where-Object { $_.Text -match 'corrected errors' }).Stufe -eq 'warn')
$p = Run @{ Ev37 = 2; Laptop = $true }
Check 'Throttling on a laptop = hint only' (-not ((Levels $p 'CPU') -match 'warn|krit'))

# ---------------------------------------------------------------- TjMax, numbers
Check 'TjMax Ryzen 9 7950X = 95' ((Get-CpuTjMax 'AMD Ryzen 9 7950X 16-Core Processor') -eq 95)
Check 'TjMax Ryzen 7 7800X3D = 89' ((Get-CpuTjMax 'AMD Ryzen 7 7800X3D 8-Core Processor') -eq 89)
Check 'TjMax Ryzen 9 5900X = 90' ((Get-CpuTjMax 'AMD Ryzen 9 5900X 12-Core Processor') -eq 90)
Check 'TjMax i9-14900K = 100' ((Get-CpuTjMax '13th Gen Intel(R) Core(TM) i9-14900K') -eq 100)
Check 'TjMax Core Ultra 9 285K = 105' ((Get-CpuTjMax 'Intel(R) Core(TM) Ultra 9 285K') -eq 105)
Check 'ConvertTo-WtNumber 45,5 = 45.5' ((ConvertTo-WtNumber '45,5') -eq 45.5)
Check 'ConvertTo-WtNumber 1.234 (thousands) = 1234' ((ConvertTo-WtNumber '1.234') -eq 1234)
$g3 = @(ConvertFrom-NvidiaCsv @('NVIDIA GeForce RTX 4070 Ti, 36, 0, 41.85, 285.00, 2610, 3105, 3, 16, 16, 0x0000000000000001'))
Check 'nvidia-smi CSV new format: load/PCIe' ($g3[0].Auslastung -eq 3 -and $g3[0].PcieBreite -eq 16 -and $g3[0].Gruende -eq 1)

# ---------------------------------------------------------------- Score with hardware section
$snapOk = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $false; AndererVirenschutz = $true }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @() }; Hardware = @{ Punkte = @() } }
Check 'Score 100: Defender off, but another antivirus active' ((Get-HealthScore $snapOk).Wert -eq 100) (Get-HealthScore $snapOk | ConvertTo-Json -Depth 4)
$snapBad = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @(@{ Text = 'TPM'; Anzahl = 30 }) }; Hardware = @{ Punkte = @(@{ Stufe = 'krit'; Text = 'x' }, @{ Stufe = 'warn'; Text = 'y' }) } }
Check 'Score: 1 warning sign (-2), 1 krit (-5), 1 warn (-1) = 92' ((Get-HealthScore $snapBad).Wert -eq 92) ((Get-HealthScore $snapBad).Wert)
$snapMom = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @() }; Hardware = @{ Punkte = @(@{ Stufe = 'krit'; Text = 'heiss'; Wertung = 'moment' }) } }
Check 'Score: snapshots (temperature) do not count' ((Get-HealthScore $snapMom).Wert -eq 100) ((Get-HealthScore $snapMom).Wert)
$snapWin = @{ Zeit = '2026-10-23T10:00:00'; Laufwerke = @(@{ LW = 'C'; FreiGB = 300; FreiProzent = 14 }); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true; WindowsSupportEnde = '2026-10-13'; TageSeitUpdate = 3 }; Speicher = @{}; Stabilitaet = @{ Warnsignale = @() } }
$env:SystemDrive = 'C:'
Check 'Score: Windows without support -20, 300 GB free at 14 % no deduction' ((Get-HealthScore $snapWin).Wert -eq 80) ((Get-HealthScore $snapWin).Abzuege | ConvertTo-Json -Compress)
# Old snapshot format (without Stabilitaet) still counts via the findings
$snapOld = @{ Laufwerke = @(); Boot = @{}; Autostart = @{ Aktiv = 3; Verwaist = 0 }; Ereignisse = @{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = @{}; Sicherheit = @{ SecureBoot = $true; DefenderEchtzeit = $true }; Speicher = @{}; Befunde = @(@{ Regel = 'EVT-HEALTH'; Anzahl = 2 }) }
Check 'Score old format: 2 warning signs = 96' ((Get-HealthScore $snapOld).Wert -eq 96) ((Get-HealthScore $snapOld).Wert)

# ---------------------------------------------------------------- Cooling test (short, with synthetic readings)
function Start-Sleep([int]$Milliseconds = 0, [int]$Seconds = 0) { [Threading.Thread]::Sleep(60) }
$Script:PerfSeq = New-Object System.Collections.Generic.Queue[object]
function Get-CpuPerfSample { $v = if ($Script:PerfSeq.Count) { $Script:PerfSeq.Dequeue() } else { $Script:PerfLast }; $Script:PerfLast = $v; [pscustomobject]@{ Leistung = $v; Limit = 100; MHz = 4000; Auslastung = 100 } }
function Set-Perf([double[]]$v) { $Script:PerfSeq.Clear(); foreach ($x in $v) { $Script:PerfSeq.Enqueue($x) }; $Script:PerfLast = $v[-1] }

# a) Performance stays stable, no sensors
$Script:Mock = @{ Ev37 = 0; Neu37 = 0 }
Set-Perf (@(120, 120, 120) + @(1..60 | ForEach-Object { 118 }))
$r = Invoke-CoolingTest 3
Check 'Cooling test stable: ok' ($r.Status -eq 'OK' -and @($r.Punkte | Where-Object Stufe -eq 'ok').Count -ge 1 -and -not @($r.Punkte | Where-Object { $_.Stufe -in 'warn', 'krit' })) ($r.Punkte | ConvertTo-Json)
Check 'Cooling test saves JSON' (@(Get-ChildItem (Join-Path $TestData 'kuehltest') -Filter *.json).Count -ge 1)

# b) Performance drops 25 % without heat/throttling signal and without sensors: hint only (turbo limit), no alarm
Set-Perf (@(140, 140, 140) + @(1..8 | ForEach-Object { 140 }) + @(1..60 | ForEach-Object { 105 }))
$r = Invoke-CoolingTest 3
Check 'Turbo drop 25 % without signal: no warn/krit' (-not ($r.Punkte | Where-Object { $_.Stufe -in 'warn', 'krit' })) ($r.Punkte | ConvertTo-Json)

# c) Performance drops 40 %, temperature 99 degrees, fans do not speed up
$Script:TempSeq = 0
function Get-HwMonitorSensors([switch]$NoCache) { $Script:TempSeq++; $t = [math]::Min(99, 45 + 4 * $Script:TempSeq); @((S 'CPU Package' 'Temperature' $t 'Cpu'), (S 'CPU Fan' 'Fan' 900)) }
$Script:Mock = @{ Ev37 = 0; Neu37 = 2 }
Set-Perf (@(140, 140, 140) + @(1..8 | ForEach-Object { 140 }) + @(1..60 | ForEach-Object { 80 }))
$r = Invoke-CoolingTest 3
$st = @($r.Punkte | ForEach-Object { $_.Stufe })
Check 'Heat + drop 40 %: krit' ($st -contains 'krit') ($r.Punkte | ConvertTo-Json)
Check 'Fixed fan speed detected (warn fan curve)' (@($r.Punkte | Where-Object { $_.Text -match 'fan curve' }).Count -eq 1) ($r.Punkte | ConvertTo-Json)
Check 'Firmware throttling reported during the test' (@($r.Punkte | Where-Object { $_.Text -match '2 times' }).Count -eq 1) ($r.Punkte | ConvertTo-Json)

# c2) User cancels: not saved, no "last test"
$vorher = @(Get-ChildItem (Join-Path $TestData 'kuehltest') -Filter *.json).Count
$ctl = [hashtable]::Synchronized(@{ Cancel = $true })
$Script:Mock = @{ Ev37 = 0; Neu37 = 0 }
$r = Invoke-CoolingTest 3 $null $ctl
Check 'Cancel: status ABGEBROCHEN, not saved' ($r.Status -eq 'ABGEBROCHEN' -and @(Get-ChildItem (Join-Path $TestData 'kuehltest') -Filter *.json).Count -eq $vorher)
Check 'Last cooling test is a complete one' ((Get-LastCoolingTest).Status -in 'OK', 'GESTOPPT')
# c3) Safety stop at a temperature above TjMax+3
$Script:TempSeq = 0
function Get-HwMonitorSensors([switch]$NoCache) { $Script:TempSeq++; @((S 'CPU Package' 'Temperature' (60 + 10 * $Script:TempSeq) 'Cpu'), (S 'CPU Fan' 'Fan' 900)) }
$Script:Mock = @{ Ev37 = 0; Neu37 = 0; Cpu = 'AMD Ryzen 9 7950X' }
$r = Invoke-CoolingTest 3
Check 'Safety stop on overtemperature: GESTOPPT + krit' ($r.Status -eq 'GESTOPPT' -and ($r.Punkte | Where-Object Stufe -eq 'krit'))
# c4) VM/server blocked
$Script:Mock = @{ VM = $true }
Check 'VM: cooling test blocked' ((Invoke-CoolingTest 3).Status -eq 'GESPERRT')

# d) Battery: test is refused
$Script:Mock = @{ Akku = $true; Laptop = $true; HatAkku = $true }
$r = Invoke-CoolingTest 3
Check 'On battery: test refused' ($r.Status -eq 'AKKU')

# ---------------------------------------------------------------- German output (lang\de.psd1)
function Get-HwMonitorSensors([switch]$NoCache) { @($Script:Mock.Sensors | Where-Object { $_ }) }
Set-WtLanguage 'de' $root
$p = Run @{ Gpus = @(Gpu 36 0 1); Disks = @(Disk 'Samsung SSD' 'SSD' $null) }
Check 'German: hint about LibreHardwareMonitor is translated' (@($p | Where-Object { $_.Bereich -eq 'Lüfter' -and $_.Text -match 'Lüfterdrehzahlen' }).Count -eq 1) ($p | ConvertTo-Json -Depth 4)
Check 'German: formatted text with placeholder' ((T 'Drive {0}: {1} °C' 'X' 40) -eq 'Laufwerk X: 40 °C') (T 'Drive {0}: {1} °C' 'X' 40)
Set-WtLanguage 'en' $root
Check 'English again after switching back' ((T 'Drives') -eq 'Drives')

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red } else { Write-Host 'All hardware tests passed' -ForegroundColor Green }
exit $fail
