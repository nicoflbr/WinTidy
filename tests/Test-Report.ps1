# Test-Report.ps1 - creates two synthetic snapshots + an action log and builds the comparison and the HTML report from them.
# Runs without Windows dependencies (also with pwsh on Linux/macOS). Usage: pwsh ./tests/Test-Report.ps1
$ErrorActionPreference = 'Stop'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-test'
$t=$null;$e=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Join-Path $PSScriptRoot '..') 'WinTidy.ps1'),[ref]$t,[ref]$e)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent.Parent.Parent -eq $null -or ($n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast) }, $false)
foreach ($f in $funcs) { . ([scriptblock]::Create($f.Extent.Text)) }
Set-WtLanguage 'en'
$env:SystemDrive='C:'; $env:COMPUTERNAME='TESTPC'
$Script:Version='1.0.0'; $Script:DataDir=$TestData; $Script:SnapDir=(Join-Path $TestData 'snapshots'); $Script:RunsDir=(Join-Path $TestData 'runs')
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Script:SnapDir,"$Script:RunsDir/20261021-1831_apply" | Out-Null
function MkSnap($label,$time,$free,$bootBase,$aktiv,$err){
 $boots=@(); for($i=0;$i -lt 12;$i++){ $boots += [pscustomobject]@{Zeit=([datetime]$time).AddDays(-$i).ToString('o'); GesamtMs=$bootBase+ (Get-Random -Max 4000); HauptpfadMs=35000; NachDesktopMs=13000} }
 $s=[ordered]@{Tool='1.0.0';Label=$label;Zeit=([datetime]$time).ToString('o');Admin=$true;Computer='TESTPC';Benutzer='X\y'
  System=[ordered]@{OS='Microsoft Windows 11 Home';Build='26200.9711';Version='25H2';CPU='AMD Ryzen 9 5900X';Kerne=12;Threads=24;RamGB=63.9;Board='ASRock B550';BIOS='P2.20 (2022-02-24)';LetzterStart=$time;LaufzeitStd=1}
  Laufwerke=@([pscustomobject]@{LW='C';Label='';FS='NTFS';GroesseGB=231.7;FreiGB=$free;FreiProzent=[math]::Round(100*$free/231.7,1);Medium='SSD';Bus='SATA';Disk='Samsung'},[pscustomobject]@{LW='W';Label='Work';FS='NTFS';GroesseGB=931.5;FreiGB=906;FreiProzent=97.3;Medium='SSD';Bus='NVMe';Disk='WD'})
  Boot=[ordered]@{Verlauf=$boots;Mittel5=$bootBase+2000;Bremser=@([pscustomobject]@{Typ='App';Datei='Spotify.exe';Name='Spotify';Anzahl=7;MittelMs=22000;MaxMs=26000},[pscustomobject]@{Typ='Treiber';Datei='vgk';Name='Vanguard';Anzahl=1;MittelMs=444;MaxMs=444})}
  Autostart=[ordered]@{Gesamt=20;Aktiv=$aktiv;Verwaist=2;Liste=@([pscustomobject]@{Name='Spotify';Art='StoreApp';Ort='Spotify_x';Ziel='Spotify_x';Zustand='ok';Aktiv=$true;DegradationMs=22000},[pscustomobject]@{Name='KeePassXC';Art='Registry';Ort='HKCU Run';Ziel='G:\KeePassXC\KeePassXC.exe';Zustand='fehlt';Aktiv=$false;DegradationMs=0})}
  Dienste=[ordered]@{Gesamt=300;Laufend=120;AutoDrittanbieter=12}; Aufgaben=[ordered]@{Gesamt=206;Eigene=13}; Programme=[ordered]@{Installiert=70;StoreApps=60}
  Treiber=[ordered]@{Pakete=123;Duplikate=34;Geistergeraete=97}; Ereignisse=[ordered]@{FehlerSystem7T=$err;FehlerAnwendung7T=20;Top=@()}
  Leerlauf=[pscustomobject]@{CpuProzent=3.1;RamBelegtProzent=15;RamBelegtGB=9.8;Prozesse=214;Threads=4902;Handles=90000}
  Speicher=[ordered]@{PapierkorbBytes=0;TempBytes=1000;CrashDumpsBytes=0}; Sicherheit=[ordered]@{SecureBoot=$false;DefenderEchtzeit=$true;AusfuehrungsrichtlinieCU='Unrestricted'}
  Hardware=[ordered]@{Laptop=$false;Sensorquelle=$null;CpuTempC=$null;Luefter=@();Gpu=[ordered]@{Name='NVIDIA GeForce RTX 4070 Ti';TempC=36;LuefterProzent=0;Gruende=1};Laufwerke=@([ordered]@{Name='Samsung <SSD>';Art='SSD';TempC=$null;Verschleiss=$null;Zustand='Healthy'});Drosselung30T=0;Thermalzonen=@();AkkuVerschleiss=$null;Punkte=@([ordered]@{Stufe='warn';Text='Test warning <fan>'})}
  Stabilitaet=[ordered]@{Warnsignale=@([ordered]@{Text='TPM-Fehler';Anzahl=30})}
  Befunde=@([ordered]@{Regel='CLN-TEMP';Kategorie='Speicher';Titel='Temporaere Dateien';Risiko='Niedrig';Anzahl=2;Bytes=123456789;Objekte=@('C:\Temp (3 Dateien)','x <y>')},[ordered]@{Regel='EVT-HEALTH';Kategorie='Stabilitaet';Titel='Ereignisse';Risiko='Info';Anzahl=1;Bytes=0;Objekte=@('TPM-Fehler: 30x')})}
 $s.Score = Get-HealthScore $s
 $s | ConvertTo-Json -Depth 7 | Out-File ("$Script:SnapDir/{0}_{1}.json" -f ([datetime]$time).ToString('yyyyMMdd-HHmmss'),$label) -Encoding utf8
 [pscustomobject]$s
}
$a = MkSnap 'vorher' '2026-10-21T18:31:00' 78.3 50000 14 80
$b = MkSnap 'nachher' '2026-10-22T19:00:00' 86.1 44000 9 30
'{"Zeit":"2026-10-21T18:35:00","Lauf":"20261021-1831","Regel":"CLN-TEMP","Objekt":"C:\\Temp","Status":"OK","Bytes":123456789,"Meldung":"3 Dateien","Undo":null}' | Out-File "$Script:RunsDir/20261021-1831_apply/actions.jsonl" -Encoding utf8
'{"Zeit":"2026-10-21T18:36:00","Lauf":"20261021-1831","Regel":"STA-HEAVY","Objekt":"Spotify <b>","Status":"Fehler","Bytes":0,"Meldung":"x","Undo":null}' | Out-File "$Script:RunsDir/20261021-1831_apply/actions.jsonl" -Append -Encoding utf8
function W([string]$Text,[string]$Color='Gray',[switch]$NoNewline){ Write-Host $Text }
Show-Compare $a $b
$r = New-Report
"REPORT: $r"
"Score a: $($a.Score.Wert) b: $($b.Score.Wert)"
$fail = 0
function Check([string]$Name, [bool]$Cond) { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name" -ForegroundColor Red } }
$html = Get-Content $r -Raw -Encoding UTF8
Check 'Report: hardware section present and HTML-escaped' ($html -match 'Hardware &amp; cooling' -and $html -match 'Test warning &lt;fan&gt;' -and $html -notmatch '<SSD>')
Check 'Report: English by default' ($html -match "<html lang='en'>" -and $html -match 'Findings \(last scan\)')
# German report
Set-WtLanguage 'de' (Join-Path $PSScriptRoot '..')
$r = New-Report
$html = Get-Content $r -Raw -Encoding UTF8
Check 'Report: German with -Language de' ($html -match "<html lang='de'>" -and $html -match 'Befunde \(letzter Scan\)' -and $html -match 'Hardware &amp; K')
Check 'Report: risk shown in German' ($html -match '>Niedrig</span>')
Set-WtLanguage 'en'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red } else { Write-Host 'All report tests passed' -ForegroundColor Green }
exit $fail
