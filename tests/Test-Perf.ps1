# Test-Perf.ps1 - performance key figures: idle measurement (median, calm detection), key figure values from snapshots,
# the "did WinTidy help?" verdict with noise tolerance, start times only from starts after the optimization, comparison ids,
# history data and the report section (English and German). Synthetic snapshots, no Windows needed (also pwsh on Linux).
# Usage: pwsh ./tests/Test-Perf.ps1
$ErrorActionPreference = 'Stop'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-test-perf'
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Join-Path $PSScriptRoot '..') 'WinTidy.ps1'), [ref]$t, [ref]$e)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent.Parent.Parent -eq $null -or ($n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast) }, $false)
foreach ($f in $funcs) { . ([scriptblock]::Create($f.Extent.Text)) }
Set-WtLanguage 'en'
$env:SystemDrive = 'C:'; $env:COMPUTERNAME = 'TESTPC'
$Script:Version = '1.8.0'; $Script:DataDir = $TestData; $Script:SnapDir = (Join-Path $TestData 'snapshots'); $Script:RunsDir = (Join-Path $TestData 'runs')
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Script:SnapDir, $Script:RunsDir | Out-Null
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }
$fail = 0
function Check([string]$Name, [bool]$Cond) { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name" -ForegroundColor Red } }

# ---------------------------------------------------------------- median and idle measurement
Check 'Get-Median: odd, even, empty' ((Get-Median @(5, 1, 9)) -eq 5 -and (Get-Median @(4, 1, 2, 3)) -eq 2.5 -and $null -eq (Get-Median @()))

function Start-Sleep { }   # no waiting in the test
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) [pscustomobject]@{ FreePhysicalMemory = 4GB / 1KB; TotalVisibleMemorySize = 16GB / 1KB } }   # 12 GB of 16 GB in use
$Script:Seq = New-Object System.Collections.Generic.Queue[object]
function Get-IdleCounters {
    $x = $null; if ($Script:Seq.Count) { $x = $Script:Seq.Dequeue() }
    if ($null -eq $x) { return [pscustomobject]@{ Cpu = 2.0; Platte = 1.0; PlatteOps = 5.0 } }
    return [pscustomobject]@{ Cpu = $x[0]; Platte = $x[1]; PlatteOps = $x[2] }
}
# warm-up, then still busy twice (60, 40), calm on the third reading (10) -> 6 readings with one spike each
foreach ($r in @(@(1, 0, 0), @(60, 0, 0), @(40, 0, 0), @(10, 0, 0), @(5, 10, 100), @(50, 1, 90), @(4, 2, 100), @(6, 1, 110), @(5, 90, 95), @(4, 2, 105))) { $Script:Seq.Enqueue($r) }
$idle = Get-IdleSample
Check 'Idle: median ignores single spikes (CPU 5, drive 2)' ($idle.CpuProzent -eq 5 -and $idle.PlatteProzent -eq 2)
Check 'Idle: calm PC -> Ruhig' ($idle.Ruhig -eq $true)
Check 'Idle: new fields present' ($null -ne $idle.PlatteOpsProSek -and $idle.RamBelegtGB -gt 0 -and $idle.Prozesse -gt 0)
$Script:Seq.Clear(); for ($i = 0; $i -lt 30; $i++) { $Script:Seq.Enqueue(@(80, 5, 5)) }
$busy = Get-IdleSample
Check 'Idle: PC never calms down -> Ruhig = false' ($busy.Ruhig -eq $false -and $busy.CpuProzent -eq 80)

# ---------------------------------------------------------------- synthetic snapshots
function MkBoots([datetime]$from, [int]$count, [int]$gesamtMs, [int]$nachMs) {
    @(1..$count | ForEach-Object { [pscustomobject]@{ Zeit = $from.AddHours($_ * 12).ToString('o'); GesamtMs = $gesamtMs + ($_ * 100); HauptpfadMs = $gesamtMs - $nachMs; NachDesktopMs = $nachMs } })
}
function MkSnap([string]$label, [datetime]$time, $free, $boots, $mittel5, $aktiv, $proz, $ram, $cpu, $platte, $ruhig) {
    $idle = [ordered]@{ CpuProzent = $cpu; RamBelegtProzent = 15; RamBelegtGB = $ram; Prozesse = $proz; Threads = 4000; Handles = 90000 }
    if ($null -ne $platte) { $idle.PlatteProzent = $platte; $idle.PlatteOpsProSek = 10 }
    if ($null -ne $ruhig) { $idle.Ruhig = $ruhig }
    $s = [ordered]@{ Tool = '1.8.0'; Label = $label; Zeit = $time.ToString('o'); Admin = $true; Computer = 'TESTPC'; Benutzer = 'X\y'
        System = [ordered]@{ OS = 'Microsoft Windows 11 Home'; Build = '26200.1'; Version = '25H2'; CPU = 'Test CPU'; Kerne = 4; Threads = 8; RamGB = 16; Board = 'Test Board'; BIOS = 'P1'; LetzterStart = $time.ToString('o'); LaufzeitStd = 1 }
        Laufwerke = @([pscustomobject]@{ LW = 'C'; Label = ''; FS = 'NTFS'; GroesseGB = 231.7; FreiGB = $free; FreiProzent = [math]::Round(100 * $free / 231.7, 1); Medium = 'SSD'; Bus = 'SATA'; Disk = 'Test' })
        Boot = [ordered]@{ Verlauf = @($boots); Mittel5 = $mittel5; Bremser = @() }
        Autostart = [ordered]@{ Gesamt = 20; Aktiv = $aktiv; Verwaist = 0; Liste = @() }
        Dienste = [ordered]@{ Gesamt = 300; Laufend = 120; AutoDrittanbieter = 12 }; Aufgaben = [ordered]@{ Gesamt = 200; Eigene = 13 }; Programme = [ordered]@{ Installiert = 70; StoreApps = 60 }
        Treiber = [ordered]@{ Pakete = 100; Duplikate = 3; Geistergeraete = 5 }; Ereignisse = [ordered]@{ FehlerSystem7T = 10; FehlerAnwendung7T = 10; Top = @() }
        Leerlauf = [pscustomobject]$idle
        Speicher = [ordered]@{ PapierkorbBytes = 0; TempBytes = 1000; CrashDumpsBytes = 0; BrowserCacheBytes = 0 }
        Sicherheit = [ordered]@{ SecureBoot = $true; DefenderEchtzeit = $true; AusfuehrungsrichtlinieCU = 'RemoteSigned' }
        Stabilitaet = [ordered]@{ Warnsignale = @() }; Befunde = @() }
    $s.Score = Get-HealthScore $s
    $s | ConvertTo-Json -Depth 7 | Out-File (Join-Path $Script:SnapDir ('{0}_{1}.json' -f $time.ToString('yyyyMMdd-HHmmss'), $label)) -Encoding utf8
}
$t0 = [datetime]'2026-10-20T18:00:00'
$oldBoots = MkBoots $t0.AddDays(-5) 5 62000 20000
$newBoots = MkBoots $t0.AddHours(2) 4 40000 8000
MkSnap 'vorher' $t0 78.3 $oldBoots 62000 18 220 9.8 3.0 5.0 $true
MkSnap 'nachher' $t0.AddHours(1) 86.1 $oldBoots 62000 9 205 9.7 3.5 4.0 $true
MkSnap 'scan' $t0.AddDays(5) 85.0 ($newBoots + $oldBoots) 40200 9 206 9.6 3.2 4.5 $true
$files = @(Get-Snapshots)
Check 'Synthetic snapshots written' ($files.Count -eq 3)
$vor = Read-Snapshot $files[0]; $nach = Read-Snapshot $files[1]; $spaet = Read-Snapshot $files[2]

# ---------------------------------------------------------------- key figure values
Check 'Perf values from a snapshot' ((Get-PerfValue $vor 'BootGesamt') -eq 62.0 -and (Get-PerfValue $vor 'Autostart') -eq 18 -and (Get-PerfValue $vor 'Prozesse') -eq 220 -and (Get-PerfValue $vor 'Ram') -eq 9.8 -and (Get-PerfValue $vor 'Cpu') -eq 3.0 -and (Get-PerfValue $vor 'Platte') -eq 5.0 -and (Get-PerfValue $vor 'Frei') -eq 78.3)
Check 'Perf value BootNach from the start history' ((Get-PerfValue $vor 'BootNach') -eq 20.0)
Check 'Perf definitions: 8 figures, unique ids, all with text' ((@(Get-PerfDefs).Count -eq 8) -and (@(Get-PerfDefs | Select-Object -ExpandProperty Id -Unique).Count -eq 8) -and -not @(Get-PerfDefs | Where-Object { -not $_.Titel -or -not $_.Hinweis }).Count)

# ---------------------------------------------------------------- verdict: immediately after the optimization (no starts yet)
$e1 = Get-PerfEffect $vor $nach @()
$m1 = @{}; foreach ($m in $e1.Metriken) { $m1[$m.Id] = $m }
Check 'Effect right after: start times are open (no starts after the optimization yet)' ($m1['BootGesamt'].Bewertung -eq 'offen' -and $m1['BootNach'].Bewertung -eq 'offen')
Check 'Effect: startup programs 18 -> 9 and free space +7.8 GB are better' ($m1['Autostart'].Bewertung -eq 'besser' -and $m1['Frei'].Bewertung -eq 'besser')
Check 'Effect: 15 fewer processes is better' ($m1['Prozesse'].Bewertung -eq 'besser')
Check 'Effect: noise (RAM -0.1 GB, CPU +0.5, drive -1) counts as unchanged' ($m1['Ram'].Bewertung -eq '=' -and $m1['Cpu'].Bewertung -eq '=' -and $m1['Platte'].Bewertung -eq '=')
Check 'Effect: counts and verdict' ($e1.Besser -eq 3 -and $e1.Gleich -eq 3 -and $e1.Schlechter -eq 0 -and $e1.Offen -eq 2 -and $e1.Gemessen -eq 6 -and $e1.Urteil -eq 'besser')
Check 'Effect: headline says it helped, note asks for restarts' ($e1.Kopfzeile -match 'WinTidy helped: 3 of 6' -and $e1.BootHinweis -match 'at least 2 starts')

# ---------------------------------------------------------------- verdict: later, with starts after the optimization
$boots = @($newBoots + $oldBoots)
$e2 = Get-PerfEffect $vor $spaet $boots
$m2 = @{}; foreach ($m in $e2.Metriken) { $m2[$m.Id] = $m }
Check 'Effect later: start time 62 s -> about 40 s is better (only starts after the optimization count)' ($m2['BootGesamt'].Bewertung -eq 'besser' -and $m2['BootGesamt'].Nachher -ge 40 -and $m2['BootGesamt'].Nachher -lt 41)
Check 'Effect later: wait after the desktop 20 s -> 8 s is better' ($m2['BootNach'].Bewertung -eq 'besser' -and $m2['BootNach'].Nachher -eq 8.0)
Check 'Effect later: 4 starts counted, nothing open, 5 better' ($e2.BootsDanach -eq 4 -and $e2.Offen -eq 0 -and $e2.Besser -eq 5 -and $e2.Schlechter -eq 0)
$one = Get-PerfEffect $vor $spaet @($newBoots[0])
Check 'Effect: a single start after the optimization is not enough' ((@($one.Metriken | Where-Object { $_.Id -eq 'BootGesamt' })[0].Bewertung -eq 'offen') -and $one.BootHinweis -match 'so far: 1')

# ---------------------------------------------------------------- verdict: worse, mixed, busy PC, old snapshots
MkSnap 'vorher' $t0.AddDays(20) 80 @() $null 10 100 8.0 2.0 2.0 $true
MkSnap 'scan' $t0.AddDays(21) 60 @() $null 14 100 8.0 2.0 2.0 $true
$files = @(Get-Snapshots); $b2 = Read-Snapshot $files[3]; $c2 = Read-Snapshot $files[4]
$ew = Get-PerfEffect $b2 $c2 @()
Check 'Worse: more startup programs and less free space -> verdict worse' ($ew.Urteil -eq 'schlechter' -and $ew.Schlechter -eq 2 -and $ew.Kopfzeile -match 'No improvement')
$mixed = Get-PerfEffect $vor $c2 @()
Check 'Mixed: some better, some worse' ($mixed.Urteil -eq 'gemischt' -and $mixed.Kopfzeile -match 'Mixed result')
MkSnap 'vorher' $t0.AddDays(30) 80 @() $null 10 100 8.0 2.0 2.0 $true
MkSnap 'scan' $t0.AddDays(31) 80 @() $null 10 100 8.0 25.0 40.0 $false
$files = @(Get-Snapshots); $b3 = Read-Snapshot $files[5]; $c3 = Read-Snapshot $files[6]
$eb = Get-PerfEffect $b3 $c3 @()
$mb3 = @{}; foreach ($m in $eb.Metriken) { $mb3[$m.Id] = $m }
Check 'Busy PC: CPU/drive jump is not counted as worse, flagged as unsure' ($mb3['Cpu'].Bewertung -eq '=' -and $mb3['Cpu'].Unsicher -eq $true -and $mb3['Platte'].Bewertung -eq '=' -and $eb.Schlechter -eq 0)
foreach ($o in @($b2, $c2)) { foreach ($p in 'PlatteProzent', 'PlatteOpsProSek', 'Ruhig') { $o.Leerlauf.PSObject.Properties.Remove($p) } }   # snapshots of older versions
$old = Get-PerfEffect $b2 $c2 @()
Check 'Old snapshot without drive activity: that figure is open, the rest still works' (@($old.Metriken | Where-Object { $_.Id -eq 'Platte' })[0].Bewertung -eq 'offen' -and @($old.Metriken | Where-Object { $_.Id -eq 'Autostart' })[0].Bewertung -eq 'schlechter' -and $old.Urteil -eq 'schlechter')
Check 'Old snapshot: counts as calm (no false "busy" warning)' ((Get-PerfPoint $c2).Ruhig -eq $true)
$none = Get-PerfEffect $b3 $b3 @()
Check 'Same state before and after: verdict equal' ($none.Urteil -eq 'gleich' -and $none.Kopfzeile -match 'No measurable change')
Check 'No effect object: headline explains' ((Get-PerfHeadline $null) -match 'Not enough data yet' -and $null -eq (Get-PerfEffect $null $c2 @()))

# ---------------------------------------------------------------- comparison table: ids and tolerance
$cmp = @(Get-CompareMetrics $vor $nach)
$ids = @($cmp | ForEach-Object { $_.Id })
Check 'Comparison: every row has a unique id' (($ids.Count -eq @($ids | Select-Object -Unique).Count) -and -not @($cmp | Where-Object { -not $_.Id }).Count)
$cm = @{}; foreach ($m in $cmp) { $cm[$m.Id] = $m }
Check 'Comparison: idle noise is not rated (CPU +0.5, RAM -0.1)' ($cm['Cpu'].Delta -eq 0.5 -and $cm['Cpu'].Bewertung -eq '=' -and $cm['Ram'].Bewertung -eq '=')
Check 'Comparison: real change is rated (startup programs, free space, processes)' ($cm['Autostart'].Bewertung -eq 'besser' -and $cm['Frei'].Bewertung -eq 'besser' -and $cm['Prozesse'].Bewertung -eq 'besser')
Check 'Comparison: new row for drive activity and wait after the desktop' ($cm.ContainsKey('Platte') -and $cm.ContainsKey('BootNach') -and $cm['Platte'].Kennzahl -eq 'Drive activity at idle')

# ---------------------------------------------------------------- history data
$h = Read-SnapshotHistory
Check 'History: one point per snapshot with all 8 figures' (@($h.Punkte).Count -eq 7 -and @($h.Punkte[0].Werte.PSObject.Properties).Count -eq 8)
Check 'History: boots merged, unique and sorted' (@($h.Boots).Count -eq 9 -and ([datetime]$h.Boots[0].Zeit) -lt ([datetime]$h.Boots[-1].Zeit))
Check 'History: effect since the FIRST optimization, defs and headline included' ($null -ne $h.Effekt -and $h.Effekt.Basis -eq ([datetime]$vor.Zeit).ToString('o') -and @($h.Defs).Count -eq 8 -and $h.Kopfzeile.Length -gt 10)
Check 'History: calm flag of a busy snapshot is kept' (@($h.Punkte | Where-Object { $_.Ruhig -eq $false }).Count -eq 1)

# ---------------------------------------------------------------- console output and report
$out = New-Object System.Collections.Generic.List[string]
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { $out.Add($Text) }
Show-PerfEffect $e2
$txt = $out -join "`n"
Check 'Console: headline, table and ratings' ($txt -match 'Did WinTidy help\?' -and $txt -match 'Windows start until ready' -and $txt -match 'better')
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }
Remove-Item (Join-Path $Script:SnapDir '*') -Force
MkSnap 'vorher' $t0 78.3 $oldBoots 62000 18 220 9.8 3.0 5.0 $true
MkSnap 'nachher' $t0.AddHours(1) 86.1 $oldBoots 62000 9 205 9.7 3.5 4.0 $true
MkSnap 'scan' $t0.AddDays(5) 85.0 ($newBoots + $oldBoots) 40200 9 206 9.6 3.2 4.5 $true
New-Item -ItemType Directory -Force (Join-Path $Script:RunsDir '20261020-1800_apply') | Out-Null
$r = New-Report
$html = Get-Content $r -Raw -Encoding UTF8
Check 'Report: section "Did WinTidy help?" with verdict and table' ($html -match '<h2>Did WinTidy help\?</h2>' -and $html -match "class='verdict besser'" -and $html -match 'WinTidy helped: 5 of 8')
Check 'Report: trend section with 8 cards and charts' ($html -match 'Trend of the key figures' -and ([regex]::Matches($html, "class='card pc'")).Count -eq 8 -and ([regex]::Matches($html, "class='chart spark'")).Count -ge 7)
Check 'Report: key figure names and explanations present' ($html -match 'Programs starting with Windows' -and $html -match 'title=')
Set-WtLanguage 'de' (Join-Path $PSScriptRoot '..')
$r = New-Report
$html = Get-Content $r -Raw -Encoding UTF8
Check 'Report: German texts' ($html -match 'Hat WinTidy etwas gebracht\?' -and $html -match 'Verlauf der Kennzahlen' -and $html -match 'Laufwerksaktivit')
$e3 = Get-PerfEffect $vor $spaet $boots
Check 'German headline and date format' ($e3.Kopfzeile -match 'WinTidy hat etwas gebracht' -and $e3.Kopfzeile -match '20\.10\.2026')
Set-WtLanguage 'en'

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red } else { Write-Host 'All performance key figure tests passed' -ForegroundColor Green }
exit $fail
