. "$PSScriptRoot/board-scope.ps1"

function Format-BoardElapsed([int]$Minutes,[switch]$Stale) {
    $esc=[char]27
    if($Stale){ return "$esc[33m멈춤?$esc[0m" }
    $elapsed=if($Minutes -lt 60){"$($Minutes)m"}else{"$([int][Math]::Floor($Minutes/60))h$($Minutes%60)m"}
    "$esc[36m$elapsed$esc[0m"
}

function Format-BoardModel([string]$Model,[string]$Effort) {
    $esc=[char]27
    $Model=($Model -replace '[\x00-\x1f\x7f-\x9f]',' ').Trim()
    $Effort=($Effort -replace '[\x00-\x1f\x7f-\x9f]',' ').Trim()
    if($Model -match '\s+\((low|medium|high|xhigh|max|ultra)\)$'){
        if(!$Effort){ $Effort=$Matches[1] }
        $Model=$Model.Substring(0,$Model.Length-$Matches[0].Length)
    }
    $Model=$Model -replace '^(Claude\s+|Gemini\s+\d+(?:\.\d+)?\s+)',''
    if(!$Model -or $Model -eq '?'){ return "$esc[90m—$esc[0m" }
    $detail="$esc[36m$Model$esc[0m"
    if($Effort){ $detail+=" $esc[90m· $($Effort.ToLowerInvariant())$esc[0m" }
    $detail
}

function Get-BoardCodexDefaults {
    $codexHome=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path ([Environment]::GetFolderPath("UserProfile")) '.codex'}
    $defaults=@{}
    foreach($line in ((Read-BoardUsageText (Join-Path $codexHome 'config.toml')) -split '\r?\n')){
        if($line -match '^\s*\['){ break }
        if($line -match '^\s*(model|model_reasoning_effort)\s*=\s*["'']([\w./:-]+)["'']\s*(?:#.*)?$'){
            $defaults[$Matches[1]]=$Matches[2]
        }
    }
    $defaults
}

function Get-BoardCardTitle([string]$LogRoot, [string]$Card, [string]$Fallback) {
    if (-not $Card) { return $Fallback }
    $path = Join-Path $LogRoot "card-$Card.md"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $first = Get-Content -LiteralPath $path -Encoding UTF8 -TotalCount 1 -ErrorAction SilentlyContinue
        if ($first) { return ($first -replace '^#\s*(?:카드(?:\s+[\w-]+)?\s*:\s*)?', '' -replace '\s*\(.*$', '').Trim() }
    }
    return $Card
}

function Get-BoardCardDevice([string]$LogRoot,[string]$Card,[string]$Arguments){
    $cardText=''
    if($Card -match '^[\w-]+$'){
        $path=Join-Path $LogRoot "card-$Card.md"
        $cardText=Read-BoardUsageText $path
        if($cardText -match '(?m)^기기[ \t]*:[ \t]*([^\r\n]+)'){ return [pscustomobject]@{Name=$Matches[1].Trim()} }
    }
    [pscustomobject]@{Hints=$Arguments}
}

function Get-BoardBacklogCard([string]$LogRoot,[string]$Id,[string]$Title){
    if($Title -match '(?i)\bcard-([\w-]+)\.md\b'){ return $Matches[1] }
    if(Test-Path -LiteralPath (Join-Path $LogRoot "card-$Id.md") -PathType Leaf){ return $Id }
    if($Title -match '(?i)\b([A-Z]+\d+)\b'){
        $matches=@(Get-ChildItem -LiteralPath $LogRoot -Filter "card-$($Matches[1])-*.md" -File -ErrorAction SilentlyContinue)
        if($matches.Count -eq 1){ return $matches[0].BaseName.Substring(5) }
    }
}

function Resolve-BoardDevice($Source,$Labels,$Machines){
    if(!$Source){ return }
    foreach($machine in $Machines.PSObject.Properties){
        $key=$machine.Name
        $hostName=[string]$machine.Value
        if(!$hostName){ continue }
        $label=if($Labels.$key){ $Labels.$key }else{ $key }
        if(($Source.Name -and $Source.Name -in @($key,$hostName,$label)) -or
           (!$Source.Name -and $Source.Hints -match "(?i)(?:\bssh\s+$([regex]::Escape($key))(?![\w-])|(?<![\w-])$([regex]::Escape($hostName))(?![\w-]))")){
            if($hostName -ne [Environment]::MachineName){ return $label }
            return
        }
    }
    if($Source.Name -and $Source.Name -ne [Environment]::MachineName){ return $Source.Name }
}

function Get-BoardWorkers([string]$LogRoot,[string]$ClaudeSessionsPath,$Scope) {
    if (!$Scope) { $Scope=New-BoardWorkerScope -LogRoot $LogRoot -Session 'work-herdr' -SharedLogRoot $LogRoot }
    $jobIndex=@(Get-BoardWorkerLogIndex $Scope)
    $owned=@($jobIndex | Where-Object Session -eq $Scope.Session)
    # A single process snapshot supplies counts, elapsed times and log correlation.
    $available=$true
    try { $processes = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CommandLine,CreationDate -ErrorAction Stop) }
    catch { $processes=@(); $available=$false }
    $byId = @{}
    foreach ($proc in $processes) { $byId[$proc.ProcessId] = $proc }

    $now = Get-Date
    $defaults = Get-BoardCodexDefaults
    $active = @(foreach ($proc in $processes) {
        $command = $proc.CommandLine
        if (-not $command -or $proc.Name -notmatch '^(codex|claude|agy)\.exe$') { continue }
        # Inspect whole argv tokens so options embedded in a quoted prompt cannot create a worker.
        $argv = @([regex]::Matches($command, '(?:[^\s"]|"(?:\\.|[^"\\])*")+') | ForEach-Object {$_.Value.Trim('"')})
        $flags = @(for($i=1; $i -lt $argv.Count -and $argv[$i] -ne '--'; $i++){ $argv[$i] })
        $owner = switch ($proc.Name) {
            'codex.exe'  { if ('exec' -in $flags) { 'codex' } }
            'claude.exe' { if ($flags -match '^(?:-p|--print|--bg-pty-host)(?:=|$)') { 'claude' } }
            'agy.exe'    { if ($flags -match '^(?:-p|--prompt|--headless|--background)(?:=|$)') { 'agy' } }
        }
        if (-not $owner) { continue }
        $parent = $byId[$proc.ParentProcessId]
        if ($owner -eq 'claude' -and $parent.Name -eq $proc.Name -and
            $parent.CreationDate -le $proc.CreationDate -and $parent.CommandLine -match '\s--bg-pty-host(?:\s|$)') { continue }

        $session=$null
        if ($owner -eq 'claude' -and $ClaudeSessionsPath) {
            $session=Read-BoardClaudeWorkerSession $ClaudeSessionsPath $proc.ProcessId
        }
        if ($owner -eq 'claude' -and $command -match '\s--bg-pty-host(?:\s|$)') {
            # A detached interactive session can retain a host process while idle.
            $child = $processes | Where-Object { $_.ParentProcessId -eq $proc.ProcessId -and $_.Name -eq $proc.Name } | Select-Object -First 1
            if ($child -and $ClaudeSessionsPath) {
                $childSession=Read-BoardClaudeWorkerSession $ClaudeSessionsPath $child.ProcessId
                if ($childSession) { $session=$childSession }
                if ($session.kind -eq 'bg' -and $session.status -in 'idle','done','shell') { continue }
            }
        }

        $card = ''
        $arguments = @()
        $ancestor = $proc
        for ($depth = 0; $ancestor -and $depth -lt 5; $depth++) {
            $arguments += $ancestor.CommandLine
            if (!$card -and $ancestor.CommandLine -match '(?:^|[/\\\s"''])(?:card-([\w-]+)\.md|exec-([\w-]+)\.(?:jsonl|log))(?=[\s"'';>]|$)') {
                $card = $Matches[1] + $Matches[2]
            }
            $parent = $byId[$ancestor.ParentProcessId]
            if ($parent -and $parent.CreationDate -gt $ancestor.CreationDate) { break }
            $ancestor = $parent
        }
        $launchRoom=Resolve-BoardRoom $Scope $session.herdr_session
        $cwd=if ($session.cwd) { $session.cwd } elseif ($proc.Cwd) { $proc.Cwd } else { Get-BoardLaunchCwd $flags }
        if (!$launchRoom) { $launchRoom=Find-BoardProjectSession $Scope.Rooms $cwd }
        $candidates=@($jobIndex | Where-Object Card -eq $card)
        $argumentText=$arguments -join "`n"
        $windowsArguments=$argumentText.Replace('/','\')
        $direct=@($candidates | Where-Object {
            $paths=@($_.Files.FullName)+@($_.CardPath)
            $paths | Where-Object {
                $_ -and $windowsArguments.IndexOf($_.Replace('/','\'),[StringComparison]::OrdinalIgnoreCase) -ge 0
            } | Select-Object -First 1
        })
        $candidateRooms=@($candidates.Session | Sort-Object -Unique)
        $tagged=$candidates | Where-Object Tag | Select-Object -First 1
        $room=if ($direct.Count -eq 1) { $direct[0].Session }
        elseif ($candidateRooms.Count -gt 1) { if ($launchRoom) { $launchRoom } else { '?' } }
        elseif ($tagged) { $tagged.Tag }
        elseif ($launchRoom) { $launchRoom }
        elseif ($candidateRooms.Count) { $candidateRooms[0] }
        else { $Scope.Work }
        if ($room -ne $Scope.Session) { continue }
        $job=if ($direct.Count -eq 1) { $direct[0] } else { $owned | Where-Object Card -eq $card | Select-Object -First 1 }
        $cardRoot=if ($job) { $job.Root } else { $null }

        $model = $null
        $effort = $null
        for ($index = 1; $index -lt $argv.Count; $index++) {
            $token = $argv[$index]
            if ($token -eq '--') { break }
            if ($token -match '^(?:--model|-m)=([\w./:-]+)$') { $model = $Matches[1] }
            if ($token -match '^--effort=([\w-]+)$') { $effort = $Matches[1] }
            $value = $null
            if ($index + 1 -lt $argv.Count) { $value = $argv[$index+1] }
            if ($token -in '--model','-m' -and $value -match '^[\w./:-]+$') { $model = $value }
            if ($token -eq '--effort' -and $value -match '^[\w-]+$') { $effort = $value }
            if ($owner -ne 'codex') { continue }
            $override = if ($token -in '-c','--config') { $value } elseif ($token -match '^--config=(.*)$') { $Matches[1] }
            if ($override -match '^(model|model_reasoning_effort)\s*=\s*[\\''"]*([\w./:-]+)[\\''"]*$') {
                if ($Matches[1] -eq 'model') { $model = $Matches[2] } else { $effort = $Matches[2] }
            }
        }
        if ($owner -eq 'codex') {
            if (!$model) { $model = $defaults.model }
            if (!$effort) { $effort = $defaults.model_reasoning_effort }
        }
        [pscustomobject]@{
            Agent=$owner
            Model=$model
            Effort=$effort
            Card=$card
            Title=$(if ($cardRoot) { Get-BoardCardTitle $cardRoot $card '백그라운드 작업' } elseif ($card) { $card } else { '백그라운드 작업' })
            Device=(Get-BoardCardDevice $cardRoot $(if ($cardRoot) { $card }) $argumentText)
            LogPath=$job.EventLog.FullName
            Root=$cardRoot
            Minutes=[Math]::Max(0, [Math]::Floor(($now - $proc.CreationDate).TotalMinutes))
        }
    })

    $activeCards = @($active | Where-Object Card | ForEach-Object Card)
    $reviewLogs = @($owned | ForEach-Object Files |
        Where-Object { $_.Extension -eq '.log' -or $_.Length -gt 0 } |
        Sort-Object LastWriteTime -Descending)
    $seen = @{}
    $pending = @(foreach ($log in $reviewLogs) {
        $card = $log.BaseName.Substring(5)
        $jobRoot=$log.DirectoryName
        if ($seen[$card] -or $card -in $activeCards -or
            (Test-Path -LiteralPath (Join-Path $jobRoot "exec-$card.reviewed"))) { continue }
        $seen[$card] = $true
        $stderrPath = if ($log.Extension -eq '.jsonl') { Join-Path $jobRoot "exec-$card.err" } else { "$($log.FullName).err" }
        $stderr = Get-Item -LiteralPath $stderrPath -ErrorAction SilentlyContinue
        $lastWrite = $log.LastWriteTime
        if ($stderr -and $stderr.LastWriteTime -gt $lastWrite) { $lastWrite = $stderr.LastWriteTime }
        # Some wrappers provide no card name. Defer a potential match while its process is alive.
        if ($active | Where-Object { $_.Agent -eq 'codex' -and -not $_.Card -and $now.AddMinutes(-($_.Minutes + 1)) -le $lastWrite }) { continue }
        [pscustomobject]@{ Title=(Get-BoardCardTitle $jobRoot $card $card) }
    })
    $localOwners=@{}
    foreach ($entry in ($jobIndex | Where-Object Root -eq $Scope.LogRoot)) { $localOwners[$entry.Card]=$entry.Session }
    [pscustomobject]@{ Active=$active; Pending=$pending; Jobs=$owned; LocalOwners=$localOwners; Available=$available }
}

function Test-BoardStale([string]$Root,[string]$Card,[DateTimeOffset]$Now){
    if(!$Card){ return $false }
    $log=Get-Item -LiteralPath (Join-Path $Root "exec-$Card.jsonl") -ErrorAction SilentlyContinue
    [bool]($log -and ($Now.UtcDateTime-$log.LastWriteTimeUtc).TotalMinutes -gt 10)
}
function Test-BoardReportedDone([string]$Root,[string]$Card,[string]$Title,[string]$OwnerKind,[string]$RoomKey,[int]$OwnerWorkingCount=1){
    if(!$Root){ return $false }
    $codes=[Collections.Generic.List[string]]::new()
    if($Card){ $codes.Add($Card) }
    if($Title -match '(?i)\b([A-Z]+\d+)\b'){
        $short=$Matches[1]
        if($short -notin $codes){ $codes.Add($short) }
    }
    $flagDirs=[Collections.Generic.List[string]]::new()
    $flagDirs.Add($Root)
    if($RoomKey -match '^space-(.+)$'){
        $spaceName=$Matches[1]
        $effText=Read-BoardUsageText (Join-Path $PSScriptRoot "spaces\$spaceName\effective-space.json")
        $projectPath=$null
        if($effText){ try{ $projectPath=(ConvertFrom-Json -InputObject $effText -ErrorAction Stop).ProjectPath }catch{} }
        if($projectPath){
            $flagDirs.Add($projectPath)
            $flagDirs.Add((Join-Path $projectPath 'work'))
        }else{
            $umbrella=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
            $guessed=Join-Path $umbrella $spaceName
            if(Test-Path -LiteralPath $guessed -PathType Container){
                $flagDirs.Add($guessed)
                $flagDirs.Add((Join-Path $guessed 'work'))
            }
        }
    }
    foreach($code in $codes){
        foreach($dir in $flagDirs){
            if(Test-Path -LiteralPath (Join-Path $dir "$code-done.flag") -PathType Leaf){ return $true }
            if(Test-Path -LiteralPath (Join-Path $dir "done-$code.flag") -PathType Leaf){ return $true }
        }
    }
    $backlogFile=Get-Item -LiteralPath (Join-Path $Root 'backlog.md') -ErrorAction SilentlyContinue
    $backlogUtc=if($backlogFile){ $backlogFile.LastWriteTimeUtc }else{ [DateTime]::MinValue }
    if($Card){
        $execLog=Get-Item -LiteralPath (Join-Path $Root "exec-$Card.jsonl") -ErrorAction SilentlyContinue
        if($execLog -and $execLog.LastWriteTimeUtc -ge $backlogUtc){
            $tail=Read-BoardUsageText $execLog.FullName 16384
            if($tail -and $tail -match '"type"\s*:\s*"turn\.completed"'){ return $true }
        }
    }
    if($OwnerKind){
        $relayFiles=@(Get-ChildItem -LiteralPath $Root -Filter "relay-$OwnerKind*.jsonl" -File -ErrorAction SilentlyContinue)
        foreach($rf in $relayFiles){
            if($rf.LastWriteTimeUtc -lt $backlogUtc){ continue }
            $raw=Read-BoardUsageText $rf.FullName 65536
            if(!$raw){ continue }
            $lines=$raw -split '\r?\n'
            for($i=$lines.Count-1; $i -ge 0; $i--){
                $line=$lines[$i]
                if(!$line -or $line -notmatch '"submitted-and-settled"'){ continue }
                try{ $entry=ConvertFrom-Json -InputObject $line -ErrorAction Stop }catch{ continue }
                if($entry.status -ne 'submitted-and-settled'){ continue }
                $at=ConvertTo-BoardUsageDate $entry.at
                if(!$at -or $at.UtcDateTime -lt $backlogUtc){ continue }
                $msg=[string]$entry.message
                $isFinal=($msg -match '(?i)done\.flag|최종\s*종료|루프\s*종료|감사\s*완료|작업\s*완료|완료\s*보고') -or
                         ($msg -match '완료' -and $msg -notmatch '(?:진행|예정)\s*[.!?]?\s*$')
                if(!$isFinal){ continue }
                if($OwnerWorkingCount -le 1){ return $true }
                foreach($code in $codes){
                    if($msg -match ("(?i)(?<![A-Za-z0-9_-])$([regex]::Escape($code))(?![A-Za-z0-9_-])")){ return $true }
                }
            }
        }
    }
    $false
}
function Write-BoardFrame($Lines){
    $esc=[char]27
    [Console]::Write("$esc[H"+($Lines -join ("$esc[K"+[Environment]::NewLine))+"$esc[K$esc[J")
}
