@echo off
setlocal
set "SRT_SELF=%~f0"
set "SRT_INPUT=%~1"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:SRT_SELF); & ([scriptblock]::Create($s.Substring($s.LastIndexOf('# POWERSHELL_PAYLOAD')+21)))"
set "SRT_RESULT=%errorlevel%"
if not defined SRT_NO_PAUSE pause
exit /b %SRT_RESULT%
# POWERSHELL_PAYLOAD
$ErrorActionPreference = 'Stop'
# Combine exchanges; hold up to 6 seconds past original end, capped before next card.



function ToMs($v) {
    $a = $v -split '[:,]'
    return ([long]$a[0]*3600000 + [long]$a[1]*60000 + [long]$a[2]*1000 + [long]$a[3])
}
function Stamp([long]$v) {
    return ('{0:00}:{1:00}:{2:00},{3:000}' -f [long][Math]::Floor($v/3600000), [long][Math]::Floor(($v%3600000)/60000), [long][Math]::Floor(($v%60000)/1000), ($v%1000))
}
function ProcessSrt([string]$path) {
    $path = [IO.Path]::GetFullPath($path)
    if ([IO.Path]::GetExtension($path) -ine '.srt') { throw 'Select an SRT file.' }
    $bytes = [IO.File]::ReadAllBytes($path)
    # Latin-1 is a reversible byte container, NOT an encoding guess.
    # It leaves all text bytes untouched for CP1255, UTF-8 and other ASCII-compatible files.
    $enc = [Text.Encoding]::GetEncoding(28591)
    if ($bytes.Length -ge 4 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) -or ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255))) { throw 'UTF-32 is not supported.' }
    if ($bytes.Length -ge 2) {
        if ($bytes[0] -eq 255 -and $bytes[1] -eq 254) { $enc = [Text.UnicodeEncoding]::new($false,$false,$true) }
        elseif ($bytes[0] -eq 254 -and $bytes[1] -eq 255) { $enc = [Text.UnicodeEncoding]::new($true,$false,$true) }
    }
    $text = $enc.GetString($bytes)
    $pattern = '(?m)^(?<start>\d{2,}:\d{2}:\d{2},\d{3})(?<arrow>[ \t]+-->[ \t]+)(?<end>\d{2,}:\d{2}:\d{2},\d{3})(?<tail>[^\r\n]*)'
    $rx = [regex]::new($pattern)
    $cues = $rx.Matches($text)
    if ($cues.Count -eq 0) { throw 'No SRT timestamps found. File left unchanged.' }
    $starts = @(); $ends = @()
    foreach ($cue in $cues) {
        foreach ($name in @('start','end')) {
            if ($cue.Groups[$name].Value -notmatch '^\d{2,}:[0-5]\d:[0-5]\d,\d{3}$') { throw 'Invalid timestamp.' }
        }
        $starts += (ToMs $cue.Groups['start'].Value)
        $ends += (ToMs $cue.Groups['end'].Value)
    }
    # Parse complete blocks so no dialogue can be silently lost when grouping.
    $bom = ''
    $body = $text
    if ($body.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)) { $bom=$body.Substring(0,1); $body=$body.Substring(1) }
    elseif ($body.StartsWith(([string][char]239+[char]187+[char]191),[StringComparison]::Ordinal)) { $bom=$body.Substring(0,3); $body=$body.Substring(3) }
    $nl = "`r`n"
    if (-not $body.Contains($nl)) { $nl="`n" }
    $blocks = [regex]::Split($body.TrimEnd([char[]]"`r`n"),'\r?\n[ \t]*\r?\n')
    $items = @()
    foreach ($block in $blocks) {
        $match = [regex]::Match($block,'\A\d+\r?\n(?<start>\d{2,}:\d{2}:\d{2},\d{3})[ \t]+-->[ \t]+(?<end>\d{2,}:\d{2}:\d{2},\d{3})(?<tail>[^\r\n]*)\r?\n(?<body>[\s\S]+)\z')
        if (-not $match.Success) { throw 'Unsupported SRT block; original left unchanged.' }
        $items += [pscustomobject]@{Start=(ToMs $match.Groups['start'].Value); End=(ToMs $match.Groups['end'].Value); Body=$match.Groups['body'].Value; Tail=$match.Groups['tail'].Value}
    }
    if ($items.Count -ne $cues.Count) { throw 'Block count mismatch.' }
    for ($i=0;$i -lt $items.Count;$i++) {
        if ($items[$i].End -le $items[$i].Start) { throw 'Non-positive duration.' }
        if ($i -gt 0 -and $items[$i].Start -le $items[$i-1].Start) { throw 'Unordered subtitle starts.' }
    }
    $groups = @()
    for ($i=0;$i -lt $items.Count;$i++) {
        $first=$i; $dialogue=$items[$i].Body; $lines=([regex]::Split($dialogue,'\r?\n')).Count
        # Merge rapid exchanges, at most three cues and four text lines per card.
        while ($i+1 -lt $items.Count -and $i-$first -lt 2) {
            $available=$items[$i+1].Start-$items[$first].Start
            $next=$items[$i+1]
            $nextLines=([regex]::Split($next.Body,'\r?\n')).Count
            if ($available -ge 3500 -or $next.Start-$items[$i].End -gt 500 -or $lines+$nextLines -gt 4 -or $next.End-$items[$first].Start -gt 6000 -or $items[$i].Tail -ne $next.Tail) { break }
            $dialogue += $nl+$next.Body
            $lines += $nextLines
            $i++
        }
        $groups += [pscustomobject]@{Start=$items[$first].Start; End=$items[$i].End; Body=$dialogue; Tail=$items[$first].Tail}
    }
    $builder=[Text.StringBuilder]::new()
    [void]$builder.Append($bom)
    for ($i=0;$i -lt $groups.Count;$i++) {
        $g=$groups[$i]
        $end=$g.End+5200
        if ($i+1 -lt $groups.Count) { $end=[Math]::Min($g.End+5200,$groups[$i+1].Start-1) }
        if ($end -le $g.Start) { throw 'Invalid grouped duration.' }
        [void]$builder.Append(($i+1).ToString()+$nl+(Stamp ($g.Start+800))+' --> '+(Stamp ($end+800))+$g.Tail+$nl+$g.Body+$nl+$nl)
    }
    $result=$builder.ToString()
    # All original dialogue lines must appear exactly once and in the same order.
    $before=($items | ForEach-Object {$_.Body}) -join $nl
    $after=($groups | ForEach-Object {$_.Body}) -join $nl
    if ($before -cne $after) { throw 'Dialogue preservation verification failed.' }
    $outBytes=$enc.GetBytes($result)
    if ($enc.GetString($outBytes) -cne $result) { throw 'Encoding verification failed.' }
    $check=$rx.Matches($result)
    if ($check.Count -ne $groups.Count) { throw 'Output cue count mismatch.' }
    for ($i=0;$i -lt $check.Count;$i++) {
        $end=ToMs $check[$i].Groups['end'].Value
        if ($end -le (ToMs $check[$i].Groups['start'].Value)) { throw 'Invalid duration.' }
        if ($i+1 -lt $check.Count -and $end -ge (ToMs $check[$i+1].Groups['start'].Value)) { throw 'Overlap.' }
    }
    $stem = [IO.Path]::Combine([IO.Path]::GetDirectoryName($path),[IO.Path]::GetFileNameWithoutExtension($path)+'_hold6sec')
    $output = $stem+'.srt'; $n=2
    while ([IO.File]::Exists($output)) { $output=$stem+'_'+$n+'.srt'; $n++ }
    $stream = [IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    try { $stream.Write($outBytes,0,$outBytes.Length) } finally { $stream.Dispose() }
    $saved = [IO.File]::ReadAllBytes($output)
    if ([Convert]::ToBase64String($saved) -cne [Convert]::ToBase64String($outBytes)) { throw 'Saved file verification failed.' }
    Write-Host ('Saved: '+$output)
    Write-Host ('Verified: {0} original cues grouped into {1} cards; all dialogue preserved; no overlaps.' -f $items.Count,$groups.Count)
}
try {
    if ($env:SRT_INPUT) { $files = @($env:SRT_INPUT) }
    else {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select ORIGINAL SRT - dialogue with up to 6 seconds after original end'
        $dialog.Filter = 'SubRip subtitles (*.srt)|*.srt'
        $dialog.Multiselect = $true
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { exit 0 }
        $files = $dialog.FileNames
        $dialog.Dispose()
    }
    $failed = $false
    foreach ($file in $files) {
        try { ProcessSrt $file }
        catch { Write-Host ('ERROR: '+$file+': '+$_.Exception.Message) -ForegroundColor Red; $failed=$true }
    }
    if ($failed) { exit 1 }
    exit 0
} catch { Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
