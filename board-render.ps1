function Clean-BoardText([string]$Value){
    ($Value -replace '[\x00-\x1f\x7f-\x9f]',' ').Trim()
}
function Get-BoardCellWidth([string]$Element){
    if($Element.Contains([char]0x200D)){
        $width=0
        foreach($component in ($Element -split '\u200d')){ $width+=Get-BoardCellWidth $component }
        return $width
    }
    if(!$Element){ return 0 }
    if($Element -match '[\uFE0F\u20E3]'){ return 2 }
    $code=[char]::ConvertToUtf32($Element,0)
    if($code -in 0x200C,0x200D,0xFE0E,0xFE0F){ return 0 }
    if(([Globalization.CharUnicodeInfo]::GetUnicodeCategory($Element,0)) -in 'NonSpacingMark','EnclosingMark'){ return 0 }
    if(($code -ge 0x1100 -and $code -le 0x115F) -or ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
       ($code -ge 0xAC00 -and $code -le 0xD7A3) -or ($code -ge 0xF900 -and $code -le 0xFAFF) -or
       ($code -ge 0xFE10 -and $code -le 0xFE6F) -or ($code -ge 0xFF00 -and $code -le 0xFF60) -or
       ($code -ge 0xFFE0 -and $code -le 0xFFE6) -or ($code -ge 0x1F1E6 -and $code -le 0x1FAFF) -or
       ($code -ge 0x20000 -and $code -le 0x3FFFD) -or $code -in
       0x231A,0x231B,0x23E9,0x23EA,0x23EB,0x23EC,0x23F0,0x23F3,0x25FD,0x25FE,
       0x2614,0x2615,0x2648,0x2649,0x264A,0x264B,0x264C,0x264D,0x264E,0x264F,0x2650,0x2651,0x2652,0x2653,
       0x267F,0x2693,0x26A1,0x26AA,0x26AB,0x26BD,0x26BE,0x26C4,0x26C5,0x26CE,0x26D4,0x26EA,
       0x26F2,0x26F3,0x26F5,0x26FA,0x26FD,0x2705,0x270A,0x270B,0x2728,0x274C,0x274E,0x2753,0x2754,0x2755,
       0x2757,0x2795,0x2796,0x2797,0x27B0,0x27BF,0x2B1B,0x2B1C,0x2B50,0x2B55){ return 2 }
    1
}
function Get-BoardDisplayElements([string]$Line){
    # Match UTF-16 pairs and presentation marks together on both .NET Framework and .NET.
    $base='(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\p{M}\u200D\uD800-\uDFFF])(?:\uD83C[\uDFFB-\uDFFF])?\p{M}*'
    [regex]::Matches($Line,"\x1b\[[0-9;]*m|(?:\uD83C[\uDDE6-\uDDFF]){2}|$base(?:\u200D$base)*|\p{M}|[\s\S]")
}
function Fit-BoardLine([string]$Line,[int]$Limit){
    $esc=[char]27
    $reset="$esc[0m"
    $output=[Text.StringBuilder]::new()
    $used=0
    $lastCellStart=0
    foreach($element in (Get-BoardDisplayElements $Line)){
        $part=$element.Value
        if($part[0] -eq $esc){ [void]$output.Append($part); continue }
        $cells=Get-BoardCellWidth $part
        if($used+$cells -gt $Limit){
            if($used -eq $Limit){ $output.Length=$lastCellStart }
            [void]$output.Append("…$reset")
            break
        }
        if($cells){ $lastCellStart=$output.Length }
        [void]$output.Append($part)
        $used+=$cells
    }
    $output.ToString()
}
function Get-BoardTextWidth([string]$Value){
    $width=0
    foreach($element in (Get-BoardDisplayElements $Value)){
        if($element.Value[0] -ne [char]27){ $width+=Get-BoardCellWidth $element.Value }
    }
    $width
}
