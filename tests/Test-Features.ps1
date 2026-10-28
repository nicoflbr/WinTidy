# Test-Features.ps1 - checks the features of version 1.9: security health check (SEC-HEALTH), Storage Sense status
# (SYS-STORAGESENSE), AI inventory (SYS-AI), profiles (export/import of the rule selection) and the shareable report
# (anonymized HTML, PDF fallback). Windows parts are replaced by stubs. Usage: pwsh ./tests/Test-Features.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-featuretest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $TestData | Out-Null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
$Script:Lang = 'en'; $Script:De = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Friendly)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:AllRules = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Child -is [System.Management.Automation.Language.HashtableAst] -and $n.Extent.Text -match "^\[pscustomobject\]@\{ Id = '(SEC-HEALTH|SYS-STORAGESENSE|SYS-AI)'" }, $true) | ForEach-Object { & ([scriptblock]::Create($_.Extent.Text)) })
$Script:Rules = $Script:AllRules
$Script:DataDir = $TestData; $Script:Cache = @{}; $Script:IsAdmin = $true; $Script:Version = '1.9.0'

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }
function Rule([string]$Id) { $Script:AllRules | Where-Object Id -eq $Id }
function Run([string]$Id) { $r = Rule $Id; @(& $r.Detect | Where-Object { $_ }) }
function Stufen($items) { @($items | ForEach-Object { [string]$_.Data.Stufe }) }

# --- Rule contract ---
Check 'The three new rules exist' ($Script:AllRules.Count -eq 3)
Check 'All three are info rules without a fix' (@($Script:AllRules | Where-Object { $_.Risiko -ne 'Info' -or $_.Fix }).Count -eq 0)
Check 'All three have a plain-language text' (@($Script:AllRules | Where-Object { -not $Script:Friendly[$_.Id] }).Count -eq 0)

# --- SEC-HEALTH ---
function Get-OtherSecurityProducts([string]$Class) { @() }
function Get-ChassisInfo { [pscustomobject]@{ Laptop = $Script:Laptop } }
$Script:Laptop = $false
function Get-BitLockerState { $Script:BL }
function Get-TpmState { $Script:Tpm }
function Get-MemoryIntegrityState { $Script:MI }
function Get-DefenderTamperState { $Script:Tamper }
$Script:BL = 'Geschuetzt'; $Script:Tpm = [pscustomobject]@{ Vorhanden = $true; Bereit = $true }; $Script:MI = $true; $Script:Tamper = $true
$i = @(Run 'SEC-HEALTH')
Check 'Everything fine: four green points' ($i.Count -eq 4 -and (Stufen $i | Where-Object { $_ -ne 'ok' }).Count -eq 0)
$Script:BL = 'Aus'; $Script:Laptop = $false
Check 'No encryption on a desktop PC: neutral note' (@(Stufen (Run 'SEC-HEALTH'))[0] -eq '')
$Script:Laptop = $true
Check 'No encryption on a laptop: warning' (@(Stufen (Run 'SEC-HEALTH'))[0] -eq 'warn')
$Script:BL = 'Ausgesetzt'
Check 'Paused encryption: warning' (@(Stufen (Run 'SEC-HEALTH'))[0] -eq 'warn')
$Script:BL = $null; $Script:Tpm = $null; $Script:MI = $null; $Script:Tamper = $null
Check 'Nothing readable: no findings, no error' (@(Run 'SEC-HEALTH').Count -eq 0)
$Script:BL = 'Geschuetzt'; $Script:Tpm = [pscustomobject]@{ Vorhanden = $true; Bereit = $false }
Check 'TPM present but not ready: warning' (@(Stufen (Run 'SEC-HEALTH')) -contains 'warn')
$Script:Tpm = [pscustomobject]@{ Vorhanden = $false; Bereit = $false }
Check 'No TPM: neutral note' (@(Stufen (Run 'SEC-HEALTH'))[-1] -eq '')
$Script:Tpm = $null; $Script:MI = $false
Check 'Memory integrity off: neutral note' (@(Stufen (Run 'SEC-HEALTH')) -contains '')
$Script:MI = $null; $Script:Tamper = $false
Check 'Tamper protection off: warning' (@(Stufen (Run 'SEC-HEALTH')) -contains 'warn')
function Get-OtherSecurityProducts([string]$Class) { @([pscustomobject]@{ displayName = 'Other AV' }) }
Check 'With another antivirus the Defender tamper protection is not judged' (@(Run 'SEC-HEALTH' | Where-Object { $_.Label -match 'tamper' }).Count -eq 0)
function Get-OtherSecurityProducts([string]$Class) { @() }

# --- SYS-STORAGESENSE ---
function Get-StorageSenseState { $Script:SS }
$Script:SS = $null
Check 'Storage Sense unknown: nothing shown' (@(Run 'SYS-STORAGESENSE').Count -eq 0)
$Script:SS = [pscustomobject]@{ Aktiv = $false; DownloadsTage = 0; PapierkorbTage = 0; Richtlinie = $null }
$i = @(Run 'SYS-STORAGESENSE')
Check 'Storage Sense off: one neutral note' ($i.Count -eq 1 -and @(Stufen $i)[0] -eq '')
$Script:SS = [pscustomobject]@{ Aktiv = $true; DownloadsTage = 0; PapierkorbTage = 30; Richtlinie = $null }
$i = @(Run 'SYS-STORAGESENSE')
Check 'Storage Sense on without Downloads cleanup: green' ($i.Count -eq 1 -and @(Stufen $i)[0] -eq 'ok')
$Script:SS = [pscustomobject]@{ Aktiv = $true; DownloadsTage = 14; PapierkorbTage = 30; Richtlinie = $null }
$i = @(Run 'SYS-STORAGESENSE')
Check 'Downloads cleanup is shown with a warning and the number of days' ($i.Count -eq 2 -and @(Stufen $i)[1] -eq 'warn' -and $i[1].Label -match '14')
$Script:SS = [pscustomobject]@{ Aktiv = $true; DownloadsTage = 0; PapierkorbTage = 0; Richtlinie = 0 }
Check 'Policy turns it off: neutral note' (@(Stufen (Run 'SYS-STORAGESENSE'))[0] -eq '')

# --- SYS-AI ---
function Get-AiFeatureState { $Script:AI }
function New-Ai { [pscustomobject]@{ CopilotApp = $false; CopilotRichtlinieAus = $false; RecallAktiv = $null; RecallRichtlinie = $null; DatenanalyseAus = $false } }
$Script:AI = New-Ai
Check 'Nothing known: no findings' (@(Run 'SYS-AI').Count -eq 0)
$Script:AI = New-Ai; $Script:AI.RecallAktiv = $true; $Script:AI.CopilotApp = $true
$i = @(Run 'SYS-AI')
Check 'Recall on and Copilot installed: two neutral notes' ($i.Count -eq 2 -and (Stufen $i | Where-Object { $_ -ne '' }).Count -eq 0)
$Script:AI = New-Ai; $Script:AI.RecallAktiv = $false; $Script:AI.CopilotRichtlinieAus = $true; $Script:AI.DatenanalyseAus = $true
Check 'Recall off, Copilot and AI analysis blocked: three green points' (@(Run 'SYS-AI').Count -eq 3 -and (Stufen (Run 'SYS-AI') | Where-Object { $_ -ne 'ok' }).Count -eq 0)
$Script:AI = New-Ai; $Script:AI.RecallRichtlinie = 0
Check 'Recall blocked by policy counts as not active' (@(Stufen (Run 'SYS-AI'))[0] -eq 'ok')

# --- Profiles ---
$Script:Rules = @(
    [pscustomobject]@{ Id = 'A-LOW'; Standard = $true; Risiko = 'Niedrig' },
    [pscustomobject]@{ Id = 'B-MID'; Standard = $true; Risiko = 'Mittel' },
    [pscustomobject]@{ Id = 'C-INFO'; Standard = $true; Risiko = 'Info' },
    [pscustomobject]@{ Id = 'D-OPT'; Standard = $false; Risiko = 'Niedrig' })
Check 'Safe = standard rules without Medium/High' ((((Get-PresetRuleIds 'Safe') -join ',')) -eq 'A-LOW,C-INFO')
Check 'Standard = default selection' ((((Get-PresetRuleIds 'Standard') -join ',')) -eq 'A-LOW,B-MID,C-INFO')
Check 'Unknown built-in name gives nothing' ($null -eq (Get-PresetRuleIds 'Nope'))
$pf = Join-Path $TestData 'mine.json'
$null = Save-WtPreset $pf @('A-LOW', 'D-OPT') 'My profile'
Check 'Profile file is written' (Test-Path $pf)
$raw = [IO.File]::ReadAllBytes($pf)
Check 'Profile file is UTF-8 without BOM' (-not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF))
$j = Get-Content $pf -Raw | ConvertFrom-Json
Check 'Profile contains format, version, name and rules' ($j.Format -eq 'WinTidy-Profil' -and $j.Name -eq 'My profile' -and $j.WinTidy -eq '1.9.0' -and @($j.Regeln).Count -eq 2)
$r = Resolve-WtPreset $pf
Check 'Round trip returns the same rules' (($r.Ids -join ',') -eq 'A-LOW,D-OPT' -and $r.Name -eq 'My profile' -and $r.Unbekannt.Count -eq 0)
$null = Save-WtPreset $pf @('A-LOW') ''
Check 'Single rule stays an array in the file' (@((Get-Content $pf -Raw | ConvertFrom-Json).Regeln).Count -eq 1)
[IO.File]::WriteAllText($pf, '{"Format":"WinTidy-Profil","Name":"x","Regeln":["A-LOW","GONE-RULE","A-LOW"]}')
$r = Resolve-WtPreset $pf
Check 'Unknown rules are reported and dropped, duplicates removed' (($r.Ids -join ',') -eq 'A-LOW' -and ($r.Unbekannt -join ',') -eq 'GONE-RULE')
$r = Resolve-WtPreset 'safe'
Check 'Built-in name is found regardless of case' (($r.Ids -join ',') -eq 'A-LOW,C-INFO' -and $r.Name -eq 'Safe')
[IO.File]::WriteAllText($pf, 'this is not json')
$err = $null; try { $null = Resolve-WtPreset $pf } catch { $err = $_.Exception.Message }
Check 'A broken file gives a readable error' ($err -and $err -match 'could not be read')
[IO.File]::WriteAllText($pf, '{"foo":1}')
$err = $null; try { $null = Resolve-WtPreset $pf } catch { $err = $_.Exception.Message }
Check 'A foreign JSON file is refused' ($err -and $err -match 'not a WinTidy profile')
$err = $null; try { $null = Resolve-WtPreset (Join-Path $TestData 'missing.json') } catch { $err = $_.Exception.Message }
Check 'A missing profile names the built-in ones' ($err -and $err -match 'Safe')

# --- Shareable report ---
$env:COMPUTERNAME = 'DESKTOP-ABC123'; $env:USERNAME = 'maxmuster'
$env:USERPROFILE = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'C:\Users\Max Muster' } else { '/home/Max Muster' }; $env:USERDOMAIN = 'CORP'
$Script:DataDir = Join-Path $TestData 'WinTidy-Daten'
New-Item -ItemType Directory -Force $Script:DataDir | Out-Null
$rep = Get-ShareReplacements
Check 'Replacements cover data folder, profile, PC, user, profile name and domain' (@($rep | Where-Object { $_.Von -in $Script:DataDir, $env:USERPROFILE, 'DESKTOP-ABC123', 'maxmuster', 'Max Muster', 'CORP' }).Count -eq 6)
$short = Get-ShareReplacements | Where-Object { $_.Von.Length -lt 3 }
Check 'Very short terms are never replaced (would break the page)' (@($short).Count -eq 0)
$html = "<html><head><style>.maxmuster{color:red}</style></head><body><div><h1>Report DESKTOP-ABC123</h1><p>User maxmuster, folder $($Script:DataDir)\x and $($env:USERPROFILE)\Desktop</p><span title='maxmuster here'>x</span><p>Price `$5 &amp; more</p></div></body></html>"
$out = ConvertTo-ShareableHtml $html $rep
Check 'PC name replaced' ($out -notmatch 'DESKTOP-ABC123' -and $out -match '\[PC name\]')
Check 'User name replaced in text and in attribute values' ($out -notmatch 'title=.maxmuster' -and $out -notmatch 'User maxmuster')
Check 'Paths replaced' ($out -notmatch [regex]::Escape($env:USERPROFILE) -and $out -notmatch [regex]::Escape($Script:DataDir))
Check 'The style block is left alone' ($out -match '\.maxmuster\{color:red\}')
Check 'Other text and entities stay intact' ($out -match 'Price \$5 &amp; more')
Check 'A note is added at the end of the page' ($out -match 'Shareable version' -and $out.IndexOf('Shareable version') -lt $out.LastIndexOf('</body>'))
$out2 = ConvertTo-ShareableHtml 'Welcome MAXMUSTER' $rep
Check 'Replacement ignores upper/lower case' ($out2 -notmatch 'MAXMUSTER')
Check 'Without replacement terms the page is only given the note' ((ConvertTo-ShareableHtml '<p>a</p></div></body>' @()) -match 'Shareable version')

# PDF: no browser -> message, no exception
function Get-PdfBrowserPath { $null }
$msg = Convert-HtmlToPdf (Join-Path $TestData 'x.html') (Join-Path $TestData 'x.pdf')
Check 'No browser: readable message instead of an error' ($msg -is [string] -and $msg -match 'Edge or Chrome')

# Whole path with a stubbed report
function New-Report { $p = Join-Path $Script:DataDir 'WinTidy-Bericht.html'; [IO.File]::WriteAllText($p, "<html><body><div><p>PC DESKTOP-ABC123 / maxmuster</p></div></body></html>", (New-Object Text.UTF8Encoding($true))); $p }
$r = New-ShareableReport $false
Check 'Shareable report file is created next to the normal one' ($r -and (Test-Path $r.Html) -and (Split-Path $r.Html -Leaf) -eq 'WinTidy-Bericht-teilbar.html' -and -not $r.Pdf)
Check 'The original report keeps the names' ((Get-Content (Join-Path $Script:DataDir 'WinTidy-Bericht.html') -Raw) -match 'DESKTOP-ABC123')
Check 'The shareable report no longer contains them' ((Get-Content $r.Html -Raw) -notmatch 'DESKTOP-ABC123|maxmuster')
$r = New-ShareableReport $true
Check 'PDF requested but impossible: HTML still delivered with a hint' ($r.Html -and -not $r.Pdf -and $r.Hinweis)
function Convert-HtmlToPdf([string]$HtmlPath, [string]$PdfPath) { [IO.File]::WriteAllText($PdfPath, 'pdf'); $null }
$r = New-ShareableReport $true
Check 'PDF requested and possible: path is returned' ($r.Pdf -and (Test-Path $r.Pdf) -and $r.Pdf.EndsWith('.pdf') -and -not $r.Hinweis)
function New-Report { $null }
Check 'No report data: nothing is created' ($null -eq (New-ShareableReport $false))

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red } else { Write-Host 'All feature tests passed' -ForegroundColor Green }
exit $fail
