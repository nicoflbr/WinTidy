# Test-Storage.ps1 - checks the storage features without Windows: browser caches (CLN-BROWSER: detection, only cache folders,
# browser open, links, unknown paths), large files (CLN-BIGFILES: only shown, never deleted), the storage figures in the
# before/after comparison and the check reminder. Works on real folders in the temp folder. Usage: pwsh ./tests/Test-Storage.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$TestData = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-storagetest'
Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
$Script:Lang = 'en'; $Script:De = $null
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Friendly|Browser\w+)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
# Only the two storage rules
$Script:Rules = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Child -is [System.Management.Automation.Language.HashtableAst] -and $n.Extent.Text -match "^\[pscustomobject\]@\{ Id = 'CLN-(BROWSER|BIGFILES)'" }, $true) | ForEach-Object { & ([scriptblock]::Create($_.Extent.Text)) })
$Script:Cfg = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $Script:Cfg[$k] = $Script:DefaultConfig[$k] }
$Script:DataDir = $TestData; $Script:SnapDir = Join-Path $TestData 'snapshots'; $Script:RunsDir = Join-Path $TestData 'runs'
New-Item -ItemType Directory -Force $Script:SnapDir, $Script:RunsDir | Out-Null
$Script:Cache = @{}; $Script:IsAdmin = $false

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }

# --- Replace Windows parts ---
function W([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline) { }
$Script:Ctx = [pscustomobject]@{ Server = $false; Verwaltet = $false; Akku = $false; Laptop = $false; AnderesKonto = $false; NeustartAusstehend = $false; Hinweise = @() }
function Get-WtContext { $Script:Ctx }
# robocopy only exists on Windows
function Get-DirSize([string]$Path) { if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }; $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if ($s) { [int64]$s } else { [int64]0 } }
$Script:Running = @()
function Test-BrowserRunning([string]$Name) { $Script:Running -contains $Name }
function New-File([string]$Path, [int]$Bytes) { New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null; [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes)) }
function Rule([string]$Id) { $Script:Rules | Where-Object Id -eq $Id }

$Script:Cfg.BrowserCacheMinMB = 1
$env:LOCALAPPDATA = Join-Path $TestData 'Local'
$sep = [IO.Path]::DirectorySeparatorChar
$chrome = Join-WtPath $env:LOCALAPPDATA 'Google\Chrome\User Data'
$ff = Join-WtPath $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
# Chrome: two profiles plus a folder without Preferences (not a profile) and the files that must survive
foreach ($p in 'Default', 'Profile 1') {
    New-File ([IO.Path]::Combine($chrome, $p, 'Preferences')) 10
    New-File ([IO.Path]::Combine($chrome, $p, 'Cache', 'Cache_Data', 'data_1')) 700KB
    New-File ([IO.Path]::Combine($chrome, $p, 'Code Cache', 'js', 'index')) 200KB
    New-File ([IO.Path]::Combine($chrome, $p, 'Network', 'Cookies')) 100
    New-File ([IO.Path]::Combine($chrome, $p, 'Login Data')) 100
    New-File ([IO.Path]::Combine($chrome, $p, 'History')) 100
    New-File ([IO.Path]::Combine($chrome, $p, 'Bookmarks')) 100
}
New-File ([IO.Path]::Combine($chrome, 'Crashpad', 'Cache', 'x')) 300KB
New-File ([IO.Path]::Combine($chrome, 'ShaderCache', 'data_0')) 100KB
# Firefox: cache2 below the profile, cookies stay; Firefox only has 300 KB -> below the limit of 1 MB
New-File ([IO.Path]::Combine($ff, 'abc.default-release', 'cache2', 'entries', 'E1')) 300KB
New-File ([IO.Path]::Combine($ff, 'abc.default-release', 'cookies.sqlite')) 100
# A link inside the cache that points outside: its target must survive
$outside = Join-Path $TestData 'outside'; New-File (Join-Path $outside 'precious.txt') 50
$linkOk = $false
try { New-Item -ItemType SymbolicLink -Path ([IO.Path]::Combine($chrome, 'Default', 'Cache', 'link')) -Target $outside -ErrorAction Stop | Out-Null; $linkOk = $true } catch { }

# 1) Catalog and config
Check 'Browser catalog: every entry has name, process, root and kind' (@($Script:BrowserCatalog | Where-Object { -not $_.Name -or -not $_.Prozess -or -not $_.Root -or $_.Art -notin 'Chromium', 'Single', 'Firefox' }).Count -eq 0)
Check 'Only cache folder names are deleted' (@(@($Script:BrowserCacheProfileDirs) + @($Script:BrowserCacheRootDirs) + @($Script:BrowserCacheFirefoxDirs) | Where-Object { $_ -notmatch 'Cache|cache2' }).Count -eq 0)
Check 'New config keys have defaults' ($Script:DefaultConfig.Contains('BrowserCacheMinMB') -and $Script:DefaultConfig.Contains('BigFileMinMB') -and $Script:DefaultConfig.Contains('DownloadsOldDays') -and $Script:DefaultConfig.Contains('CheckReminderDays'))
$ex = Get-Content -LiteralPath (Join-Path $root 'WinTidy.config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$missing = @($Script:DefaultConfig.Keys | Where-Object { -not $ex.PSObject.Properties[$_] })
Check 'Example configuration lists every default key' ($missing.Count -eq 0) ($missing -join ', ')
$c = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $c[$k] = $Script:DefaultConfig[$k] }; $c.BrowserCacheMinMB = 0; $c.BigFileMinMB = 1; $c.DownloadsOldDays = 0
$c = Test-Config $c 3>$null
Check 'Test-Config: too small limits fall back to the default' ($c.BrowserCacheMinMB -eq 500 -and $c.BigFileMinMB -eq 1024 -and $c.DownloadsOldDays -eq 90)
Check 'Both rules have a plain-language text' ($Script:Friendly.ContainsKey('CLN-BROWSER') -and $Script:Friendly.ContainsKey('CLN-BIGFILES'))
Check 'CLN-BROWSER: Low, permanent, not preselected; CLN-BIGFILES: info without a fix' ((Rule 'CLN-BROWSER').Risiko -eq 'Niedrig' -and (Rule 'CLN-BROWSER').Endgueltig -and (Rule 'CLN-BROWSER').Vorwahl -eq $false -and (Rule 'CLN-BIGFILES').Risiko -eq 'Info' -and $null -eq (Rule 'CLN-BIGFILES').Fix)

# 2) Detection
$b = @(Get-BrowserCacheDirs)
$cb = $b | Where-Object Name -eq 'Google Chrome'
Check 'Chrome found with 2 profiles (folder without Preferences is no profile)' ($cb -and $cb.Profile -eq 2) ($cb | ConvertTo-Json -Compress -Depth 3)
Check 'Chrome cache dirs: Cache and Code Cache per profile + ShaderCache, not Crashpad' (@($cb.Dirs).Count -eq 5 -and -not (@($cb.Dirs) | Where-Object { $_ -match 'Crashpad' })) (@($cb.Dirs) -join ' | ')
Check 'Chrome size = only the cache folders' ($cb.Bytes -eq (2 * 900KB + 100KB)) $cb.Bytes
Check 'Firefox found with cache2' (($b | Where-Object Name -eq 'Mozilla Firefox').Bytes -eq 300KB)
Check 'Browsers without a folder are not listed' (-not ($b | Where-Object Name -eq 'Microsoft Edge'))
$Script:Cache = @{}
$items = @(& (Rule 'CLN-BROWSER').Detect | Where-Object { $_ })
Check 'Detect: Chrome offered, Firefox below the limit not' ($items.Count -eq 1 -and $items[0].Data.Name -eq 'Google Chrome' -and $items[0].Bytes -gt 1MB) (($items | ForEach-Object Label) -join ' | ')
Check 'Detect: closed browser is AutoOk (unattended allowed)' ($items[0].AutoOk -eq $true)
Check 'Detect changes nothing' ((Get-DirSize ([IO.Path]::Combine($chrome, 'Default', 'Cache'))) -gt 0)
$Script:Running = @('chrome'); $Script:Cache = @{}
$items2 = @(& (Rule 'CLN-BROWSER').Detect | Where-Object { $_ })
Check 'Detect: open browser is labelled and not AutoOk' ($items2[0].Label -match 'close the browser' -and $items2[0].AutoOk -eq $false)
$Script:Ctx.AnderesKonto = $true; $Script:Cache = @{}
Check 'Other account: nothing offered' (@(& (Rule 'CLN-BROWSER').Detect | Where-Object { $_ }).Count -eq 0 -and @(& (Rule 'CLN-BIGFILES').Detect | Where-Object { $_ }).Count -eq 0)
$Script:Ctx.AnderesKonto = $false

# 3) Fix
$msg = $null; try { & (Rule 'CLN-BROWSER').Fix $items2[0] } catch { $msg = $_.Exception.Message }
Check 'Fix with the browser open: SKIP, nothing deleted' ($msg -like 'SKIP:*' -and (Get-DirSize ([IO.Path]::Combine($chrome, 'Default', 'Cache'))) -gt 0) $msg
$Script:Running = @()
$bad = [pscustomobject]@{ Data = @{ Name = 'Google Chrome'; Prozess = 'chrome'; Root = $chrome; Dirs = @([IO.Path]::Combine($chrome, 'Default', 'Network')) } }
$msg = $null; try { & (Rule 'CLN-BROWSER').Fix $bad } catch { $msg = $_.Exception.Message }
Check 'Fix refuses a folder that is not a cache folder' ($msg -eq 'Unexpected path' -and (Test-Path ([IO.Path]::Combine($chrome, 'Default', 'Network', 'Cookies'))))
$bad2 = [pscustomobject]@{ Data = @{ Name = 'Google Chrome'; Prozess = 'chrome'; Root = $outside; Dirs = @((Join-Path $outside 'Cache')) } }
$msg = $null; try { & (Rule 'CLN-BROWSER').Fix $bad2 } catch { $msg = $_.Exception.Message }
Check 'Fix refuses an unknown browser root' ($msg -eq 'Unexpected path')
$bad3 = [pscustomobject]@{ Data = @{ Name = 'Google Chrome'; Prozess = 'chrome'; Root = $chrome; Dirs = @((Join-Path $outside 'Cache')) } }
$msg = $null; try { & (Rule 'CLN-BROWSER').Fix $bad3 } catch { $msg = $_.Exception.Message }
Check 'Fix refuses a cache folder outside the browser root' ($msg -eq 'Unexpected path')
$msg = & (Rule 'CLN-BROWSER').Fix $items[0]
Check 'Fix: cache folders emptied' ((Get-DirSize ([IO.Path]::Combine($chrome, 'Default', 'Cache'))) -eq 0 -and (Get-DirSize ([IO.Path]::Combine($chrome, 'Profile 1', 'Code Cache'))) -eq 0 -and (Get-DirSize ([IO.Path]::Combine($chrome, 'ShaderCache'))) -eq 0) $msg
Check 'Fix: the cache folders themselves stay' (Test-Path -LiteralPath ([IO.Path]::Combine($chrome, 'Default', 'Cache')))
$keep = @('Preferences', 'Network/Cookies', 'Login Data', 'History', 'Bookmarks' | ForEach-Object { Join-WtPath (Join-Path $chrome 'Default') $_ } | Where-Object { -not (Test-Path -LiteralPath $_) })
Check 'Fix: cookies, sign-ins, history, bookmarks and settings stay' ($keep.Count -eq 0) ($keep -join ', ')
Check 'Fix: other folders (Crashpad) and other browsers untouched' ((Test-Path ([IO.Path]::Combine($chrome, 'Crashpad', 'Cache', 'x'))) -and (Test-Path ([IO.Path]::Combine($ff, 'abc.default-release', 'cache2', 'entries', 'E1'))))
Check 'Fix reports the freed space' ($msg -match 'freed')
if ($linkOk) { Check 'Fix: link in the cache is not followed (target survives)' (Test-Path -LiteralPath (Join-Path $outside 'precious.txt')) }
else { Write-Host 'SKIP   link test (symbolic links not allowed here)' -ForegroundColor DarkGray }

# 4) Large files: only shown
$pf = Join-Path $TestData 'Profile'
$Script:Folders = @([pscustomobject]@{ Art = 'Downloads'; Pfad = (Join-Path $pf 'Downloads') }, [pscustomobject]@{ Art = 'Videos'; Pfad = (Join-Path $pf 'Videos') })
function Get-PersonalFolders { $Script:Folders }
New-File (Join-Path $pf 'Downloads/setup.iso') 3MB
New-File (Join-Path $pf 'Downloads/small.txt') 1KB
New-File (Join-Path $pf 'Videos/Holiday/clip.mp4') 2MB
$big = Get-PersonalFileStats 1MB 3650
Check 'Large files: sorted by size, small files ignored' (@($big.Gross).Count -eq 2 -and $big.Gross[0].Rel -match 'setup\.iso$' -and $big.Gross[1].Rel -match ('^Videos' + [regex]::Escape([string]$sep) + 'Holiday'))
Check 'Large files: nothing in Downloads counts as old with a long limit' ($big.AltDownloads -eq 0)
$Script:Cache = @{}
$old = Get-PersonalFileStats 1MB -1
Check 'Old Downloads: counted and summed (videos do not count)' ($old.AltDownloads -eq 2 -and $old.AltDownloadsBytes -eq (3MB + 1KB))
$Script:Cache = @{}
$cap = Get-PersonalFileStats 1MB 3650 2
Check 'File limit stops the walk' ($cap.Abgebrochen -and $cap.Dateien -eq 2)
$Script:Cache = @{}; $Script:Cfg.BigFileMinMB = 1; $Script:Cfg.DownloadsOldDays = 3650
$bi = @(& (Rule 'CLN-BIGFILES').Detect | Where-Object { $_ })
Check 'CLN-BIGFILES: one info item with count, total and largest file' ($bi.Count -eq 1 -and $bi[0].Data.Anzahl -eq 2 -and $bi[0].Label -match 'setup\.iso' -and $bi[0].Bytes -eq 0) (($bi | ForEach-Object Label) -join ' | ')
Check 'CLN-BIGFILES: nothing deleted' ((Test-Path (Join-Path $pf 'Downloads/setup.iso')) -and (Test-Path (Join-Path $pf 'Videos/Holiday/clip.mp4')))
if ($linkOk) {
    New-Item -ItemType SymbolicLink -Path (Join-Path $pf 'Videos/linked') -Target (Join-Path $TestData 'Local') | Out-Null
    $Script:Cache = @{}
    $lk = Get-PersonalFileStats 1 3650
    Check 'Large files: links are not followed' (-not (@($lk.Gross) | Where-Object { $_.Pfad -match 'linked' }))
}

# 5) Before/after: storage figures from the snapshot
$sa = [pscustomobject]@{ Laufwerke = @(); Score = @{ Wert = 70 }; Boot = @{}; Autostart = @{}; Dienste = @{}; Leerlauf = @{}; Treiber = @{}; Ereignisse = @{}; Programme = @{}; Aufgaben = @{}; Speicher = [pscustomobject]@{ PapierkorbBytes = 2GB; TempBytes = 500MB; CrashDumpsBytes = 0; BrowserCacheBytes = 1GB } }
$sb = [pscustomobject]@{ Laufwerke = @(); Score = @{ Wert = 75 }; Boot = @{}; Autostart = @{}; Dienste = @{}; Leerlauf = @{}; Treiber = @{}; Ereignisse = @{}; Programme = @{}; Aufgaben = @{}; Speicher = [pscustomobject]@{ PapierkorbBytes = 1GB; TempBytes = 100MB; CrashDumpsBytes = 0; BrowserCacheBytes = 10MB } }
$env:SystemDrive = 'C:'
$m = @(Get-CompareMetrics $sa $sb)
$mb = $m | Where-Object Kennzahl -eq 'Browser caches'
Check 'Comparison: browser caches in MB, smaller = better' ($mb -and $mb.Vorher -eq 1024 -and $mb.Nachher -eq 10 -and $mb.Bewertung -eq 'besser' -and $mb.Einheit -eq 'MB')
Check 'Comparison: temp files and recycle bin present' (($m | Where-Object Kennzahl -eq 'Temporary files (own temp folder)').Delta -eq -400 -and ($m | Where-Object Kennzahl -eq 'Recycle bin').Bewertung -eq 'besser')
$sOld = [pscustomobject]@{ Laufwerke = @(); Score = @{ Wert = 70 }; Speicher = [pscustomobject]@{ PapierkorbBytes = 0; TempBytes = 0; CrashDumpsBytes = 0 } }
$mo = (@(Get-CompareMetrics $sOld $sb) | Where-Object Kennzahl -eq 'Browser caches')
Check 'Comparison: old snapshot without the field shows no delta' ($null -eq $mo.Vorher -and $null -eq $mo.Delta -and $mo.Bewertung -eq '=')

# 6) Check reminder
$Script:Cfg.CheckReminderDays = 30
Check 'Reminder: no snapshot yet -> none' ($null -eq (Get-CheckReminder))
'{}' | Out-File (Join-Path $Script:SnapDir ('{0}_scan.json' -f (Get-Date).AddDays(-40).ToString('yyyyMMdd-HHmmss')))
$r = Get-CheckReminder
Check 'Reminder: last check 40 days ago -> reminder with the number of days' ($r -and $r.Tage -ge 39 -and $r.Text -match '\d+ days ago')
$Script:Cfg.CheckReminderDays = 0
Check 'Reminder: CheckReminderDays = 0 switches it off' ($null -eq (Get-CheckReminder))
$Script:Cfg.CheckReminderDays = 30
'{}' | Out-File (Join-Path $Script:SnapDir ('{0}_scan.json' -f (Get-Date).AddDays(-2).ToString('yyyyMMdd-HHmmss')))
Check 'Reminder: recent check -> none' ($null -eq (Get-CheckReminder))

# 7) German texts
Set-WtLanguage 'de' $root
Check 'German: rule title and reminder translated' ((T 'Large browser caches') -eq 'Große Browser-Zwischenspeicher' -and (T 'The last check of this PC was {0} days ago. A new check shows what has changed since - it changes nothing.' 40) -match '40 Tage')
Set-WtLanguage 'en'

Remove-Item $TestData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail test(s) failed" -ForegroundColor Red } else { Write-Host 'All storage tests passed' -ForegroundColor Green }
exit $fail
