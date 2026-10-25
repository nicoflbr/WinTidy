# Test-Parse.ps1 - Syntaxpruefung aller PowerShell-Dateien des Projekts (auch mit pwsh unter Linux).
$root = Join-Path $PSScriptRoot '..'
$fail = 0
foreach ($f in Get-ChildItem $root -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch 'WinTidy-Daten' }) {
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
    if ($f.FullName -match '[\\/]archiv[\\/]') { if (-not $e.Count) { Write-Host "OK     $($f.Name) (Archiv)" -ForegroundColor Green }; continue }
    if ($e.Count) { $fail++; Write-Host "FEHLER $($f.FullName)" -ForegroundColor Red; $e | ForEach-Object { Write-Host "  Zeile $($_.Extent.StartLineNumber): $($_.Message)" }; continue }
    $probleme = @()
    # Windows PowerShell 5.1 liest Dateien ohne BOM als ANSI - Umlaute waeren kaputt
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { $probleme += 'kein UTF-8-BOM' }
    # Steuerzeichen (z. B. ein versehentliches BEL aus '\a') machen Pfade ungueltig
    $ctl = @(for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -lt 32 -and $bytes[$i] -notin 9, 10, 13) { $i } })
    if ($ctl.Count) { $probleme += "Steuerzeichen an Byte $($ctl[0])" }
    # PowerShell-7-Syntax, die 5.1 nicht kennt
    $bad = @($t | Where-Object { "$($_.Kind)" -in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr' -or ("$($_.Kind)" -eq 'QuestionMark') })
    foreach ($b in $bad) { $probleme += "PS7-Operator '$($b.Text)' in Zeile $($b.Extent.StartLineNumber)" }
    # Typografische Anfuehrungszeichen beenden Strings - nur in Here-Strings (XAML) und Kommentaren erlaubt
    foreach ($tk in $t) {
        if ("$($tk.Kind)" -in 'HereStringLiteral', 'HereStringExpandable', 'Comment') { continue }
        if ($tk.Text -match '[\u201C\u201D\u201E\u2018\u2019\u201A\u201B]') { $probleme += "typografisches Anfuehrungszeichen in Zeile $($tk.Extent.StartLineNumber)" }
    }
    if ($probleme.Count) { $fail++; Write-Host "FEHLER $($f.Name): $(@($probleme | Select-Object -First 5) -join '; ')" -ForegroundColor Red }
    else { Write-Host "OK     $($f.Name)" -ForegroundColor Green }
}
# Regel-Vertrag pruefen
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinTidy.ps1'), [ref]$null, [ref]$null)
$ids = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and ($n.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Id' }) -and ($n.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Detect' }) }, $true) |
    ForEach-Object { ($_.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Id' }).Item2.Extent.Text.Trim("'") }
$dup = $ids | Group-Object | Where-Object Count -gt 1
if ($dup) { $fail++; Write-Host "Doppelte Regel-IDs: $($dup.Name -join ', ')" -ForegroundColor Red } else { Write-Host "OK     $($ids.Count) Regeln, IDs eindeutig" -ForegroundColor Green }
exit $fail
