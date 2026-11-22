# Sanitized local usage readers. Missing or invalid values remain null.
function ConvertTo-BoardUsageDate($Value) {
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new($Value) }
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
function ConvertTo-BoardUsageFraction($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return $null }
    try {
        $Number = [double]$Value
        if ([double]::IsNaN($Number) -or [double]::IsInfinity($Number) -or $Number -lt 0 -or $Number -gt 1) { return $null }
        return [Math]::Round($Number * 100)
    } catch { return $null }
}
function ConvertTo-BoardUsageRemaining($Used, [double]$Scale = 100) {
    if ($null -eq $Used -or $Used -is [string] -or $Used -is [bool]) { return $null }
    try {
        $Number = [double]$Used
        if ([double]::IsNaN($Number) -or [double]::IsInfinity($Number) -or $Number -lt 0 -or $Number -gt $Scale) { return $null }
        return [Math]::Round(100 - ($Number / $Scale * 100))
    } catch { return $null }
}
function ConvertTo-BoardUsageReset($Seconds) {
    if ($null -eq $Seconds -or $Seconds -is [string] -or $Seconds -is [bool]) { return $null }
    try {
        if ([double]$Seconds -le 0) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$Seconds)
    } catch { return $null }
}
function Read-BoardUsageText([string]$Path, [int]$MaxBytes = 2097152) {
    if (-not $Path) { return $null }
    try {
        $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $Offset = [Math]::Max(0, $Stream.Length - $MaxBytes)
            [void]$Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
            $Reader = [IO.StreamReader]::new($Stream, [Text.Encoding]::UTF8)
            try {
                if ($Offset -gt 0) { [void]$Reader.ReadLine() }
                return $Reader.ReadToEnd()
            } finally { $Reader.Dispose() }
        } finally { $Stream.Dispose() }
    } catch { return $null }
}
function New-BoardUsageRow([string]$Agent) {
    [pscustomobject]@{ Agent = $Agent; SessionId = $null; Model = '?'; Effort = $null; FiveLeft = $null; FiveReset = $null; WeekLeft = $null; WeekReset = $null; CapturedAt = $null }
}
function Get-BoardCodexUsage([string]$SessionsPath, [string]$ModelSessionId) {
    $Row = New-BoardUsageRow 'codex'
    if (-not $SessionsPath -or -not (Test-Path -LiteralPath $SessionsPath)) { return $Row }
    # Cache directory discovery between short refreshes, and parsed unchanged tails.
    if (-not $script:BoardUsageCache -or $script:BoardUsageCache.Path -ne $SessionsPath -or
        ([DateTime]::UtcNow - $script:BoardUsageCache.Scanned).TotalSeconds -ge 30) {
        $Files = @(Get-ChildItem -LiteralPath $SessionsPath -Filter 'rollout*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 8 -ExpandProperty FullName)
        $script:BoardUsageCache = @{ Path = $SessionsPath; Scanned = [DateTime]::UtcNow; Files = $Files; Parsed = @{}; Sessions = @{} }
    }
    $Paths = @($script:BoardUsageCache.Files)
    if ($ModelSessionId -match '^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$') {
        if (-not $script:BoardUsageCache.Sessions.ContainsKey($ModelSessionId)) {
            $script:BoardUsageCache.Sessions[$ModelSessionId] = @(Get-ChildItem -LiteralPath $SessionsPath -Filter "rollout*$ModelSessionId*.jsonl" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
        $Paths = @(@($Paths) + @($script:BoardUsageCache.Sessions[$ModelSessionId]) | Select-Object -Unique)
    }
    $NewestRates = @{}
    $NewestContext = $null
    foreach ($Path in $Paths) {
        try { $File = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { continue }
        $Stamp = "$($File.LastWriteTimeUtc.Ticks):$($File.Length)"
        $Cached = $script:BoardUsageCache.Parsed[$Path]
        if (-not $Cached -or $Cached.Stamp -ne $Stamp) {
            $Rates = @{}
            $Context = $null
            foreach ($Line in ((Read-BoardUsageText $Path) -split '\r?\n')) {
                if ($Line -notmatch '"rate_limits"|"turn_context"') { continue }
                try {
                    $Event = $Line | ConvertFrom-Json -ErrorAction Stop
                    $At = ConvertTo-BoardUsageDate $Event.timestamp
                    if ($null -eq $At) { continue }
                    if ($Event.type -eq 'turn_context' -and $Event.payload.model) {
                        if ($null -eq $Context -or $At -ge $Context.At) {
                            $Context = @{ At = $At; Model = [string]$Event.payload.model; Effort = [string]$Event.payload.effort }
                        }
                    }
                    $Limits = $Event.payload.rate_limits
                    if ($Limits -and ($Limits.limit_id -eq 'codex' -or -not $Limits.limit_id)) {
                        foreach ($window in @($Limits.primary,$Limits.secondary)) {
                            $period=[int]$window.window_minutes
                            if ($period -notin 300,10080 -or $null -eq $window.used_percent) { continue }
                            if (!$Rates[$period] -or $At -ge $Rates[$period].At) { $Rates[$period]=@{At=$At;Window=$window} }
                        }
                    }
                } catch { continue }
            }
            $Cached = @{ Stamp = $Stamp; Rates = $Rates; Context = $Context }
            $script:BoardUsageCache.Parsed[$Path] = $Cached
        }
        foreach ($period in $Cached.Rates.Keys) {
            if (!$NewestRates[$period] -or $Cached.Rates[$period].At -gt $NewestRates[$period].At) {
                $NewestRates[$period]=$Cached.Rates[$period]
            }
        }
        $UseContext = $ModelSessionId -and [IO.Path]::GetFileName($Path).Contains($ModelSessionId)
        if ($UseContext -and $Cached.Context -and ($null -eq $NewestContext -or $Cached.Context.At -gt $NewestContext.At)) { $NewestContext = $Cached.Context }
    }
    if ($NewestContext) { $Row.Model = $NewestContext.Model; $Row.Effort = $NewestContext.Effort }
    if ($NewestRates[300]) {
        $Row.FiveLeft=ConvertTo-BoardUsageRemaining $NewestRates[300].Window.used_percent
        $Row.FiveReset=ConvertTo-BoardUsageReset $NewestRates[300].Window.resets_at
    }
    if ($NewestRates[10080]) {
        $Row.WeekLeft=ConvertTo-BoardUsageRemaining $NewestRates[10080].Window.used_percent
        $Row.WeekReset=ConvertTo-BoardUsageReset $NewestRates[10080].Window.resets_at
    }
    return $Row
}
function Get-BoardUsage($Config, $Sessions) {
    $Claude = New-BoardUsageRow 'claude'
    try {
        $Data = Read-BoardUsageText $Config.ClaudeUsageFile | ConvertFrom-Json -ErrorAction Stop
        $Claude.SessionId = $Data.session_id
        if ($Data.model.display_name) { $Claude.Model = [string]$Data.model.display_name; if($Data.effort -is [string]){ $Claude.Effort = $Data.effort } }
        $Claude.FiveLeft = ConvertTo-BoardUsageRemaining $Data.rate_limits.five_hour.used_percentage
        $Claude.FiveReset = ConvertTo-BoardUsageReset $Data.rate_limits.five_hour.resets_at
        $Claude.WeekLeft = ConvertTo-BoardUsageRemaining $Data.rate_limits.seven_day.used_percentage
        $Claude.WeekReset = ConvertTo-BoardUsageReset $Data.rate_limits.seven_day.resets_at
        $Claude.CapturedAt = ConvertTo-BoardUsageDate $Data.captured_at
    } catch {}
    $Agy = New-BoardUsageRow 'agy'
    try {
        $Data = Read-BoardUsageText $Config.AgyUsageFile | ConvertFrom-Json -ErrorAction Stop
        $Agy.SessionId = $Data.session_id
        if ($Data.model.display_name) { $Agy.Model = [string]$Data.model.display_name }
        $FiveKey = 'gemini-5h'
        $WeekKey = 'gemini-weekly'
        if ($Config.AgyFiveHourBucket) { $FiveKey = $Config.AgyFiveHourBucket }
        if ($Config.AgyWeeklyBucket) { $WeekKey = $Config.AgyWeeklyBucket }
        $Five = $Data.quota.$FiveKey
        $Week = $Data.quota.$WeekKey
        $Agy.FiveLeft = ConvertTo-BoardUsageFraction $Five.remaining_fraction
        $Agy.FiveReset = ConvertTo-BoardUsageDate $Five.reset_time
        $Agy.WeekLeft = ConvertTo-BoardUsageFraction $Week.remaining_fraction
        $Agy.WeekReset = ConvertTo-BoardUsageDate $Week.reset_time
        $Agy.CapturedAt = ConvertTo-BoardUsageDate $Data.captured_at
    } catch {}
    $counts=@{}
    foreach($session in $Sessions){ $counts[$session.Kind]++ }
    foreach($session in $Sessions){
        $usage=switch($session.Kind){
            'codex' { Get-BoardCodexUsage $Config.CodexSessionsPath $session.Conversation }
            'claude' {
                $row=$Claude | Select-Object *
                if($counts.claude -gt 1 -and (!$row.SessionId -or $row.SessionId -ne $session.Conversation)){ $row.Model='?' }
                $row
            }
            'agy' {
                $row=$Agy | Select-Object *
                if($counts.agy -gt 1 -and (!$row.SessionId -or $row.SessionId -ne $session.Conversation)){ $row.Model='?' }
                $row
            }
        }
        if(!$usage){ continue }
        $usage | Add-Member -NotePropertyName Id -NotePropertyValue $session.Id
        $usage
    }
}
