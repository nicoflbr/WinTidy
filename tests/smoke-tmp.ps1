$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $n.Parent.Parent -eq $ast }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Parent -eq $ast -and $n.Left.Extent.Text -match '^\$Script:(DefaultConfig|Update\w+|PendingUpdate)$' }, $false)) { . ([scriptblock]::Create($a.Extent.Text)) }
$Script:Lang = 'en'; $Script:Version = '1.0.0'; $Script:Cfg = $Script:DefaultConfig
$msgs = @()
try {
    $r = Get-LatestRelease
    $msgs += "release: $($r | Out-String)"
    if ($r) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'smoke-wt'; New-Item -ItemType Directory -Force $tmp | Out-Null
        $zip = Join-Path $tmp 'p.zip'
        Save-WtHttpFile $r.ZipUrl $zip $Script:UpdateMaxZipBytes
        $h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        $msgs += "downloaded $((Get-Item $zip).Length) bytes, hash=$h, digest=$($r.Digest), match=$($h -eq $r.Digest)"
        try { $files = [string[]](Expand-WtUpdateZip $zip (Join-Path $tmp 'x')); $msgs += "files: $($files -join ', ')" } catch { $msgs += "expand: $($_.Exception.Message)" }
        if ($r.ShaUrl) { $msgs += "sha text: $(Get-WtHttpText $r.ShaUrl 'text/plain' 4096)" }
    }
    $txt = Get-WtHttpText 'https://api.github.com/repos/nicoflbr/WinTidy/releases/latest' 'application/vnd.github+json'
    $msgs += "api ok, $($txt.Length) chars"
} catch { $msgs += "EXCEPTION: $($_.Exception.Message)"; $code = 1 }
Write-Host "::notice title=smoke $($PSVersionTable.PSVersion)::$(($msgs -join '%0A') -replace '\r?\n','%0A')"
exit [int]$code
