# Test-GuiApi.ps1 - checks the interface to the app (Get-AllFindings, Invoke-FixSelection, restore preview)
# with test rules and replaced Windows functions. Runs without Windows. Usage: pwsh ./tests/Test-GuiApi.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-apitest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Friendly|GuiPreselectMedium|AreaNames|AppNames|DeviceClassNames|RestoreKeyAllow|Guid\w+|CoolingTestMin)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:Cfg = $Script:DefaultConfig
$Script:DataDir = $TestData; $Script:SnapDir = Join-Path $TestData 'snapshots'; $Script:RunsDir = Join-Path $TestData 'runs'
New-Item -ItemType Directory -Force $Script:SnapDir, $Script:RunsDir | Out-Null
$Script:Cache = @{}; $Script:IsAdmin = $true

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }

# Replace Windows parts
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }
function Start-Transcript { } ; function Stop-Transcript { }
function New-Snapshot([string]$Label, $Findings) { [pscustomobject]@{ Label = $Label; Score = @{ Wert = 80 }; Befunde = $Findings } }
function New-Report { $null }
function Get-CompareMetrics($a, $b) { @() }
$Script:Ctx = [pscustomobject]@{ Server = $false; Verwaltet = $false; Akku = $false; Laptop = $false; AnderesKonto = $false; NeustartAusstehend = $false; Hinweise = @() }
function Get-WtContext { $Script:Ctx }
$Script:RpFehler = $null
function Invoke-Checkpoint { if ($Script:RpSchutz) { $Script:ComputerschutzEingeschaltet = $true }; $Script:RpFehler }
function Get-HardwarePoints { @() }

$Script:Done = New-Object System.Collections.Generic.List[string]
$Script:Rules = @(
    [pscustomobject]@{ Id = 'CLN-A'; Kategorie = 'Speicher'; Titel = 'A'; Warum = 'a'; Risiko = 'Niedrig'; Admin = $false; Standard = $true
        Detect = { New-Item2 'a1' 100; New-Item2 'a2' 200 }; Fix = { param($it) $Script:Done.Add($it.Label); 'ok' } }
    [pscustomobject]@{ Id = 'CLN-LANG'; Kategorie = 'Speicher'; Titel = 'Lang'; Warum = 'l'; Risiko = 'Niedrig'; Admin = $true; Standard = $true; Dauer = '10 minutes'
        Detect = { New-Item2 'lang1' 0 }; Fix = { param($it) $Script:Done.Add($it.Label); 'ok' } }
    [pscustomobject]@{ Id = 'STA-M'; Kategorie = 'Autostart'; Titel = 'M'; Warum = 'm'; Risiko = 'Mittel'; Admin = $false; Standard = $true
        Detect = { New-Item2 'm1' 0; New-Item2 'm2' 0 }; Fix = { param($it) if ($it.Label -eq 'm2') { throw 'broken' }; $Script:Done.Add($it.Label); 'aus' } }
    [pscustomobject]@{ Id = 'CLN-SKIP'; Kategorie = 'Speicher'; Titel = 'S'; Warum = 's'; Risiko = 'Niedrig'; Admin = $false; Standard = $true
        Detect = { New-Item2 'treiber' 0 }; Fix = { param($it) throw 'SKIP:Still in use' } }
    [pscustomobject]@{ Id = 'HW-X'; Kategorie = 'Hardware'; Titel = 'X'; Warum = 'x'; Risiko = 'Info'; Admin = $false; Standard = $true
        Detect = { New-Item2 'gut' 0 @{ Stufe = 'ok' }; New-Item2 'heiss' 0 @{ Stufe = 'krit' } }; Fix = $null }
)
$all = @{ Id = 'CLN-A'; Indexes = @(0, 1) }, @{ Id = 'CLN-LANG'; Indexes = @(0) }, @{ Id = 'STA-M'; Indexes = @(0, 1) }
$mitSkip = $all + @(@{ Id = 'CLN-SKIP'; Indexes = @(0) })

# 1) Findings, level, duration
$f = @(Get-AllFindings $false $null)
Check 'Get-AllFindings: 5 rules with findings' ($f.Count -eq 5)
Check 'Info items carry a level' ((($f | Where-Object Id -eq 'HW-X').Items | ForEach-Object Stufe) -join ',' -eq 'ok,krit')
Check 'Duration is passed through' (($f | Where-Object Id -eq 'CLN-LANG').Dauer -eq '10 minutes')
Check 'Low preselected, Medium without list not' (($f | Where-Object Id -eq 'CLN-A').Items[0].Vorauswahl -and -not ($f | Where-Object Id -eq 'STA-M').Items[0].Vorauswahl)

# 2) Restore point failed -> nothing changed, no run folder
$Script:RpFehler = 'service off'
$r = Invoke-FixSelection $all $true $null $null $false
Check 'RP-FEHLT without change' ($r.Status -eq 'RP-FEHLT' -and $Script:Done.Count -eq 0 -and $r.Meldung -eq 'service off')
Check 'RP-FEHLT leaves no run behind' (@(Get-ChildItem $Script:RunsDir -Directory).Count -eq 0)

# 3) With OhneRP: run everything, one error, details
Start-Sleep -Milliseconds 1100
$r = Invoke-FixSelection $all $true { param($i, $n, $t, $id) $Script:LastProg = $id } $null $true
Check 'OhneRP: status OK, 4 OK, 1 error' ($r.Status -eq 'OK' -and $r.OK -eq 4 -and $r.Fehler -eq 1) ($r | Select-Object Status, OK, Fehler | ConvertTo-Json -Compress)
Check 'Details per step' (@($r.Details).Count -eq 5 -and (@($r.Details | Where-Object Status -eq 'Fehler').Meldung -eq 'broken'))
Check 'Progress reports the rule ID' ($Script:LastProg -eq 'CORE')
Check 'zusammenfassung.json written' (Test-Path (Join-Path $Script:RunDir 'zusammenfassung.json'))
Start-Sleep -Milliseconds 1100
$Script:Done.Clear()
$r = Invoke-FixSelection $mitSkip $false $null $null $false
Check 'SKIP: counted as skipped, not as error' ($r.Fehler -eq 1 -and ($r.Details | Where-Object Objekt -eq 'treiber').Status -eq 'Uebersprungen') ($r.Details | ConvertTo-Json -Compress)
# RP-FEHLT after System Protection was turned on: the hint is kept on the second call
$Script:RpFehler = 'broken'; $Script:RpSchutz = $true
Start-Sleep -Milliseconds 1100
$r1 = Invoke-FixSelection $all $true $null $null $false
$Script:RpSchutz = $false
Start-Sleep -Milliseconds 1100
$r2 = Invoke-FixSelection $all $true $null $null $true
Check 'System Protection hint is kept after RP-FEHLT' ($r1.Status -eq 'RP-FEHLT' -and $r1.ComputerschutzEingeschaltet -and $r2.ComputerschutzEingeschaltet)
$Script:RpFehler = $null
# Cancelled already at the restore point: no change, no measurement
$Script:Done.Clear()
$ctl0 = [hashtable]::Synchronized(@{ Cancel = $false })
Start-Sleep -Milliseconds 1100
$r = Invoke-FixSelection $all $true { param($i, $n, $t, $id) if ($id -eq 'CORE') { $ctl0.Cancel = $true } } $ctl0 $false
Check 'Cancel at the restore point: nothing changed' ($r.Status -eq 'ABGEBROCHEN' -and $Script:Done.Count -eq 0 -and $null -eq $r.Vorher)

# 4) Battery: long steps skipped and not preselected
$Script:Done.Clear(); $Script:RpFehler = $null; $Script:Ctx.Akku = $true
$f = @(Get-AllFindings $false $null)
Check 'Battery: long rule not preselected' (-not ($f | Where-Object Id -eq 'CLN-LANG').Items[0].Vorauswahl)
Start-Sleep -Milliseconds 1100
$r = Invoke-FixSelection $all $true $null $null $false
Check 'Battery: long step skipped' (($r.Details | Where-Object Objekt -eq 'lang1').Status -eq 'Uebersprungen' -and -not $Script:Done.Contains('lang1'))
$Script:Ctx.Akku = $false

# 5) Cancel: after the first step
$Script:Done.Clear()
$ctl = [hashtable]::Synchronized(@{ Cancel = $false })
Start-Sleep -Milliseconds 1100
$r = Invoke-FixSelection $all $true { param($i, $n, $t, $id) if ($i -ge 1 -and $id -ne 'CORE') { $ctl.Cancel = $true } } $ctl $false
Check 'Cancel: status ABGEBROCHEN, only 1 step' ($r.Status -eq 'ABGEBROCHEN' -and $Script:Done.Count -eq 1 -and @($r.Details | Where-Object Status -eq 'Abgebrochen').Count -eq 4) ($r.Details | ConvertTo-Json -Compress)

# 6) Server and company PC
$Script:Ctx.Server = $true
$r = Invoke-FixSelection $all $true $null $null $false
Check 'Server: GESPERRT' ($r.Status -eq 'GESPERRT')
$Script:Ctx.Server = $false; $Script:Ctx.Verwaltet = $true
$f = @(Get-AllFindings $false $null)
Check 'Company PC: only storage/low and info' ((($f | ForEach-Object Id) -join ',') -eq 'CLN-A,CLN-LANG,CLN-SKIP,HW-X') (($f | ForEach-Object Id) -join ',')
$Script:Ctx.Verwaltet = $false

# 7) Restore preview recognizes service and power setting
$d = Join-Path $Script:RunsDir '20990101-000000_apply'; New-Item -ItemType Directory -Force (Join-Path $d 'backup') | Out-Null
'x' | Out-File (Join-Path (Join-Path $d 'backup') 'StartupApproved_Run.reg')
@('{"Regel":"SVC-ORPHAN","Objekt":"Foo","Status":"Undo-Info","Undo":{"Typ":"Dienst","Name":"Foo","StartMode":"Auto"}}', '{"Regel":"HW-COOLPOLICY","Objekt":"Kuehlrichtlinie (Netzbetrieb)","Status":"Undo-Info","Undo":{"Typ":"PowerSetting","Schema":"s","Sub":"a","Setting":"b","AC":0}}') | Out-File (Join-Path $d 'actions.jsonl') -Encoding utf8
$p = @(Get-RestorePreview '20990101-000000')
Check 'Restore preview: Setting, Power setting, Background service' ((($p | ForEach-Object Art) -join ',') -eq 'Background service,Power setting,Setting') (($p | ForEach-Object Art) -join ',')
Check 'Restore preview: readable names' (($p | Where-Object Art -eq 'Power setting').Objekt -eq 'Cooling on mains power')
# Runs with single-value undo: old .reg backups are no longer imported
'{"Regel":"STA-HEAVY","Objekt":"Spotify","Status":"Undo-Info","Undo":{"Typ":"RegValue","Key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run","Name":"Spotify","Vorher":null,"Nachher":{"Art":"Binary","Wert":"AwAAAA=="}}}' | Out-File (Join-Path $d 'actions.jsonl') -Append -Encoding utf8
$p = @(Get-RestorePreview '20990101-000000')
Check 'Single-value undo replaces .reg import' (-not ($p | Where-Object { $_.Objekt -eq 'StartupApproved Run' }) -and ($p | Where-Object { $_.Art -eq 'Startup' -and $_.Objekt -match 'Spotify' }))
Check 'Registry allow-list: StartupApproved allowed, IFEO not' (((ConvertTo-RegKeyText 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run') -match $Script:RestoreKeyAllow) -and -not ((ConvertTo-RegKeyText 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\x') -match $Script:RestoreKeyAllow))
New-Item -ItemType Directory -Force (Join-Path $Script:RunsDir '20990102-000000_apply') | Out-Null
Check 'Registry allow-list: .. is rejected' (-not (Test-RegKeyAllowed 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\..\..'))
$tmpR = Join-Path $TestData 'kette'; New-Item -ItemType Directory -Force (Join-Path $tmpR 'a') | Out-Null; 'x' | Out-File (Join-Path $tmpR 'a/f.txt')
Check 'Path chain: file below the root ok, outside not' ((Test-PathChainNoReparse $tmpR (Join-Path $tmpR 'a/f.txt')) -and -not (Test-PathChainNoReparse (Join-Path $tmpR 'a') (Join-Path $tmpR 'f.txt')))
Check 'Run ID not unique = not found' ($null -eq (Resolve-RunDir '2099'))
Check 'Run ID exact = found' ((Resolve-RunDir '20990101-000000').Name -eq '20990101-000000_apply')
$h = Get-RunList | Where-Object Lauf -eq '20990101-000000'
Check 'History knows reversible changes' ($h.Umkehrbar -ge 3)

# 8) Restore with admin rights only applies undo records from a protected data folder (also with -DataPath)
function Test-WtDataRootSafe([string]$Path) { $Script:SafeMock }
$Script:SafeMock = $false; $Script:IsAdmin = $true; $Script:DataDirProtected = $false
$Script:DataDirIsDefault = $false; $Script:RestoreRunId = '20990101-000000'
Check 'Restore: unprotected -DataPath is blocked' ((Invoke-Restore).Status -eq 'GESPERRT')
$Script:DataDirIsDefault = $true
Check 'Restore: unprotected default data folder is blocked' ((Invoke-Restore).Status -eq 'GESPERRT')
Check 'Restore: blocked runs leave no undo marker' (-not (Test-Path (Join-Path $d 'rueckgaengig.json')))

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red } else { Write-Host 'All API tests passed' -ForegroundColor Green }
exit $fail
