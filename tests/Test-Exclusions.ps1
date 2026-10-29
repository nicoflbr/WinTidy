# Test-Exclusions.ps1 - exclusions ("Ausnahmen", 1.12): storage, item keys, filtering of findings (app and command line),
# fix defense, score (Abzug/Regel/Objekt, startup items, WertOhneAusnahmen), history/report with recomputed scores,
# the app interface and the command line mode. Runs without Windows. Usage: pwsh ./tests/Test-Exclusions.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-exclusionstest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TestData | Out-Null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
$Script:Lang = 'en'; $Script:De = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Friendly|AppNames|DeviceClassNames|AreaNames|GuiPreselectMedium|QuarantineSuffix)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:RealRules = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Child -is [System.Management.Automation.Language.HashtableAst] -and $n.Extent.Text -match "^\[pscustomobject\]@\{ Id = '[A-Z]+-[A-Z0-9-]+'; Kategorie" }, $true) | ForEach-Object { & ([scriptblock]::Create($_.Extent.Text)) })
$Script:Rules = $Script:RealRules
$Script:Cfg = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $Script:Cfg[$k] = $Script:DefaultConfig[$k] }
$Script:Version = '1.12.0'
$Script:DataDir = $TestData; $Script:SnapDir = Join-Path $TestData 'snapshots'; $Script:RunsDir = Join-Path $TestData 'runs'; $Script:RunDir = $null
New-Item -ItemType Directory -Force $Script:SnapDir, $Script:RunsDir | Out-Null
$Script:Cache = @{}; $Script:IsAdmin = $true; $Script:RunId = '20261029-120000'
$env:SystemDrive = 'C:'; $env:COMPUTERNAME = 'TESTPC'

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }
$Script:Out = New-Object System.Collections.Generic.List[string]
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { $Script:Out.Add($Text) }
function Start-Transcript { } ; function Stop-Transcript { }
$Script:Records = New-Object System.Collections.Generic.List[object]
function Add-ActionRecord { param($Regel, $Objekt, $Status, $Bytes, $Msg, $Undo) $Script:Records.Add([pscustomobject]@{ Regel = $Regel; Objekt = $Objekt; Status = $Status; Meldung = $Msg }); $true }
$ExPath = Get-WtExclusionPath

# 1) Storage
Check 'Path is ausnahmen.json in the data folder' ($ExPath -eq (Join-Path $TestData 'ausnahmen.json'))
Check 'No file: empty list, no warning' (@(Read-WtExclusions).Count -eq 0 -and $Script:Out.Count -eq 0)
$e1 = Add-WtExclusion -Art Objekt -Regel 'STA-HEAVY' -Schluessel '[HKCU Run] Spotify -> C:\x.exe' -Anzeige 'Spotify' -Titel 'Review startup'
Check 'Add: entry returned and file written' ($e1.Art -eq 'Objekt' -and (Test-Path $ExPath) -and -not (Test-Path ($ExPath + '.tmp')))
$bytes = [IO.File]::ReadAllBytes($ExPath)
Check 'File is UTF-8 without BOM' (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB))
$j = Get-Content $ExPath -Raw | ConvertFrom-Json
Check 'Format, version and German field names' ($j.Format -eq 'WinTidy-Ausnahmen' -and $j.Version -eq 1 -and @($j.Eintraege).Count -eq 1 -and $j.Eintraege[0].Schluessel -like '*Spotify*' -and $j.Eintraege[0].Zeit)
$Script:Exclusions = $null
$r = @(Read-WtExclusions)
Check 'Round trip after resetting the cache' ($r.Count -eq 1 -and $r[0].Regel -eq 'STA-HEAVY' -and $r[0].Anzeige -eq 'Spotify' -and $r[0].Titel -eq 'Review startup')
$null = Add-WtExclusion -Art Objekt -Regel 'STA-HEAVY' -Schluessel '[hkcu run] SPOTIFY -> c:\X.exe'
Check 'Add is idempotent and ignores case' (@(Read-WtExclusions).Count -eq 1)
$null = Add-WtExclusion -Art Regel -Regel 'SEC-EXECPOLICY' -Schluessel 'ignored' -Titel 'Policy'
$null = Add-WtExclusion -Art Abzug -Regel 'SCORE-UAC'
$x = @(Read-WtExclusions)
Check 'Regel/Abzug entries have no key' ($x.Count -eq 3 -and ($x | Where-Object Art -ne 'Objekt' | Where-Object Schluessel).Count -eq 0)
$err = ''; try { $null = Add-WtExclusion -Art 'Foo' -Regel 'STA-HEAVY' } catch { $err = $_.Exception.Message }
Check 'Invalid type rejected' ($err -like '*Foo*')
foreach ($bad in 'sta-heavy', 'STA', 'STA-HEAVY; rm', '', '-X') { $err = ''; try { $null = Add-WtExclusion -Art Regel -Regel $bad } catch { $err = $_.Exception.Message }; Check "Invalid rule id rejected: '$bad'" ([bool]$err) }
$err = ''; try { $null = Add-WtExclusion -Art Objekt -Regel 'STA-HEAVY' } catch { $err = $_.Exception.Message }
Check 'Single point without key rejected' ([bool]$err -and @(Read-WtExclusions).Count -eq 3)
Check 'Test-WtExcluded: item by rule+key (ignoring case)' ((Test-WtExcluded 'STA-HEAVY' '[HKCU Run] Spotify -> C:\x.exe') -and -not (Test-WtExcluded 'STA-HEAVY' 'other') -and -not (Test-WtExcluded 'CLN-TEMP' '[HKCU Run] Spotify -> C:\x.exe'))
Check 'Test-WtExcluded: whole rule excludes every key, -ItemOnly does not' ((Test-WtExcluded 'SEC-EXECPOLICY' 'anything') -and -not (Test-WtExcluded 'SEC-EXECPOLICY' 'anything' $null -ItemOnly))
Check 'Test-WtExcluded: a score deduction is not a rule' (-not (Test-WtExcluded 'SCORE-UAC' 'x'))
Check 'Remove: true when removed, idempotent' ((Remove-WtExclusion -Art Abzug -Regel 'SCORE-UAC') -and -not (Remove-WtExclusion -Art Abzug -Regel 'SCORE-UAC') -and @(Read-WtExclusions).Count -eq 2)
Check 'Remove: item needs its key' (-not (Remove-WtExclusion -Art Objekt -Regel 'STA-HEAVY' -Schluessel 'nope') -and (Remove-WtExclusion -Art Objekt -Regel 'STA-HEAVY' -Schluessel '[HKCU Run] SPOTIFY -> C:\x.exe') -and @(Read-WtExclusions).Count -eq 1)
Save-WtExclusions @()
# damaged files: behave as if there were none, warn, keep the old file when writing again
$Script:Out.Clear(); $Script:Exclusions = $null
Set-Content $ExPath '{ this is not json' -Encoding UTF8
Check 'Corrupt JSON: empty list and a warning, does not throw' (@(Read-WtExclusions).Count -eq 0 -and ($Script:Out -join ' ') -match 'could not be read')
$null = Add-WtExclusion -Art Regel -Regel 'CLN-TEMP'
Check 'Writing over a damaged file keeps a copy' ((Test-Path ($ExPath + '.defekt')) -and (Get-Content ($ExPath + '.defekt') -Raw) -match 'not json' -and @(Read-WtExclusions).Count -eq 1)
$Script:Out.Clear(); $Script:Exclusions = $null
Set-Content $ExPath '{"Format":"Something-Else","Version":1,"Eintraege":[{"Art":"Regel","Regel":"CLN-TEMP"}]}' -Encoding UTF8
Check 'Wrong format: empty list and a warning' (@(Read-WtExclusions).Count -eq 0 -and $Script:Out.Count -ge 1)
$Script:Out.Clear(); $Script:Exclusions = $null
Set-Content $ExPath '{"Format":"WinTidy-Ausnahmen","Version":2,"Eintraege":[{"Art":"Regel","Regel":"CLN-TEMP"}]}' -Encoding UTF8
Check 'Newer version: empty list and a warning' (@(Read-WtExclusions).Count -eq 0 -and $Script:Out.Count -ge 1)
$Script:Out.Clear(); $Script:Exclusions = $null
Set-Content $ExPath '{"Format":"WinTidy-Ausnahmen","Version":1,"Eintraege":[{"Art":"Regel","Regel":"CLN-TEMP"},{"Art":"Bogus","Regel":"CLN-TEMP"},{"Art":"Regel"},{"Art":"Regel","Regel":"lower-case"},{"Art":"Objekt","Regel":"STA-HEAVY"},{"Art":"Objekt","Regel":"STA-HEAVY","Schluessel":"k"},null]}' -Encoding UTF8
$x = @(Read-WtExclusions)
Check 'Malformed entries are dropped, valid ones stay' ($x.Count -eq 2 -and $x[0].Regel -eq 'CLN-TEMP' -and $x[1].Schluessel -eq 'k' -and $Script:Out.Count -eq 0)
Remove-Item $ExPath, ($ExPath + '.defekt') -Force; $Script:Exclusions = $null
Check 'Missing file again: empty' (@(Read-WtExclusions).Count -eq 0)

# 2) Item keys
$k = { param($i) Get-WtItemKey $i }
Check 'Key: explicit Schluessel wins' ((& $k ([pscustomobject]@{ Schluessel = 'sk'; Technik = 't'; Data = 'd'; Label = 'l' })) -eq 'sk')
Check 'Key: Technik next' ((& $k ([pscustomobject]@{ Technik = '[HKCU Run] A -> b'; Data = 'd'; Label = 'l' })) -eq '[HKCU Run] A -> b')
Check 'Key: string and number Data' ((& $k ([pscustomobject]@{ Data = 'C:\Temp'; Label = 'l' })) -eq 'C:\Temp' -and (& $k ([pscustomobject]@{ Data = 42; Label = 'l' })) -eq '42')
Check 'Key: dictionary Data with Name' ((& $k ([pscustomobject]@{ Data = @{ Name = 'foo'; Stufe = 'warn' }; Label = 'l' })) -eq 'Name=foo')
Check 'Key: dictionary Data combines Key and Name' ((& $k ([pscustomobject]@{ Data = @{ Key = 'HKCU:\x'; Name = 'n' }; Label = 'l' })) -eq 'Key=HKCU:\x;Name=n')
Check 'Key: pscustomobject Data with Path' ((& $k ([pscustomobject]@{ Data = [pscustomobject]@{ Path = 'P:\x' }; Label = 'l' })) -eq 'Path=P:\x')
Check 'Key: Data without identifying property falls back to the label' ((& $k ([pscustomobject]@{ Data = @{ Stufe = 'warn' }; Label = 'Some text' })) -eq 'Some text' -and (& $k ([pscustomobject]@{ Data = $null; Label = 'Only label' })) -eq 'Only label')
Check 'Key: New-Item2 carries Schluessel' ((New-Item2 'x' 0 $null $null 'kk').Schluessel -eq 'kk')
$gk = @(& ($Script:RealRules | Where-Object Id -eq 'SYS-GAMEDVR').Detect)
Check 'Startup key: same text as the Technik of the rules' ((Get-StartupKey ([pscustomobject]@{ Ort = 'HKCU Run'; Name = 'Spotify'; Ziel = 'C:\s.exe' })) -eq '[HKCU Run] Spotify -> C:\s.exe')

# 3) Findings of the app (mock rules)
$Script:Ctx = [pscustomobject]@{ Server = $false; Verwaltet = $false; Akku = $false; Laptop = $false; AnderesKonto = $false; NeustartAusstehend = $false; Hinweise = @() }
function Get-WtContext { $Script:Ctx }
function Get-HardwarePoints { @() }
function New-Snapshot([string]$Label, $Findings) { [pscustomobject]@{ Label = $Label; Score = @{ Wert = 80 }; Befunde = $Findings } }
function New-Report { $null }
function Get-CompareMetrics($a, $b) { @() }
function Invoke-Checkpoint { $null }
$Script:Done = New-Object System.Collections.Generic.List[string]
$Script:Rules = @(
    [pscustomobject]@{ Id = 'CLN-A'; Kategorie = 'Speicher'; Titel = 'A'; Warum = 'a'; Risiko = 'Niedrig'; Admin = $false; Standard = $true
        Detect = { New-Item2 'a1' 100 'C:\a1'; New-Item2 'a2' 200 'C:\a2' }; Fix = { param($it) $Script:Done.Add($it.Label); 'ok' } }
    [pscustomobject]@{ Id = 'STA-M'; Kategorie = 'Autostart'; Titel = 'M'; Warum = 'm'; Risiko = 'Mittel'; Admin = $false; Standard = $true
        Detect = { New-Item2 'm1' 0 @{ Name = 'one' }; New-Item2 'm2' 0 $null '[Run] two -> x' }; Fix = { param($it) $Script:Done.Add($it.Label); 'ok' } }
    [pscustomobject]@{ Id = 'CLN-ALL'; Kategorie = 'Speicher'; Titel = 'All'; Warum = 'x'; Risiko = 'Niedrig'; Admin = $false; Standard = $true
        Detect = { New-Item2 'z1' 0 'z1' }; Fix = { param($it) $Script:Done.Add($it.Label); 'ok' } }
    [pscustomobject]@{ Id = 'HW-X'; Kategorie = 'Hardware'; Titel = 'X'; Warum = 'x'; Risiko = 'Info'; Admin = $false; Standard = $true
        Detect = { New-Item2 'Fan stopped' 0 @{ Stufe = 'krit' } $null 'fan-stop'; New-Item2 'Drive warm' 0 @{ Stufe = 'warn' } $null 'drive-warm'; New-Item2 'Fine' 0 @{ Stufe = 'ok' } }; Fix = $null }
    [pscustomobject]@{ Id = 'DBL-T'; Kategorie = 'System'; Seite = 'Debloat'; Titel = 'T'; Warum = 't'; Risiko = 'Niedrig'; Admin = $false; Standard = $false
        Detect = { New-Item2 'tweak' 0 'tw1' }; Fix = { param($it) $Script:Done.Add($it.Label); 'ok' } }
)
$Script:LastFindings = @(); $Script:LastExcludedHits = @(); $Script:ExclChecked = @{}
$f = @(Get-AllFindings $false $null)
Check 'Without exclusions: everything is offered, items carry their key' ($f.Count -eq 4 -and ($f | Where-Object Id -eq 'CLN-A').Items[0].Schluessel -eq 'C:\a1' -and ($f | Where-Object Id -eq 'STA-M').Items[0].Schluessel -eq 'Name=one' -and ($f | Where-Object Id -eq 'STA-M').Items[1].Schluessel -eq '[Run] two -> x')
Check 'No exclusions: no hits, nothing excluded' (@($Script:LastExcludedHits).Count -eq 0 -and ($f | Where-Object Id -eq 'CLN-A').Ausgeschlossen -eq 0)
$null = Add-WtExclusion -Art Objekt -Regel 'CLN-A' -Schluessel 'C:\a1' -Anzeige 'a1'
$null = Add-WtExclusion -Art Regel -Regel 'CLN-ALL'
$null = Add-WtExclusion -Art Objekt -Regel 'HW-X' -Schluessel 'fan-stop' -Anzeige 'Fan stopped'
$null = Add-WtExclusion -Art Objekt -Regel 'HW-X' -Schluessel 'drive-warm' -Anzeige 'Drive warm'
$null = Add-WtExclusion -Art Objekt -Regel 'DBL-T' -Schluessel 'tw1' -Anzeige 'tweak'
$f = @(Get-AllFindings $false $null)
$a = $f | Where-Object Id -eq 'CLN-A'
Check 'Excluded item is hidden, the other stays (index and key intact)' ($a.Items.Count -eq 1 -and $a.Items[0].Label -eq 'a2' -and $a.Items[0].Index -eq 0 -and $a.Ausgeschlossen -eq 1 -and $a.Bytes -eq 200)
Check 'Rule with all items excluded does not appear' (-not ($f | Where-Object Id -eq 'CLN-ALL') -and $f.Count -eq 3)
Check 'Info item (warn) excluded by its explicit key; the critical one stays visible' ((($f | Where-Object Id -eq 'HW-X').Items | ForEach-Object Label) -join ',' -eq 'Fan stopped,Fine')
$h = @($Script:LastExcludedHits)
Check 'Hits collected for the normal page' ($h.Count -eq 3 -and -not ($h | Where-Object Schluessel -eq 'fan-stop') -and ($h | Where-Object { $_.Regel -eq 'CLN-A' -and $_.Schluessel -eq 'C:\a1' -and $_.Label -eq 'a1' }) -and ($h | Where-Object Regel -eq 'CLN-ALL'))
$d = @(Get-AllFindings $false $null 'Debloat')
Check 'Debloat page: excluded item hidden' ($d.Count -eq 0)
$h2 = @($Script:LastExcludedHits)
Check 'Hits of both pages are merged, not wiped' ($h2.Count -eq 4 -and ($h2 | Where-Object Regel -eq 'DBL-T') -and ($h2 | Where-Object Regel -eq 'CLN-A'))
$f = @(Get-AllFindings $false $null)
Check 'Re-checking the normal page keeps the Debloat hits and does not duplicate' (@($Script:LastExcludedHits).Count -eq 4)
$bf = @(ConvertTo-Befunde $f)
Check 'Befunde: only kept items, count of excluded added, keys listed' ((($bf | Where-Object Regel -eq 'CLN-A').Anzahl -eq 1) -and (($bf | Where-Object Regel -eq 'CLN-A').Ausgeschlossen -eq 1) -and ((($bf | Where-Object Regel -eq 'CLN-A').Schluessel) -join ',' -eq 'C:\a2'))

# 4) Fix defense: excluded after the check
$f = @(Get-AllFindings $false $null)
$null = Remove-WtExclusion -Art Regel -Regel 'CLN-ALL'
$f = @(Get-AllFindings $false $null)
$Script:Done.Clear(); $Script:Records.Clear()
$null = Add-WtExclusion -Art Objekt -Regel 'CLN-A' -Schluessel 'C:\a2' -Anzeige 'a2'
$sel = @(@{ Id = 'CLN-A'; Indexes = @(0) }, @{ Id = 'CLN-ALL'; Indexes = @(0) }, @{ Id = 'STA-M'; Indexes = @(0, 1) })
$r = Invoke-FixSelection $sel $false $null $null $true
Check 'Item excluded after the check: Fix is not called' (-not $Script:Done.Contains('a2') -and $Script:Done.Contains('z1') -and $Script:Done.Contains('m1') -and $Script:Done.Contains('m2'))
$det = $r.Details | Where-Object Objekt -eq 'a2'
Check 'Skipped with status Uebersprungen and a message' ($det.Status -eq 'Uebersprungen' -and $det.Meldung -match 'Excluded' -and ($Script:Records | Where-Object { $_.Objekt -eq 'a2' -and $_.Status -eq 'Uebersprungen' }))
Check 'Not counted as error' ($r.Fehler -eq 0 -and $r.Status -eq 'OK')
Start-Sleep -Milliseconds 1100
$null = Add-WtExclusion -Art Regel -Regel 'STA-M'
$Script:Done.Clear()
$r = Invoke-FixSelection @(@{ Id = 'STA-M'; Indexes = @(0, 1) }) $false $null $null $true
Check 'Whole rule excluded after the check: nothing fixed' ($Script:Done.Count -eq 0 -and @($r.Details | Where-Object Status -eq 'Uebersprungen').Count -eq 2)
$null = Remove-WtExclusion -Art Regel -Regel 'STA-M'

# 5) Command line: Invoke-Rules never fixes an excluded item, also not with -Yes
$null = Remove-WtExclusion -Art Objekt -Regel 'CLN-A' -Schluessel 'C:\a2'
$Yes = $true; $Rule = $null; $ExcludeRule = $null; $IncludeMedium = $false
$Script:CliContext = $null
$Script:Done.Clear(); $Script:Out.Clear()
$Script:Rules = @($Script:Rules | Where-Object { $_.Id -in 'CLN-A', 'CLN-ALL' })
$null = Add-WtExclusion -Art Regel -Regel 'CLN-ALL'
function Get-SelectedRules([switch]$ForApply) { $Script:Rules }
$res = Invoke-Rules $true
Check 'Invoke-Rules -Yes: only the kept item is fixed' ($Script:Done.Count -eq 1 -and $Script:Done[0] -eq 'a2') ($Script:Done -join ',')
Check 'Invoke-Rules: a gray line for every rule with excluded points' (@($Script:Out | Where-Object { $_ -match '1 excluded point\(s\) not shown \(see -Mode Exclusions\)' }).Count -eq 2) ($Script:Out -join '|')
$bfc = $res.Befunde | Where-Object Regel -eq 'CLN-A'
Check 'Invoke-Rules: findings only with kept items, count of excluded, keys' ($bfc.Anzahl -eq 1 -and $bfc.Ausgeschlossen -eq 1 -and ($bfc.Schluessel -join ',') -eq 'C:\a2' -and -not ($res.Befunde | Where-Object Regel -eq 'CLN-ALL'))
$Script:Done.Clear(); $Yes = $false
$res = Invoke-Rules $false
Check 'Invoke-Rules preview: excluded items are not listed' (-not ($Script:Out -join '|' -match 'a1') -and $Script:Done.Count -eq 0)
$Yes = $false
Remove-Item $ExPath -Force; $Script:Exclusions = $null

# 6) Score
function MkScoreSnap {
    [pscustomobject]@{ Zeit = '2026-10-29T10:00:00'; Laufwerke = @(); Boot = [pscustomobject]@{ Mittel5 = $null }
        Autostart = [pscustomobject]@{ Aktiv = 12; Verwaist = 0; Liste = @(1..12 | ForEach-Object { [pscustomobject]@{ Name = "App$_"; Art = 'Registry'; Ort = 'HKCU Run'; Ziel = "C:\app$_.exe"; Zustand = 'ok'; Aktiv = $true; DegradationMs = 0 } }) }
        Ereignisse = [pscustomobject]@{ FehlerSystem7T = 0; FehlerAnwendung7T = 0 }; Treiber = [pscustomobject]@{ Duplikate = 0; Geistergeraete = 0 }; Speicher = [pscustomobject]@{ PapierkorbBytes = 0 }
        Stabilitaet = [pscustomobject]@{ Warnsignale = @([pscustomobject]@{ Text = 'Blue screen'; Anzahl = 1; Schluessel = 'bluescreen' }, [pscustomobject]@{ Text = 'Drive errors'; Anzahl = 2; Schluessel = 'drive-errors' }) }
        Hardware = [pscustomobject]@{ Punkte = @([pscustomobject]@{ Stufe = 'krit'; Text = 'Fan stopped'; Wertung = 'dauer'; Schluessel = 'fan-stop' }, [pscustomobject]@{ Stufe = 'warn'; Text = 'Drive warm'; Wertung = 'dauer'; Schluessel = 'drive-warm' }) }
        Sicherheit = [pscustomobject]@{ SecureBoot = $false; DefenderEchtzeit = $true; AndererVirenschutz = $false; AusfuehrungsrichtlinieCU = 'Bypass'; UacAus = $true; FirewallProfileAus = 2 } }
}
$s = MkScoreSnap
$sc = Get-HealthScore $s @()
# 100 - autostart 5 - secure boot 4 - UAC 8 - firewall 10 - policy 3 - warnings 4 - hardware 5 - 1
Check 'Score without exclusions' ($sc.Wert -eq 60 -and $sc.WertOhneAusnahmen -eq 60 -and @($sc.Ausgeschlossen).Count -eq 0) (($sc.Abzuege | ForEach-Object { "$($_.Id)=$($_.Punkte)" }) -join ' ')
Check 'Every deduction has an Id' (@($sc.Abzuege | Where-Object { -not $_.Id }).Count -eq 0 -and @($sc.Abzuege).Count -eq 8)
$e = @([pscustomobject]@{ Art = 'Abzug'; Regel = 'SCORE-UAC'; Schluessel = '' })
$sc = Get-HealthScore $s $e
Check 'Abzug exclusion: deduction accepted, 0 points, listed' ($sc.Wert -eq 68 -and $sc.WertOhneAusnahmen -eq 60 -and @($sc.Ausgeschlossen).Count -eq 1 -and $sc.Ausgeschlossen[0].Id -eq 'SCORE-UAC' -and $sc.Ausgeschlossen[0].Punkte -eq 8 -and $sc.Ausgeschlossen[0].Quelle -eq 'Abzug' -and -not ($sc.Abzuege | Where-Object Id -eq 'SCORE-UAC')) ("W=$($sc.Wert) O=$($sc.WertOhneAusnahmen) A=" + (@($sc.Ausgeschlossen) | ForEach-Object { "$($_.Id)/$($_.Quelle)/$($_.Punkte)" }) -join ' ') + ' Z=' + ((@($sc.Abzuege) | ForEach-Object { "$($_.Id)" }) -join ',')
$e = @([pscustomobject]@{ Art = 'Regel'; Regel = 'SEC-EXECPOLICY'; Schluessel = '' })
$sc = Get-HealthScore $s $e
Check 'Regel exclusion SEC-EXECPOLICY covers the deduction of the same Id' ($sc.Wert -eq 63 -and $sc.Ausgeschlossen[0].Id -eq 'SEC-EXECPOLICY' -and $sc.Ausgeschlossen[0].Quelle -eq 'Regel') ("W=$($sc.Wert) O=$($sc.WertOhneAusnahmen) A=" + (@($sc.Ausgeschlossen) | ForEach-Object { "$($_.Id)/$($_.Quelle)/$($_.Punkte)" }) -join ' ') + ' Z=' + ((@($sc.Abzuege) | ForEach-Object { "$($_.Id)" }) -join ',')
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'SEC-CHECKS'; Schluessel = 'uac-off' })
$sc = Get-HealthScore $s $e
Check 'SEC-CHECKS item uac-off excludes SCORE-UAC' ($sc.Wert -eq 68 -and $sc.Ausgeschlossen[0].Id -eq 'SCORE-UAC' -and $sc.Ausgeschlossen[0].Quelle -eq 'Objekt') ("W=$($sc.Wert) O=$($sc.WertOhneAusnahmen) A=" + (@($sc.Ausgeschlossen) | ForEach-Object { "$($_.Id)/$($_.Quelle)/$($_.Punkte)" }) -join ' ') + ' Z=' + ((@($sc.Abzuege) | ForEach-Object { "$($_.Id)" }) -join ',')
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'SEC-CHECKS'; Schluessel = 'secureboot-off' })
Check 'SEC-CHECKS item secureboot-off excludes SCORE-SECUREBOOT' ((Get-HealthScore $s $e).Wert -eq 64)
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'SEC-CHECKS'; Schluessel = 'firewall-domain' })
Check 'Firewall: two profiles off, one excluded - still counts' ((Get-HealthScore $s $e).Wert -eq 60)
$e += [pscustomobject]@{ Art = 'Objekt'; Regel = 'SEC-CHECKS'; Schluessel = 'firewall-private' }
Check 'Firewall: both profiles excluded - accepted' ((Get-HealthScore $s $e).Wert -eq 70)
$e = @([pscustomobject]@{ Art = 'Regel'; Regel = 'SEC-CHECKS'; Schluessel = '' })
$sc = Get-HealthScore $s $e
Check 'Whole SEC-CHECKS excluded: hints hidden, security deductions stay in the score' ($sc.Wert -eq 60 -and @($sc.Ausgeschlossen).Count -eq 0) (($sc.Ausgeschlossen | ForEach-Object { "$($_.Id)/$($_.Quelle)" }) -join ' ')
# startup items
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'STA-HEAVY'; Schluessel = '[HKCU Run] App1 -> C:\app1.exe' }, [pscustomobject]@{ Art = 'Objekt'; Regel = 'STA-HEAVY'; Schluessel = '[HKCU Run] App2 -> C:\app2.exe' })
$sc = Get-HealthScore $s $e
Check 'Excluded startup programs reduce the counted number below the threshold' ($sc.Wert -eq 65 -and -not ($sc.Abzuege | Where-Object Id -eq 'SCORE-AUTOSTART') -and $sc.Ausgeschlossen[0].Id -eq 'SCORE-AUTOSTART' -and $sc.Ausgeschlossen[0].Quelle -eq 'Objekt')
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'STA-HEAVY'; Schluessel = '[HKCU Run] App1 -> C:\app1.exe' })
$s2 = MkScoreSnap; $s2.Autostart.Aktiv = 16
$sc = Get-HealthScore $s2 $e
Check 'Autostart text shows the counted number' ((($sc.Abzuege | Where-Object Id -eq 'SCORE-AUTOSTART').Grund) -like '15 *' -and (($sc.Abzuege | Where-Object Id -eq 'SCORE-AUTOSTART').Punkte) -eq 5)
$e = @([pscustomobject]@{ Art = 'Regel'; Regel = 'STA-HEAVY'; Schluessel = '' })
$sc = Get-HealthScore $s $e
Check 'Whole STA-HEAVY excluded accepts the autostart deduction' ($sc.Ausgeschlossen[0].Id -eq 'SCORE-AUTOSTART') ("W=$($sc.Wert) O=$($sc.WertOhneAusnahmen) A=" + (@($sc.Ausgeschlossen) | ForEach-Object { "$($_.Id)/$($_.Quelle)/$($_.Punkte)" }) -join ' ') + ' Z=' + ((@($sc.Abzuege) | ForEach-Object { "$($_.Id)" }) -join ',')
# event log and hardware items
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'EVT-HEALTH'; Schluessel = 'bluescreen' })
Check 'Warning kind excluded one by one (2 points less)' ((Get-HealthScore $s $e).Wert -eq 62)
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'HW-COOLING'; Schluessel = 'fan-stop' })
Check 'Critical hardware point cannot be excluded from the count' ((Get-HealthScore $s $e).Wert -eq 60)
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'HW-COOLING'; Schluessel = 'drive-warm' })
Check 'Warn hardware point excluded (1 point less)' ((Get-HealthScore $s $e).Wert -eq 61)
$e = @([pscustomobject]@{ Art = 'Regel'; Regel = 'HW-COOLING'; Schluessel = '' })
Check 'Whole HW-COOLING excluded covers only the warn deduction, never the critical one' ((Get-HealthScore $s $e).Wert -eq 61)
$sOld = MkScoreSnap; foreach ($p in $sOld.Hardware.Punkte) { $p.psobject.Properties.Remove('Schluessel') }; foreach ($p in $sOld.Stabilitaet.Warnsignale) { $p.psobject.Properties.Remove('Schluessel') }
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'HW-COOLING'; Schluessel = 'Drive warm' }, [pscustomobject]@{ Art = 'Objekt'; Regel = 'EVT-HEALTH'; Schluessel = 'Blue screen' })
Check 'Old snapshots without Schluessel: fallback to the text' ((Get-HealthScore $sOld $e).Wert -eq 63)
# deductions that are never a wanted state
Check 'Fixed deduction Ids' ((Get-ScoreFixedIds) -join ',' -eq 'SCORE-ANTIVIRUS,SCORE-WINSUPPORT,SCORE-HWCRIT')
foreach ($fx in (Get-ScoreFixedIds)) { $err = ''; try { $null = Add-WtExclusion -Art Abzug -Regel $fx } catch { $err = $_.Exception.Message }; Check "Abzug exclusion of $fx is refused" ($err -like '*cannot be accepted*' -and -not (Test-Path $ExPath)) }
$sAv = MkScoreSnap; $sAv.Sicherheit.DefenderEchtzeit = $false; $sAv.Sicherheit | Add-Member WindowsSupportEnde '2020-01-01' -Force
$base = (Get-HealthScore $sAv @()).Wert
$e = @([pscustomobject]@{ Art = 'Abzug'; Regel = 'SCORE-ANTIVIRUS' }, [pscustomobject]@{ Art = 'Abzug'; Regel = 'SCORE-WINSUPPORT' }, [pscustomobject]@{ Art = 'Abzug'; Regel = 'SCORE-HWCRIT' }, [pscustomobject]@{ Art = 'Regel'; Regel = 'SEC-CHECKS' }, [pscustomobject]@{ Art = 'Regel'; Regel = 'HW-COOLING' }, [pscustomobject]@{ Art = 'Objekt'; Regel = 'SEC-CHECKS'; Schluessel = 'antivirus-off' }, [pscustomobject]@{ Art = 'Objekt'; Regel = 'SEC-CHECKS'; Schluessel = 'winsupport-end' })
$sc = Get-HealthScore $sAv $e
Check 'Antivirus, Windows support and critical hardware count by every route' (@($sc.Abzuege | Where-Object Id -in (Get-ScoreFixedIds)).Count -eq 3 -and $sc.Wert -eq $base + 1 -and (@($sc.Abzuege | Where-Object Fest).Count -eq 3)) (($sc.Abzuege | ForEach-Object { "$($_.Id)/$($_.Fest)" }) -join ' ')
Check 'Other deductions are not marked fixed' (@((Get-HealthScore $s @()).Abzuege | Where-Object Fest).Count -eq 1)
Set-Content $ExPath '{"Format":"WinTidy-Ausnahmen","Version":1,"Eintraege":[{"Art":"Abzug","Regel":"SCORE-ANTIVIRUS","Schluessel":"","Anzeige":"","Titel":"","Zeit":""},{"Art":"Abzug","Regel":"SCORE-UAC","Schluessel":"","Anzeige":"","Titel":"","Zeit":""}]}' -Encoding UTF8; $Script:Exclusions = $null
Check 'Reading drops a fixed Abzug entry, keeps the others' (@(Read-WtExclusions).Count -eq 1 -and (Read-WtExclusions)[0].Regel -eq 'SCORE-UAC')
Remove-Item $ExPath -Force; $Script:Exclusions = $null
# orphans
$s3 = MkScoreSnap; $s3.Autostart.Verwaist = 2; $s3.Autostart.Liste[0].Zustand = 'fehlt'; $s3.Autostart.Liste[1].Zustand = 'fehlt'
$e = @([pscustomobject]@{ Art = 'Objekt'; Regel = 'STA-ORPHAN'; Schluessel = '[HKCU Run] App1 -> C:\app1.exe' })
$a1 = Get-HealthScore $s3 @(); $a2 = Get-HealthScore $s3 $e
Check 'Orphans excluded one by one' ((($a1.Abzuege | Where-Object Id -eq 'STA-ORPHAN').Punkte) -eq 2 -and (($a2.Abzuege | Where-Object Id -eq 'STA-ORPHAN').Punkte) -eq 1)
# all deductions
$all = [pscustomobject]@{ Zeit = '2026-10-29T10:00:00'; Laufwerke = @([pscustomobject]@{ LW = 'C'; FreiGB = 5; FreiProzent = 2 }); Boot = [pscustomobject]@{ Mittel5 = 100000 }
    Autostart = [pscustomobject]@{ Aktiv = 20; Verwaist = 3; Liste = @() }; Ereignisse = [pscustomobject]@{ FehlerSystem7T = 300; FehlerAnwendung7T = 0 }; Treiber = [pscustomobject]@{ Duplikate = 20; Geistergeraete = 60 }
    Speicher = [pscustomobject]@{ PapierkorbBytes = 6GB }; Stabilitaet = [pscustomobject]@{ Warnsignale = @([pscustomobject]@{ Text = 'x'; Anzahl = 1 }) }
    Hardware = [pscustomobject]@{ Punkte = @([pscustomobject]@{ Stufe = 'krit'; Text = 'a'; Wertung = 'dauer' }, [pscustomobject]@{ Stufe = 'warn'; Text = 'b'; Wertung = 'dauer' }) }
    Sicherheit = [pscustomobject]@{ SecureBoot = $false; DefenderEchtzeit = $false; AndererVirenschutz = $false; AusfuehrungsrichtlinieCU = 'Unrestricted'; UacAus = $true; FirewallProfileAus = 1; WindowsSupportEnde = '2020-01-01'; WindowsUpdateAus = $true } }
$core = @(Get-HealthScoreCore $all @())
$ids = @(Get-ScoreIds)
Check 'All score Ids are known and every known Id is produced' (@($core | Where-Object { $ids -cnotcontains $_.Id }).Count -eq 0 -and @($ids | Where-Object { $_ -notin @($core | ForEach-Object Id) }).Count -eq 0) ((@($ids | Where-Object { $_ -notin @($core | ForEach-Object Id) })) -join ',')
Check 'Score info has a text for every Id' (@($ids | Where-Object { -not (Get-ScoreInfo)[$_] }).Count -eq 0)
Check 'Score links point to known deductions' (@((Get-ScoreItemLinks).Values + (Get-ScoreRuleLinks).Keys | Where-Object { $ids -cnotcontains $_ }).Count -eq 0)
Check 'No link reaches a fixed deduction' (@((Get-ScoreItemLinks).Values + (Get-ScoreRuleLinks).Keys | Where-Object { (Get-ScoreFixedIds) -contains $_ }).Count -eq 0)
# nothing readable -> as if there were no exclusions
Set-Content $ExPath 'garbage' -Encoding UTF8; $Script:Exclusions = $null
Check 'Unreadable file: score as without exclusions' ((Get-HealthScore $s).Wert -eq 60)
Remove-Item $ExPath -Force; $Script:Exclusions = $null

# 7) History and report with the recomputed score
foreach ($fn in 'New-Snapshot', 'New-Report', 'Get-CompareMetrics') { foreach ($f1 in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] }, $false)) { . ([scriptblock]::Create($f1.Extent.Text)) } }
$Script:Version = '1.12.0'
function MkSnap($label, $time, $uacOff) {
    $s = MkScoreSnap
    $s | Add-Member -NotePropertyName Tool -NotePropertyValue '1.12.0' -Force; $s | Add-Member -NotePropertyName Label -NotePropertyValue $label -Force
    $s.Zeit = $time; $s | Add-Member -NotePropertyName Admin -NotePropertyValue $true -Force; $s | Add-Member -NotePropertyName Computer -NotePropertyValue 'TESTPC' -Force; $s | Add-Member -NotePropertyName Benutzer -NotePropertyValue 'X\y' -Force
    $s | Add-Member -NotePropertyName System -NotePropertyValue ([pscustomobject]@{ OS = 'Microsoft Windows 11'; Build = '1'; Version = '25H2'; CPU = 'CPU'; Kerne = 4; Threads = 8; RamGB = 16; Board = 'B'; BIOS = 'x' }) -Force
    $s | Add-Member -NotePropertyName Laufwerke -NotePropertyValue @([pscustomobject]@{ LW = 'C'; Label = ''; FS = 'NTFS'; GroesseGB = 200; FreiGB = 100; FreiProzent = 50; Medium = 'SSD'; Bus = 'NVMe'; Disk = 'd' }) -Force
    $s.Boot = [pscustomobject]@{ Verlauf = @(); Mittel5 = 30000; Bremser = @() }
    $s | Add-Member -NotePropertyName Leerlauf -NotePropertyValue ([pscustomobject]@{ CpuProzent = 3; RamBelegtProzent = 15; RamBelegtGB = 5; Prozesse = 200; Threads = 4000; Handles = 90000 }) -Force
    $s | Add-Member -NotePropertyName Dienste -NotePropertyValue ([pscustomobject]@{ Gesamt = 1; Laufend = 1; AutoDrittanbieter = 0 }) -Force
    $s | Add-Member -NotePropertyName Aufgaben -NotePropertyValue ([pscustomobject]@{ Gesamt = 1; Eigene = 1 }) -Force
    $s | Add-Member -NotePropertyName Programme -NotePropertyValue ([pscustomobject]@{ Installiert = 1; StoreApps = 1 }) -Force
    $s.Hardware = $null
    $s.Sicherheit.UacAus = $uacOff
    $s | Add-Member -NotePropertyName Befunde -NotePropertyValue @() -Force
    $s | Add-Member -NotePropertyName Score -NotePropertyValue (Get-HealthScore $s @()) -Force
    $s | ConvertTo-Json -Depth 7 | Out-File ("$Script:SnapDir/{0}_{1}.json" -f ([datetime]$time).ToString('yyyyMMdd-HHmmss'), $label) -Encoding utf8
    $s
}
$sa = MkSnap 'vorher' '2026-10-28T10:00:00' $true
$sb = MkSnap 'nachher' '2026-10-29T10:00:00' $true
$hist = Read-SnapshotHistory
Check 'History without exclusions: scores as stored' ((@($hist.Scores | ForEach-Object Wert) -join ',') -eq "$($sa.Score.Wert),$($sb.Score.Wert)")
$null = Add-WtExclusion -Art Abzug -Regel 'SCORE-UAC' -Titel 'UAC'
$null = Add-WtExclusion -Art Objekt -Regel 'STA-HEAVY' -Schluessel '[HKCU Run] App1 -> C:\app1.exe' -Anzeige 'App1' -Titel 'Review startup'
$null = Add-WtExclusion -Art Regel -Regel 'SEC-EXECPOLICY' -Titel 'Policy'
$hist = Read-SnapshotHistory
$expected = (Get-HealthScore $sa).Wert
Check 'History: all points recomputed with the exclusions (same rules for every point)' ((@($hist.Scores | ForEach-Object Wert) -join ',') -eq "$expected,$expected" -and $expected -gt $sa.Score.Wert) (@($hist.Scores | ForEach-Object Wert) -join ',')
$raw = Get-Content (Get-ChildItem $Script:SnapDir -Filter '*_vorher.json').FullName -Raw | ConvertFrom-Json
Check 'Snapshot files are never rewritten' ($raw.Score.Wert -eq $sa.Score.Wert)
$cm = Get-CompareMetrics (Read-Snapshot (Get-Snapshots)[0]) (Read-Snapshot (Get-Snapshots)[1])
Check 'Compare: score row uses the recomputed values' ((($cm | Where-Object Id -eq 'Score').Vorher) -eq $expected)
$null = New-Item -ItemType Directory -Force "$Script:RunsDir/20261028-1000_apply"
$rp = New-Report
$html = Get-Content $rp -Raw -Encoding UTF8
Check 'Report EN: accepted deductions, score without exclusions, exclusions table' ($html -match 'Accepted \(not counted\)' -and $html -match "Without exclusions the score would be $((Get-HealthScore $sb @()).Wert)" -and $html -match '<h2>Exclusions</h2>' -and $html -match 'App1' -and $html -match 'SEC-EXECPOLICY')
Check 'Report EN: ring shows the recomputed score' ($html -match "class='ring (good|mid|bad)'>$expected<")
Set-WtLanguage 'de' $root
$rp = New-Report
$html = Get-Content $rp -Raw -Encoding UTF8
Check 'Report DE: sections translated' ($html -match 'Akzeptiert \(nicht gewertet\)' -and $html -match '<h2>Ausnahmen</h2>' -and $html -match 'Ohne Ausnahmen')
Set-WtLanguage 'en'
Remove-Item $ExPath -Force; $Script:Exclusions = $null
$rp = New-Report; $html = Get-Content $rp -Raw -Encoding UTF8
Check 'Report without exclusions: no exclusion section, no accepted block' ($html -notmatch '<h2>Exclusions</h2>' -and $html -notmatch 'Accepted \(not counted\)')

# 8) App interface
$Script:Rules = @($Script:Rules | Where-Object { $_.Id -eq 'CLN-A' }) + @([pscustomobject]@{ Id = 'STA-M'; Kategorie = 'Autostart'; Titel = 'M'; Warum = 'm'; Risiko = 'Mittel'; Admin = $false; Standard = $true; Detect = { New-Item2 'm1' 0 @{ Name = 'one' } }; Fix = { param($it) 'ok' } })
$Script:LastFindings = @(); $Script:LastExcludedHits = @(); $Script:ExclChecked = @{}
$g = Get-GuiExclusions
Check 'Get-GuiExclusions: empty list, score of the latest snapshot' (@($g.Eintraege).Count -eq 0 -and $g.Score.Wert -eq (Get-HealthScore $sb).Wert -and $g.Fehler -eq '')
$f = @(Get-AllFindings $false $null)
$it = ($f | Where-Object Id -eq 'CLN-A').Items[0]
$g = Invoke-GuiExclude @{ Art = 'Objekt'; Regel = 'CLN-A'; Schluessel = $it.Schluessel; Anzeige = $it.Label; Titel = '' }
Check 'Invoke-GuiExclude: stored, title filled, found by the last check, findings updated' ($g.Fehler -eq '' -and @($g.Eintraege).Count -eq 1 -and $g.Eintraege[0].RegelTitel -eq 'A' -and $g.Eintraege[0].NochGefunden -eq $true -and $g.Eintraege[0].Titel -eq 'A' -and (($Script:LastFindings | Where-Object Id -eq 'CLN-A').Items.Count -eq 1))
$g = Invoke-GuiExclude @{ Art = 'Regel'; Regel = 'STA-M'; Schluessel = ''; Anzeige = ''; Titel = 'M' }
Check 'Invoke-GuiExclude whole rule: rule leaves the remembered findings' (-not ($Script:LastFindings | Where-Object Id -eq 'STA-M') -and @($g.Eintraege).Count -eq 2)
$g = Invoke-GuiExclude @{ Art = 'Abzug'; Regel = 'SCORE-UAC'; Schluessel = ''; Anzeige = ''; Titel = '' }
$ab = $g.Eintraege | Where-Object Art -eq 'Abzug'
Check 'Deduction exclusion: score returned, status from the latest snapshot' ($ab.NochGefunden -eq $true -and $ab.RegelTitel -match 'User Account Control' -and $g.Score.Wert -gt (Get-HealthScore $sb @()).Wert)
$g = Invoke-GuiExclude @{ Art = 'Regel'; Regel = 'bad id'; Schluessel = ''; Anzeige = ''; Titel = '' }
Check 'Invoke-GuiExclude: error is returned, nothing changed' ($g.Fehler -and @($g.Eintraege).Count -eq 3)
$g = Invoke-GuiInclude @{ Art = 'Abzug'; Regel = 'SCORE-UAC'; Schluessel = '' }
Check 'Invoke-GuiInclude: removed, score back' (@($g.Eintraege).Count -eq 2 -and $g.Score.Wert -eq (Get-HealthScore $sb @()).Wert)
$null = Add-WtExclusion -Art Regel -Regel 'GONE-RULE'
$Script:Exclusions = $null
$g = Get-GuiExclusions
Check 'Rule that does not exist (any more): not found, title from the entry' (($g.Eintraege | Where-Object Regel -eq 'GONE-RULE').NochGefunden -eq $false)
$g = Invoke-GuiIncludeAll
Check 'Invoke-GuiIncludeAll empties the list' (@($g.Eintraege).Count -eq 0 -and @(Read-WtExclusions).Count -eq 0)
$ex2 = (Get-Command Invoke-GuiScan).ScriptBlock.ToString()
Check 'Scan results carry the exclusions for the app' ($ex2 -match 'Ausnahmen')

# 9) Command line mode
Remove-Item $ExPath -Force -ErrorAction SilentlyContinue; $Script:Exclusions = $null
$Script:Rules = $Script:RealRules
function Run-Mode($add, $remove) { $Script:Out.Clear(); $script:AddExclusion = $add; $script:RemoveExclusion = $remove; Invoke-ExclusionsMode; ($Script:Out -join "`n") }
$o = Run-Mode @('NO-SUCH-RULE') $null
Check 'Unknown rule: error text, nothing written' ($o -match 'Unknown rule' -and $o -match 'Nothing was changed' -and -not (Test-Path $ExPath))
$o = Run-Mode @('SCORE:SCORE-NOPE') $null
Check 'Unknown deduction: error text, nothing written' ($o -match 'Unknown score deduction' -and -not (Test-Path $ExPath))
$o = Run-Mode @('SEC-EXECPOLICY', 'NO-SUCH-RULE') $null
Check 'One bad value: nothing at all is written' (-not (Test-Path $ExPath))
$o = Run-Mode @('sec-execpolicy') $null
Check 'Add a rule (any case)' (@(Read-WtExclusions).Count -eq 1 -and (Read-WtExclusions)[0].Art -eq 'Regel' -and (Read-WtExclusions)[0].Regel -eq 'SEC-EXECPOLICY' -and $o -match 'Excluded: SEC-EXECPOLICY')
$o = Run-Mode @('SCORE:SCORE-UAC', 'SCORE:FIREWALL') $null
Check 'Add deductions (also without the SCORE- prefix)' (@(Read-WtExclusions).Count -eq 3 -and (Read-WtExclusions)[2].Regel -eq 'SCORE-FIREWALL' -and (Read-WtExclusions)[2].Art -eq 'Abzug')
Check 'The listing is numbered and shows type and rule' ($o -match '  1  ' -and $o -match 'whole check: SEC-EXECPOLICY' -and $o -match 'score deduction: SCORE-UAC')
$o = Run-Mode $null @('9')
Check 'Remove: unknown number is an error, nothing removed' ($o -match 'no exclusion number 9' -and @(Read-WtExclusions).Count -eq 3)
$o = Run-Mode $null @('2')
Check 'Remove by number' (@(Read-WtExclusions).Count -eq 2 -and -not (Read-WtExclusions | Where-Object Regel -eq 'SCORE-UAC'))
$o = Run-Mode @('CLN-TEMP') @('1')
Check 'Add and remove together are refused' ($o -match 'one after the other' -and @(Read-WtExclusions).Count -eq 2)
$o = Run-Mode $null @('all')
Check 'Remove all' (@(Read-WtExclusions).Count -eq 0 -and $o -match 'No exclusions')


# 10) Stable keys of hardware points and warning signals
$o = Run-Mode @('SCORE:SCORE-ANTIVIRUS') $null
$Script:Exclusions = $null
Check 'CLI: fixed deduction is refused, nothing written' ($o -match 'cannot be accepted' -and @(Read-WtExclusions).Count -eq 0)
$o = Run-Mode @('SCORE:ANTIVIRUS', 'SCORE:SCORE-UAC') $null
$Script:Exclusions = $null
Check 'CLI: one refused entry stops the whole call' ($o -match 'Nothing was changed' -and @(Read-WtExclusions).Count -eq 0)
$def = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HardwarePoints' }, $true) | Select-Object -First 1
Invoke-Expression ($def.Extent.Text -replace 'function Get-HardwarePoints', 'function Get-HwPointsReal')
$Script:Mock = @{}
function Get-HwMonitorSensors([switch]$NoCache) { @($Script:Mock.Sensors | Where-Object { $_ }) }
function Get-NvidiaGpus { @($Script:Mock.Gpus | Where-Object { $_ }) }
function Get-ThermalZones { @() }
function Get-ThrottleEventCount([int]$Days = 30, [datetime]$Since = [datetime]::MinValue) { 0 }
function Get-DiskHealth { @($Script:Mock.Disks | Where-Object { $_ }) }
function Get-ChassisInfo { [pscustomobject]@{ Laptop = $false; Akku = $false; HatAkku = $false; Typen = @(); VM = $false; CpuName = 'CPU' } }
function Get-EventCount([hashtable]$Filter) { 0 }
function Get-FanToolPoints { @() }
function Get-BatteryWear { $null }
function SS($Name, $Typ, $Wert, $GTyp = 'Motherboard') { [pscustomobject]@{ Quelle = 'LibreHardwareMonitor'; Name = $Name; Typ = $Typ; Wert = [double]$Wert; Geraet = 'Board'; GeraeteTyp = $GTyp } }
function Gpu2($T, $F, $U = 5) { [pscustomobject]@{ Name = 'RTX'; TempC = $T; LuefterProzent = $F; LeistungW = 40; LimitW = 285; TaktMHz = 2600; TaktMaxMHz = 3100; Auslastung = $U; PcieBreite = $null; PcieBreiteMax = $null; GruendeStabil = 0; SlowdownC = $null; MaxOpC = $null; ZielC = $null } }
function Disk2($Name, $T, $Wear = $null) { [pscustomobject]@{ Name = $Name; Art = 'SSD'; Bus = ''; Zustand = 'Healthy'; TempC = $T; Verschleiss = $Wear; Betriebsstunden = 100; Ausfallwarnung = $false } }
function RunHw([hashtable]$m, [string]$lang) { $Script:Mock = $m; $Script:Cache = @{}; $Script:Lang = $lang; @(Get-HwPointsReal) }
$p1 = RunHw @{ Sensors = @((SS 'CPU Package' 'Temperature' 44 'Cpu'), (SS 'CPU Fan' 'Fan' 800)); Gpus = @(Gpu2 74 0 5); Disks = @(Disk2 'Samsung' 61 85) } 'en'
$p2 = RunHw @{ Sensors = @((SS 'CPU Package' 'Temperature' 47 'Cpu'), (SS 'CPU Fan' 'Fan' 800)); Gpus = @(Gpu2 78 0 5); Disks = @(Disk2 'Samsung' 62 85) } 'en'
$k1 = @($p1 | ForEach-Object Schluessel) -join '|'; $k2 = @($p2 | ForEach-Object Schluessel) -join '|'
Check 'Every hardware point has a key' (@($p1 | Where-Object { -not $_.Schluessel }).Count -eq 0 -and $p1.Count -ge 5) $k1
Check 'Keys do not change when the measured values change' ($k1 -eq $k2 -and (($p1 | ForEach-Object Text) -join '|') -ne (($p2 | ForEach-Object Text) -join '|')) "$k1 // $k2"
Check 'Keys contain the cause, the device name but no numbers from measurements' (($p1 | Where-Object Schluessel -eq 'gpu-fan-zero:RTX') -and ($p1 | Where-Object { $_.Schluessel -in 'drive-temp-hot:Samsung', 'drive-temp-warm:Samsung' }) -and ($p1 | Where-Object Schluessel -eq 'ssd-wear:Samsung'))
$Script:De = New-Object "System.Collections.Generic.Dictionary[string,string]"; $p3 = RunHw @{ Sensors = @((SS 'CPU Package' 'Temperature' 44 'Cpu'), (SS 'CPU Fan' 'Fan' 800)); Gpus = @(Gpu2 74 0 5); Disks = @(Disk2 'Samsung' 61 85) } 'de'
Check 'Keys do not change with the language' ((@($p3 | ForEach-Object Schluessel) -join '|') -eq $k1)
$Script:Lang = 'en'; $Script:De = $null
function Get-EventCount([hashtable]$Filter) { if ($Filter.Id -eq 41) { 3 } elseif ($Filter.Id -eq 1001) { 1 } else { 0 } }
$Script:Cache = @{}; $w = @(Get-WarningSignals)
Check 'Warning signals carry a key per check' ($w.Count -eq 2 -and ($w | ForEach-Object Schluessel) -join ',' -eq 'power-loss,bluescreen')
$Script:Cache = @{}
$snap = @(Get-WarningSignals | ForEach-Object { [ordered]@{ Text = $_.Text; Anzahl = $_.Anzahl; Schluessel = [string]$_.Schluessel } })
Check 'Warning signal key is used by the EVT-HEALTH item' ((($Script:RealRules | Where-Object Id -eq 'EVT-HEALTH').Detect.ToString()) -match 'Schluessel')

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red } else { Write-Host 'All exclusion tests passed' -ForegroundColor Green }
exit $fail
