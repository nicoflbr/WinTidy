# Test-Update.ps1 - checks the updater (check -> download/verify -> install, rollback, security checks) completely offline:
# the release information and the downloads are replaced, ZIP packages are built on the fly. Usage: pwsh ./tests/Test-Update.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$Tmp = Join-Path ([IO.Path]::GetTempPath()) 'wintidy-updatetest'
Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Tmp | Out-Null
$AppDir = Join-Path $Tmp 'app'
$Script:DataDir = Join-Path $Tmp 'data'
$UpdDir = Join-Path $Script:DataDir 'update'

# Load the functions and constants of the engine
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Update\w+|PendingUpdate)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:Lang = 'en'; $Script:De = $null

$fail = 0
function Check([string]$Name, [bool]$Cond, $Detail = '') { if ($Cond) { Write-Host "OK     $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAILED $Name  $Detail" -ForegroundColor Red } }

# --- Replace everything that needs the network or Windows ---
$Script:MockRelease = $null; $Script:MockThrow = $null; $Script:MockZip = $null; $Script:MockShaText = $null; $Script:MockSafe = $true
$Script:SavedUrls = New-Object System.Collections.Generic.List[string]
function Get-LatestRelease { if ($Script:MockThrow) { throw $Script:MockThrow }; $Script:MockRelease }
function Save-WtHttpFile([string]$Url, [string]$Path, [int64]$MaxBytes) { $Script:SavedUrls.Add($Url); Copy-Item -LiteralPath $Script:MockZip -Destination $Path -Force }
function Get-WtHttpText([string]$Url, [string]$Accept = '*/*', [int]$MaxBytes = 1MB) { $Script:MockShaText }
function Test-WtDataRootSafe([string]$Path) { $Script:MockSafe }

# --- Helpers ---
$OldEngine = "`$Script:Version = '1.0.0'`r`n# old engine`r`n"
$OldApp = "# old app`r`n"
$OwnConfig = '{"Own": 1}'
function Write-Txt([string]$Path, [string]$Text) {
    $d = [IO.Path]::GetDirectoryName($Path)
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($Path, $Text)
}
function Read-Txt([string]$Path) { [IO.File]::ReadAllText($Path) }
function Initialize-Env {
    foreach ($d in $AppDir, $Script:DataDir) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    New-Item -ItemType Directory -Force $AppDir, $Script:DataDir | Out-Null
    Write-Txt (Join-Path $AppDir 'WinTidy.ps1') $OldEngine
    Write-Txt (Join-Path $AppDir 'WinTidy-App.ps1') $OldApp
    Write-Txt (Join-Path $AppDir 'WinTidy.cmd') "@echo off`r`n"
    Write-Txt (Join-Path $AppDir 'WinTidy.config.json') $OwnConfig
    Write-Txt (Join-Path $AppDir 'lang/de.psd1') "@{ 'old' = 'alt' }"
    $Script:Cfg = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $Script:Cfg[$k] = $Script:DefaultConfig[$k] }
    $Script:Cfg.UpdateEnabled = $true
    $Script:ToolRoot = $AppDir; $Script:Version = '1.0.0'; $Script:IsAdmin = $true; $Script:DataDirProtected = $true
    $Script:PendingUpdate = $null; $Script:MockThrow = $null; $Script:MockSafe = $true; $Script:MockShaText = $null; $Script:SavedUrls.Clear()
}
function New-PkgFiles([string]$Ver = '2.0.0', [string]$Top = 'auto') {
    if ($Top -eq 'auto') { $Top = "WinTidy-v$Ver" }
    $p = if ($Top) { "$Top/" } else { '' }
    $h = [ordered]@{}
    $h[$p + 'WinTidy.ps1'] = "`$Script:Version = '$Ver'`r`n# new engine`r`n"
    $h[$p + 'WinTidy-App.ps1'] = "# new app $Ver`r`n"
    $h[$p + 'WinTidy.cmd'] = "@echo off`r`n"
    $h[$p + 'WinTidy.config.json'] = '{"Pkg": 1}'
    $h[$p + 'README.md'] = "readme $Ver"
    $h[$p + 'LICENSE'] = 'MIT'
    $h[$p + 'lang/de.psd1'] = "@{ 'new' = 'neu' }"
    $h
}
function New-TestZip([string]$Path, [System.Collections.IDictionary]$Files) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $z = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($k in $Files.Keys) {
            $e = $z.CreateEntry($k)
            $sw = New-Object IO.StreamWriter ($e.Open(), (New-Object Text.UTF8Encoding $false))
            try { $sw.Write([string]$Files[$k]) } finally { $sw.Dispose() }
        }
    } finally { $z.Dispose() }
}
# Makes the mocks return a release whose ZIP is built from $Files (default: valid package 2.0.0)
function Set-MockRelease([System.Collections.IDictionary]$Files = $null, [string]$Ver = '2.0.0', $Digest = 'auto', $ShaText = $null, [string]$ZipUrl = '', [int64]$Size = -1) {
    if (-not $Files) { $Files = New-PkgFiles $Ver }
    $zip = Join-Path $Tmp ("pkg-$Ver.zip")
    New-TestZip $zip $Files
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    if ($Digest -eq 'auto') { $Digest = $hash }
    if (-not $ZipUrl) { $ZipUrl = "https://github.com/nicoflbr/WinTidy/releases/download/v$Ver/WinTidy-v$Ver.zip" }
    if ($Size -lt 0) { $Size = (Get-Item -LiteralPath $zip).Length }
    $Script:MockZip = $zip; $Script:MockShaText = $ShaText
    $Script:MockRelease = [pscustomobject]@{
        Tag = "v$Ver"; Version = [version]$Ver; ZipUrl = $ZipUrl; ZipSize = $Size; Digest = [string]$Digest
        ShaUrl = $(if ($null -ne $ShaText) { "https://github.com/nicoflbr/WinTidy/releases/download/v$Ver/WinTidy-v$Ver.zip.sha256" } else { '' })
        Notes = 'Release notes'; PageUrl = "https://github.com/nicoflbr/WinTidy/releases/tag/v$Ver"
    }
    return $hash
}
function Invoke-CheckAndStage { $c = Invoke-GuiUpdateCheck; if ($c.Status -ne 'NEU') { return $c }; Invoke-GuiUpdateStage }
function Test-RootOld {
    (Read-Txt (Join-Path $AppDir 'WinTidy.ps1')) -eq $OldEngine -and (Read-Txt (Join-Path $AppDir 'WinTidy-App.ps1')) -eq $OldApp -and
    (Read-Txt (Join-Path $AppDir 'lang/de.psd1')) -eq "@{ 'old' = 'alt' }" -and
    -not (Test-Path -LiteralPath (Join-Path $AppDir 'README.md')) -and -not (Test-Path -LiteralPath (Join-Path $AppDir 'LICENSE')) -and
    @(Get-ChildItem -LiteralPath $AppDir -Recurse -Force -Filter '*.wt*').Count -eq 0
}
$Staged = Join-Path $UpdDir 'staged'

# 1) Version numbers
Check 'ConvertTo-WtVersion: v1.4.2' ((ConvertTo-WtVersion 'v1.4.2') -eq [version]'1.4.2')
Check 'ConvertTo-WtVersion: 1.10.0 is newer than 1.9.0' ((ConvertTo-WtVersion '1.10.0') -gt (ConvertTo-WtVersion '1.9.0'))
foreach ($bad in 'v1.4', '1.4.2-beta', 'abc', '', 'v1.4.2.1', '1.4.2 ', 'v1.4.x') { Check "ConvertTo-WtVersion rejects '$bad'" ($null -eq (ConvertTo-WtVersion $bad)) }

# 2) Allowed files of a package
foreach ($ok in 'WinTidy.ps1', 'WinTidy-App.ps1', 'lang/de.psd1', 'LICENSE', 'WinTidy App.cmd', 'WinTidy.config.json', 'README.md', 'Console.md') { Check "Test-WtUpdatePath allows '$ok'" (Test-WtUpdatePath $ok) }
foreach ($bad in '../x.ps1', 'a/../b.ps1', 'x.exe', 'lang/sub/x.psd1', '/abs.ps1', 'C:/x.ps1', 'lang\de.psd1', 'NUL.txt', 'com1.md', 'file .md', '.hidden.ps1', 'x..ps1', 'tool.dll', 'run.bat', 'a.ps1.lnk', '') { Check "Test-WtUpdatePath rejects '$bad'" (-not (Test-WtUpdatePath $bad)) }

# 3) Addresses: only https and GitHub hosts (nothing is sent here, the check comes first)
foreach ($h in 'github.com', 'api.github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com') { Check "Host allowed: $h" ($h -match $Script:UpdateHostPattern) }
foreach ($h in 'github.com.evil.com', 'evilgithub.com', 'githubusercontent.com.evil.org', 'example.com', 'xgithubusercontent.com') { Check "Host blocked: $h" (-not ($h -match $Script:UpdateHostPattern)) }
foreach ($u in 'http://github.com/x', 'https://evil.example.com/x', 'https://github.com.evil.com/x', 'ftp://github.com/x', 'file:///etc/passwd', 'https://github.com@evil.example.com/x', 'not a url') {
    $msg = ''; try { $r = Open-WtHttp $u; $r.Close() } catch { $msg = $_.Exception.Message }
    Check "Open-WtHttp blocks $u" ($msg -like 'Blocked address*') $msg
}

# 4) Configuration values
$c = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $c[$k] = $Script:DefaultConfig[$k] }
$c.UpdateRepo = 'bad repo'; $c.UpdateIntervalHours = 0; $c.UpdateEnabled = 1
$c = Test-Config $c 3>$null
Check 'Test-Config: invalid UpdateRepo -> default' ($c.UpdateRepo -eq $Script:DefaultConfig.UpdateRepo)
Check 'Test-Config: interval below minimum -> default' ($c.UpdateIntervalHours -eq $Script:DefaultConfig.UpdateIntervalHours)
Check 'Test-Config: UpdateEnabled becomes a boolean' ($c.UpdateEnabled -is [bool] -and $c.UpdateEnabled)
$c2 = @{}; foreach ($k in $Script:DefaultConfig.Keys) { $c2[$k] = $Script:DefaultConfig[$k] }
$c2.UpdateRepo = 'someone/else-repo.1'
Check 'Test-Config: valid UpdateRepo is kept' ((Test-Config $c2).UpdateRepo -eq 'someone/else-repo.1')
$ex = Get-Content -LiteralPath (Join-Path $root 'WinTidy.config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'Example configuration lists the update keys' ($null -ne $ex.UpdateRepo -and $null -ne $ex.UpdateIntervalHours -and $null -ne $ex.UpdateEnabled)
Check 'Default: updates on, repo and interval set' ($Script:DefaultConfig.UpdateEnabled -eq $true -and $Script:DefaultConfig.UpdateRepo -eq 'nicoflbr/WinTidy' -and $Script:DefaultConfig.UpdateIntervalHours -eq 24)

# 5) Blockers
Initialize-Env
Check 'No blocker in the normal case' ($null -eq (Get-WtUpdateBlocker))
$Script:Cfg.UpdateEnabled = $false
Check 'Blocker: UpdateEnabled=false (check, stage, apply)' ((Invoke-GuiUpdateCheck).Status -eq 'GESPERRT' -and (Invoke-GuiUpdateStage).Status -eq 'GESPERRT' -and (Invoke-GuiUpdateApply).Status -eq 'GESPERRT')
Initialize-Env; $Script:IsAdmin = $false
Check 'Blocker: no admin rights' ((Invoke-GuiUpdateCheck).Status -eq 'GESPERRT')
Initialize-Env; $Script:DataDirProtected = $false
Check 'Blocker: data folder not protected (-DataPath)' ((Invoke-GuiUpdateCheck).Status -eq 'GESPERRT')
Initialize-Env; New-Item -ItemType Directory -Force (Join-Path $AppDir '.git') | Out-Null
Check 'Blocker: git clone' ((Get-WtUpdateBlocker) -like '*git clone*')
Initialize-Env; $Script:ToolRoot = '\\server\share\WinTidy'
Check 'Blocker: network path' ((Get-WtUpdateBlocker) -like '*network drive*')

# 6) Check: statuses
Initialize-Env
$null = Set-MockRelease -Ver '1.0.0'
Check 'Check: same version -> AKTUELL' ((Invoke-GuiUpdateCheck).Status -eq 'AKTUELL')
$null = Set-MockRelease -Ver '0.9.0'
Check 'Check: older release -> AKTUELL' ((Invoke-GuiUpdateCheck).Status -eq 'AKTUELL')
$null = Set-MockRelease -Ver '2.0.0'
$r = Invoke-GuiUpdateCheck
Check 'Check: newer release -> NEU with version and notes' ($r.Status -eq 'NEU' -and $r.Neu -eq '2.0.0' -and $r.Aktuell -eq '1.0.0' -and $r.Notizen -eq 'Release notes' -and $Script:PendingUpdate.Version -eq [version]'2.0.0')
$Script:MockRelease.Notes = 'x' * 1000
Check 'Check: long notes are shortened' ((Invoke-GuiUpdateCheck).Notizen.Length -le 705)
$Script:MockRelease = $null
$r = Invoke-GuiUpdateCheck
Check 'Check: no release -> FEHLER, nothing pending' ($r.Status -eq 'FEHLER' -and $r.Meldung -like '*No installable release*' -and $null -eq $Script:PendingUpdate)
$Script:MockThrow = 'boom'
$r = Invoke-GuiUpdateCheck
Check 'Check: network error -> FEHLER with text' ($r.Status -eq 'FEHLER' -and $r.Meldung -like '*boom*')
$Script:MockThrow = $null; $null = Set-MockRelease -Ver '2.0.0'; $Script:Version = 'abc'
Check 'Check: unreadable own version -> FEHLER' ((Invoke-GuiUpdateCheck).Status -eq 'FEHLER')
$Script:Version = '1.0.0'
Check 'Stage without check -> FEHLER' ((& { $Script:PendingUpdate = $null; (Invoke-GuiUpdateStage).Meldung }) -like '*check for updates first*')

# 7) Happy path: check -> stage -> apply
Initialize-Env
$hash = Set-MockRelease -Ver '2.0.0'
$s = Invoke-CheckAndStage
Check 'Stage: BEREIT' ($s.Status -eq 'BEREIT' -and $s.Version -eq '2.0.0') ($s | Out-String)
Check 'Stage: downloaded from the release address' ($Script:SavedUrls.Count -eq 1 -and $Script:SavedUrls[0] -like 'https://github.com/nicoflbr/WinTidy/releases/download/*')
Check 'Stage: program folder untouched' (Test-RootOld)
Check 'Stage: staged.json and files exist, download folder removed' ((Test-Path -LiteralPath (Join-Path $Staged 'staged.json')) -and (Test-Path -LiteralPath (Join-Path $Staged 'files/WinTidy.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $UpdDir 'download')))
$a = Invoke-GuiUpdateApply
Check 'Apply: OK' ($a.Status -eq 'OK' -and $a.Version -eq '2.0.0' -and -not $a.Zurueck) ($a | Out-String)
Check 'Apply: 5 files replaced (unchanged launcher and own config skipped)' ($a.Geaendert -eq 5) "$($a.Geaendert)"
Check 'Apply: new engine and app in place' ((Read-Txt (Join-Path $AppDir 'WinTidy.ps1')) -like "*Version = '2.0.0'*" -and (Read-Txt (Join-Path $AppDir 'WinTidy-App.ps1')) -like '*new app 2.0.0*')
Check 'Apply: new files added, language file replaced' ((Test-Path -LiteralPath (Join-Path $AppDir 'README.md')) -and (Test-Path -LiteralPath (Join-Path $AppDir 'LICENSE')) -and (Read-Txt (Join-Path $AppDir 'lang/de.psd1')) -like "*'new'*")
Check 'Apply: existing WinTidy.config.json is never overwritten' ((Read-Txt (Join-Path $AppDir 'WinTidy.config.json')) -eq $OwnConfig)
Check 'Apply: backup of the old files' ((Read-Txt (Join-Path $UpdDir 'backup/1.0.0/WinTidy.ps1')) -eq $OldEngine -and (Read-Txt (Join-Path $UpdDir 'backup/1.0.0/lang/de.psd1')) -eq "@{ 'old' = 'alt' }" -and $a.Sicherung -like '*1.0.0')
Check 'Apply: no temporary files, no journal, staging removed' (@(Get-ChildItem -LiteralPath $AppDir -Recurse -Force -Filter '*.wt*').Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $UpdDir 'journal.json')) -and -not (Test-Path -LiteralPath $Staged))
Check 'Apply: update.log written' ((Test-Path -LiteralPath (Join-Path $UpdDir 'update.log')) -and (Read-Txt (Join-Path $UpdDir 'update.log')) -like '*Installed version 2.0.0*')
Check 'Apply twice: second call has nothing to install' ((Invoke-GuiUpdateApply).Status -eq 'FEHLER')

# 8) Config.json is created when it does not exist yet
Initialize-Env; Remove-Item -LiteralPath (Join-Path $AppDir 'WinTidy.config.json') -Force
$null = Set-MockRelease -Ver '2.0.0'; $null = Invoke-CheckAndStage; $a = Invoke-GuiUpdateApply
Check 'Missing WinTidy.config.json is taken from the package' ($a.Status -eq 'OK' -and (Read-Txt (Join-Path $AppDir 'WinTidy.config.json')) -eq '{"Pkg": 1}')

# 9) Package without top folder, uppercase digest, checksum only from the .sha256 file
Initialize-Env
$null = Set-MockRelease -Files (New-PkgFiles '2.0.0' '') -Ver '2.0.0'
Check 'Flat package (no top folder) is accepted' ((Invoke-CheckAndStage).Status -eq 'BEREIT')
Initialize-Env
$h = Set-MockRelease -Ver '2.0.0'; $Script:MockRelease.Digest = $h.ToUpper()
Check 'Uppercase digest is accepted' ((Invoke-CheckAndStage).Status -eq 'BEREIT')
Initialize-Env
$h = Set-MockRelease -Ver '2.0.0' -Digest '' -ShaText 'placeholder'; $Script:MockShaText = "$($h.ToUpper())  WinTidy-v2.0.0.zip`n"
Check 'Only the .sha256 file (no digest) is enough' ((Invoke-CheckAndStage).Status -eq 'BEREIT')
Initialize-Env
$h = Set-MockRelease -Ver '2.0.0' -ShaText 'placeholder'; $Script:MockShaText = "$h  WinTidy-v2.0.0.zip"
Check 'Digest and .sha256 file agree' ((Invoke-CheckAndStage).Status -eq 'BEREIT')

# 10) Stage refuses: every case leaves the program folder and the staging folder clean
function Test-StageRefused([string]$Name, [string]$Pattern) {
    $r = Invoke-CheckAndStage
    Check "Stage refuses: $Name" ($r.Status -eq 'FEHLER' -and $r.Meldung -like $Pattern -and -not (Test-Path -LiteralPath $Staged) -and (Test-RootOld)) ($r | Out-String)
}
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -Digest ('0' * 64)
Test-StageRefused 'wrong digest' '*checksum of the download is wrong*'
Initialize-Env; $h = Set-MockRelease -Ver '2.0.0' -ShaText 'x'; $Script:MockShaText = ('1' * 64)
Test-StageRefused 'digest and .sha256 file disagree' '*do not match each other*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -Digest '' -ShaText ('2' * 64)
Test-StageRefused 'wrong checksum in the .sha256 file' '*checksum of the download is wrong*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -Digest '' -ShaText 'no hash in here'
Test-StageRefused 'unreadable .sha256 file' '*checksum file of the release is not readable*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -Digest ''
Test-StageRefused 'no checksum at all' '*has no checksum*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -ZipUrl 'https://evil.example.com/WinTidy-v2.0.0.zip'
Test-StageRefused 'foreign host' '*unexpected address*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -ZipUrl 'https://github.com/other/repo/releases/download/v2.0.0/WinTidy-v2.0.0.zip'
Test-StageRefused 'other repository' '*unexpected address*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -ZipUrl 'http://github.com/nicoflbr/WinTidy/releases/download/v2.0.0/WinTidy-v2.0.0.zip'
Test-StageRefused 'http instead of https' '*unexpected address*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -Size (50MB)
Test-StageRefused 'announced size too large' '*larger than expected*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0' -Size 0
Test-StageRefused 'announced size zero' '*larger than expected*'

$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/../evil.ps1'] = 'x'
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'zip-slip (../ in the entry name)' '*unexpected file*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/lang/..\..\evil.ps1'] = 'x'
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'zip-slip (backslashes)' '*unexpected file*'
$p = New-PkgFiles '2.0.0'; $p['/abs.ps1'] = 'x'
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'absolute entry name' '*unexpected file*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/evil.exe'] = 'MZ'
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'executable file' '*unexpected file*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/a/b/deep.ps1'] = '# x'
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'nested too deep' '*unexpected file*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/lang\de.psd1'] = 'dup'
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'duplicate name (backslash spelling of an existing entry)' '*unexpected file*'
$p = New-PkgFiles '2.0.0'; for ($i = 0; $i -lt 101; $i++) { $p["WinTidy-v2.0.0/f$i.txt"] = 'x' }
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'too many files' '*unexpected number of files*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/big.txt'] = ('x' * (11MB))
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'single file too large' '*larger than expected*'
$p = New-PkgFiles '2.0.0'; $null = $p.Remove('WinTidy-v2.0.0/lang/de.psd1')
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'required file missing' '*incomplete*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/WinTidy-App.ps1'] = 'function { {{ ('
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'syntax error in a script' '*syntax error*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/WinTidy.ps1'] = "`$Script:Version = '2.0.1'`r`n"
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'version in the package differs from the release' '*does not match the release*'
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/WinTidy.ps1'] = "# no version here`r`n"
Initialize-Env; $null = Set-MockRelease -Files $p -Ver '2.0.0'
Test-StageRefused 'no version number in the package' '*does not match the release*'
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0'
$bad = Join-Path $Tmp 'not-a-zip.zip'; [IO.File]::WriteAllText($bad, 'this is not a zip file')
$Script:MockZip = $bad; $Script:MockRelease.Digest = (Get-FileHash -LiteralPath $bad -Algorithm SHA256).Hash.ToLower(); $Script:MockRelease.ZipSize = 22
Test-StageRefused 'file is not a ZIP' '*could not be downloaded*'

# 11) Apply refuses
Initialize-Env; $null = Set-MockRelease -Ver '2.0.0'
Check 'Apply without staged update -> FEHLER' ((Invoke-GuiUpdateApply).Meldung -like '*no downloaded update*')
$null = Invoke-CheckAndStage; $Script:MockSafe = $false
$a = Invoke-GuiUpdateApply
Check 'Apply: staging folder not protected -> FEHLER, nothing changed' ($a.Status -eq 'FEHLER' -and $a.Meldung -like '*not protected*' -and (Test-RootOld))
$Script:MockSafe = $true; $Script:Version = '3.0.0'
$a = Invoke-GuiUpdateApply
Check 'Apply: staged version not newer -> FEHLER, nothing changed' ($a.Status -eq 'FEHLER' -and $a.Meldung -like '*not newer*') ($a | Out-String)
$Script:Version = '1.0.0'

Initialize-Env; $null = Set-MockRelease -Ver '2.0.0'; $null = Invoke-CheckAndStage
Add-Content -LiteralPath (Join-Path $Staged 'files/WinTidy-App.ps1') -Value '# tampered'
$a = Invoke-GuiUpdateApply
Check 'Apply: changed staged file -> FEHLER, nothing changed' ($a.Status -eq 'FEHLER' -and $a.Meldung -like '*was changed*' -and (Test-RootOld)) ($a | Out-String)

Initialize-Env; $null = Set-MockRelease -Ver '2.0.0'; $null = Invoke-CheckAndStage
$mf = Join-Path $Staged 'staged.json'
$m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
$m.Dateien[0].Pfad = 'evil.exe'
$m | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $mf -Encoding utf8
$a = Invoke-GuiUpdateApply
Check 'Apply: forbidden path in staged.json -> FEHLER, nothing changed' ($a.Status -eq 'FEHLER' -and $a.Meldung -like '*unexpected file*' -and (Test-RootOld)) ($a | Out-String)

# 12) Rollback: a directory with the name of a new file makes the installation fail half way
Initialize-Env
$p = New-PkgFiles '2.0.0'; $p['WinTidy-v2.0.0/ZZ-conflict.md'] = 'conflict'
$null = Set-MockRelease -Files $p -Ver '2.0.0'
$s = Invoke-CheckAndStage
New-Item -ItemType Directory -Force (Join-Path $AppDir 'ZZ-conflict.md') | Out-Null
$a = Invoke-GuiUpdateApply
Check 'Rollback: failed installation reports FEHLER and rolled back' ($s.Status -eq 'BEREIT' -and $a.Status -eq 'FEHLER' -and $a.Zurueck -eq $true) ($a | Out-String)
Check 'Rollback: old files are back, new files removed' (Test-RootOld)
Check 'Rollback: engine was never touched (replaced last)' ((Read-Txt (Join-Path $AppDir 'WinTidy.ps1')) -eq $OldEngine)
Check 'Rollback: config untouched, conflicting folder still there, no journal' ((Read-Txt (Join-Path $AppDir 'WinTidy.config.json')) -eq $OwnConfig -and (Test-Path -LiteralPath (Join-Path $AppDir 'ZZ-conflict.md') -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $UpdDir 'journal.json')))

# 13) Journal of an interrupted installation is repaired at the next check
Initialize-Env
New-Item -ItemType Directory -Force (Join-Path $UpdDir 'backup/1.0.0') | Out-Null
Write-Txt (Join-Path $UpdDir 'backup/1.0.0/WinTidy-App.ps1') 'OLD-APP-BACKUP'
Write-Txt (Join-Path $AppDir 'WinTidy-App.ps1') 'HALF-WRITTEN'
Write-Txt (Join-Path $AppDir 'README.md') 'new file'
Write-Txt (Join-Path $AppDir 'README.md.wtnew') 'leftover'
[ordered]@{ Von = '1.0.0'; Nach = '2.0.0'; Fertig = $false; Dateien = @([ordered]@{ Pfad = 'WinTidy-App.ps1'; Vorhanden = $true }, [ordered]@{ Pfad = 'README.md'; Vorhanden = $false }) } | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $UpdDir 'journal.json') -Encoding utf8
$null = Set-MockRelease -Ver '1.0.0'
Check 'Check repairs an unfinished installation' ((Invoke-GuiUpdateCheck).Status -eq 'AKTUELL' -and (Read-Txt (Join-Path $AppDir 'WinTidy-App.ps1')) -eq 'OLD-APP-BACKUP' -and -not (Test-Path -LiteralPath (Join-Path $AppDir 'README.md')) -and -not (Test-Path -LiteralPath (Join-Path $AppDir 'README.md.wtnew')) -and -not (Test-Path -LiteralPath (Join-Path $UpdDir 'journal.json')))
Initialize-Env
New-Item -ItemType Directory -Force $UpdDir | Out-Null
Write-Txt (Join-Path $AppDir 'WinTidy-App.ps1') 'NEW-AND-COMPLETE'
[ordered]@{ Von = '1.0.0'; Nach = '2.0.0'; Fertig = $true; Dateien = @([ordered]@{ Pfad = 'WinTidy-App.ps1'; Vorhanden = $true }) } | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $UpdDir 'journal.json') -Encoding utf8
$null = Set-MockRelease -Ver '1.0.0'; $null = Invoke-GuiUpdateCheck
Check 'A finished installation is not rolled back (journal only removed)' ((Read-Txt (Join-Path $AppDir 'WinTidy-App.ps1')) -eq 'NEW-AND-COMPLETE' -and -not (Test-Path -LiteralPath (Join-Path $UpdDir 'journal.json')))
Initialize-Env
New-Item -ItemType Directory -Force $UpdDir | Out-Null
Write-Txt (Join-Path $UpdDir 'journal.json') '{ this is not json'
Check 'Corrupt journal does not break the check' ((Invoke-GuiUpdateCheck).Status -eq 'AKTUELL')

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red } else { Write-Host "`nAll update checks passed" -ForegroundColor Green }
exit $fail
