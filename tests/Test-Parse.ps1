# Test-Parse.ps1 - static checks of all PowerShell files of the project (also runs with pwsh on Linux):
# syntax, UTF-8 BOM, control characters, PowerShell 7-only operators, typographic quotes, unique rule IDs
# and completeness of the German translation (lang\de.psd1).
$root = Join-Path $PSScriptRoot '..'
$fail = 0
foreach ($f in Get-ChildItem $root -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch 'WinTidy-Daten' }) {
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
    if ($f.FullName -match '[\\/]archiv[\\/]') { if (-not $e.Count) { Write-Host "OK     $($f.Name) (archive)" -ForegroundColor Green }; continue }
    if ($e.Count) { $fail++; Write-Host "FAILED $($f.FullName)" -ForegroundColor Red; $e | ForEach-Object { Write-Host "  line $($_.Extent.StartLineNumber): $($_.Message)" }; continue }
    $problems = @()
    # Windows PowerShell 5.1 reads files without BOM as ANSI - umlauts would break
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { $problems += 'no UTF-8 BOM' }
    # Control characters (e.g. an accidental BEL from '\a') make paths invalid
    $ctl = @(for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -lt 32 -and $bytes[$i] -notin 9, 10, 13) { $i } })
    if ($ctl.Count) { $problems += "control character at byte $($ctl[0])" }
    # PowerShell 7 syntax that 5.1 does not know
    $bad = @($t | Where-Object { "$($_.Kind)" -in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr' -or ("$($_.Kind)" -eq 'QuestionMark') })
    foreach ($b in $bad) { $problems += "PS7 operator '$($b.Text)' in line $($b.Extent.StartLineNumber)" }
    # Typographic quotes end strings - only allowed in here-strings (XAML) and comments
    foreach ($tk in $t) {
        if ("$($tk.Kind)" -in 'HereStringLiteral', 'HereStringExpandable', 'Comment') { continue }
        if ($tk.Text -match '[\u201C\u201D\u201E\u2018\u2019\u201A\u201B]') { $problems += "typographic quote in line $($tk.Extent.StartLineNumber)" }
    }
    if ($problems.Count) { $fail++; Write-Host "FAILED $($f.Name): $(@($problems | Select-Object -First 5) -join '; ')" -ForegroundColor Red }
    else { Write-Host "OK     $($f.Name)" -ForegroundColor Green }
}

# Rule contract: unique IDs
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
$ids = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and ($n.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Id' }) -and ($n.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Detect' }) }, $true) |
    ForEach-Object { ($_.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Id' }).Item2.Extent.Text.Trim("'") }
$dup = $ids | Group-Object | Where-Object Count -gt 1
if ($dup) { $fail++; Write-Host "Duplicate rule IDs: $($dup.Name -join ', ')" -ForegroundColor Red } else { Write-Host "OK     $($ids.Count) rules, IDs unique" -ForegroundColor Green }

# Translation: every text used with T '...' (engine and app, including the XAML of the app) must be in lang\de.psd1
$keys = New-Object System.Collections.Generic.List[string]
foreach ($file in 'WinTidy.ps1', 'WinTidy-App.ps1') {
    $p = Join-Path $root $file
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $fa = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    foreach ($c in $fa.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'T', 'HT' }, $true)) {
        $a = $c.CommandElements[1]
        if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $keys.Add($a.Value) }
        elseif ($c.Extent.Text -ne 'T $Text @args') { $fail++; Write-Host "FAILED $file line $($c.Extent.StartLineNumber): T needs a literal text: $($c.Extent.Text)" -ForegroundColor Red }
    }
    # Texts in the XAML of the app: translated at runtime by Convert-XamlLanguage
    foreach ($h in $fa.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^\s*<Window[\s>]' }, $true)) {
        $x = [xml]$h.Value
        foreach ($node in $x.SelectNodes('//*')) {
            foreach ($at in $node.Attributes) { if ($at.LocalName -in 'Text', 'Content', 'ToolTip', 'Header', 'Title' -or $at.Name -eq 'AutomationProperties.Name') { if ($at.Value -match '[A-Za-z]' -and $at.Value -notmatch '^\{') { $keys.Add($at.Value) } } }
            foreach ($tn in $node.ChildNodes) { if ($tn.NodeType -eq 'Text' -and $tn.Value.Trim() -match '[A-Za-z]') { $keys.Add(($tn.Value -replace '\s+', ' ').Trim()) } }
        }
    }
}
$langFile = Join-Path $root 'lang/de.psd1'
$la = [System.Management.Automation.Language.Parser]::ParseFile($langFile, [ref]$null, [ref]$e)
if ($e.Count) { $fail++; Write-Host "FAILED lang/de.psd1: $($e[0].Message)" -ForegroundColor Red }
$de = @{}; $deCase = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
$tbl = $la.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
foreach ($kv in $tbl.KeyValuePairs) {
    $v = $kv.Item2; if ($v -is [System.Management.Automation.Language.PipelineAst]) { $v = $v.PipelineElements[0].Expression }
    if (-not ($kv.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $v -is [System.Management.Automation.Language.StringConstantExpressionAst])) { $fail++; Write-Host "FAILED lang/de.psd1 line $($kv.Item1.Extent.StartLineNumber): only plain 'key' = 'value' strings allowed" -ForegroundColor Red; continue }
    if ($deCase.ContainsKey($kv.Item1.Value)) { $fail++; Write-Host "FAILED lang/de.psd1: duplicate key '$($kv.Item1.Value)'" -ForegroundColor Red }
    $deCase[$kv.Item1.Value] = $v.Value
}
$used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($k in $keys) { [void]$used.Add($k) }
$missing = @($used | Where-Object { -not $deCase.ContainsKey($_) })
$unused = @($deCase.Keys | Where-Object { -not $used.Contains($_) })
$ph = @($deCase.Keys | Where-Object { $a = @([regex]::Matches($_, '\{\d+') | ForEach-Object Value | Sort-Object -Unique) -join ','; $b = @([regex]::Matches($deCase[$_], '\{\d+') | ForEach-Object Value | Sort-Object -Unique) -join ','; $a -ne $b })
if ($missing.Count) { $fail++; Write-Host "FAILED German translation missing for $($missing.Count) text(s):" -ForegroundColor Red; $missing | Select-Object -First 20 | ForEach-Object { Write-Host "  '$_'" } }
if ($unused.Count) { $fail++; Write-Host "FAILED lang/de.psd1 has $($unused.Count) unused entr(y/ies):" -ForegroundColor Red; $unused | Select-Object -First 20 | ForEach-Object { Write-Host "  '$_'" } }
if ($ph.Count) { $fail++; Write-Host "FAILED placeholders {0}.. differ between English and German:" -ForegroundColor Red; $ph | Select-Object -First 20 | ForEach-Object { Write-Host "  '$_'" } }
if (-not ($missing.Count + $unused.Count + $ph.Count)) { Write-Host "OK     German translation complete ($($deCase.Keys.Count) texts)" -ForegroundColor Green }

# Programs are started by full path: cmd.exe and ShellExecute also search the current folder (planted powershell.exe etc.)
foreach ($c in 'WinTidy.cmd', 'WinTidy App.cmd') {
    $txt = [IO.File]::ReadAllText((Join-Path $root $c))
    $alle = [regex]::Matches($txt, '(?i)powershell\.exe').Count
    $voll = [regex]::Matches($txt, '(?i)(v1\.0\\|\$PSHOME '')powershell\.exe').Count
    if (-not $alle -or $alle -ne $voll) { $fail++; Write-Host "FAILED $c starts powershell.exe without a full path" -ForegroundColor Red } else { Write-Host "OK     $c starts PowerShell by full path" -ForegroundColor Green }
}
$appTxt = [IO.File]::ReadAllText((Join-Path $root 'WinTidy-App.ps1'))
$bare = @([regex]::Matches($appTxt, '(?i)Start-Process\s+(-FilePath\s+)?(powershell|explorer|notepad|shutdown)\.exe') | ForEach-Object Value)
if ($bare.Count) { $fail++; Write-Host "FAILED WinTidy-App.ps1 starts programs by bare name: $($bare -join '; ')" -ForegroundColor Red } else { Write-Host 'OK     WinTidy-App.ps1 starts programs by full path' -ForegroundColor Green }
exit $fail
