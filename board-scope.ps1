# Worker ownership is shared by the dashboard and background view.
function Get-BoardSocketSession([string]$Socket) {
    if (!$Socket) { return }
    if ($Socket -match '[/\\]sessions[/\\]([^/\\]+)[/\\][^/\\]+$') { $Matches[1] }
}

function ConvertTo-BoardPath([string]$Path) {
    if (!$Path -or ![IO.Path]::IsPathRooted($Path)) { return }
    try { [IO.Path]::GetFullPath($Path).Replace('/','\').TrimEnd([char[]]@('/','\')) } catch {}
}

function New-BoardWorkerScope([string]$LogRoot,[string]$Session,[string]$SharedLogRoot,[string]$ProjectPath,[string]$CodexSessionsPath) {
    $work='work-herdr'
    $sessionFromPane=if ($env:HERDR_SESSION) { $env:HERDR_SESSION } else { Get-BoardSocketSession $env:HERDR_SOCKET_PATH }
    if (!$SharedLogRoot) { $SharedLogRoot=Join-Path $PSScriptRoot 'logs' }
    $shared=ConvertTo-BoardPath $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SharedLogRoot)
    $rooms=@{}
    $roots=@{}
    $spacesRoot=Join-Path $PSScriptRoot 'spaces'
    foreach ($folder in (Get-ChildItem -LiteralPath $spacesRoot -Directory -ErrorAction SilentlyContinue)) {
        $state=Read-BoardUsageText (Join-Path $folder.FullName 'effective-space.json')
        if (!$state) { continue }
        try { $project=ConvertFrom-Json -InputObject $state -ErrorAction Stop } catch { continue }
        if ($project.Name -ne $folder.Name) { continue }
        $label=$project.Label
        if (!$label) {
            $defText=Read-BoardUsageText (Join-Path $spacesRoot "$($folder.Name).json")
            if ($defText) { try { $label=(ConvertFrom-Json -InputObject $defText -ErrorAction Stop).Label } catch {} }
        }
        $name='space-'+$folder.Name
        $rooms[$name]=[pscustomobject]@{ Name=$folder.Name; Label=$label; Project=$project.CatalogProject; Path=(ConvertTo-BoardPath $project.ProjectPath) }
        $roots[(Join-Path $folder.FullName 'logs')]=$name
    }
    if (!$Session) { $Session=$sessionFromPane }
    if (!$Session) {
        $inferred=Find-BoardProjectSession $rooms (Get-Location).ProviderPath
        $Session=if ($inferred -and $inferred -ne '?') { $inferred } else { $work }
    }
    $projectRoot=ConvertTo-BoardPath $ProjectPath
    if ($projectRoot -and $Session -ne $work) {
        if ($rooms.ContainsKey($Session)) { $rooms[$Session].Path=$projectRoot }
        else { $rooms[$Session]=[pscustomobject]@{ Name=$Session; Project=$null; Path=$projectRoot } }
    }
    if (!$LogRoot) {
        $LogRoot=$roots.Keys | Where-Object { $roots[$_] -eq $Session } | Select-Object -First 1
        if (!$LogRoot) { $LogRoot=$shared }
    }
    $local=ConvertTo-BoardPath $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogRoot)
    if ($local -ne $shared -and !$roots.ContainsKey($local)) { $roots[$local]=$Session }
    if (!$CodexSessionsPath) {
        $codexHome=if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
        $CodexSessionsPath=Join-Path $codexHome 'sessions'
    }
    [pscustomobject]@{
        Session=$Session; Work=$work; LogRoot=$local; SharedLogRoot=$shared; Rooms=$rooms; Roots=$roots
        CodexSessionsPath=$CodexSessionsPath; Rollouts=@{}; RolloutsScanned=[DateTime]::MinValue; FileCache=@{}
    }
}

function Find-BoardProjectSession($Rooms,[string]$Cwd) {
    $path=ConvertTo-BoardPath $Cwd
    if (!$path) { return }
    $umbrella=ConvertTo-BoardPath (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    $matches=@(foreach ($room in $Rooms.GetEnumerator()) {
        $root=$room.Value.Path
        # The workspace umbrella is also used by Work and rooms with no project checkout.
        if (!$root -or $root -eq $umbrella) { continue }
        if ($path -eq $root -or $path.StartsWith("$root\",[StringComparison]::OrdinalIgnoreCase)) {
            [pscustomobject]@{ Session=$room.Key; Length=$root.Length }
        }
    })
    if (!$matches.Count) { return }
    $best=($matches | Measure-Object -Property Length -Maximum).Maximum
    $owners=@($matches | Where-Object Length -eq $best)
    if ($owners.Count -eq 1) { return $owners[0].Session }
    # A shared project directory cannot identify either room.
    return '?'
}

function Resolve-BoardRoom($Scope,[string]$Name) {
    if (!$Name) { return }
    $Name=$Name.Trim()
    if ($Name -in 'Work','Work 작업실',$Scope.Work) { return $Scope.Work }
    if ($Name -eq $Scope.Session -or $Scope.Rooms.ContainsKey($Name)) { return $Name }
    $owners=@(foreach ($room in $Scope.Rooms.GetEnumerator()) {
        if ($Name -in $room.Value.Name,$room.Value.Project,$room.Value.Label) { $room.Key }
    })
    if ($owners.Count -eq 1) { return $owners[0] }
    if ($owners.Count -gt 1) { return '?' }
    if ($Name -match '^space-') { return $Name }
    # Tags can also use the space name without its Herdr prefix.
    return "space-$Name"
}

function Get-BoardCardRoom($Scope,[string]$Root,[string]$Card) {
    if ($Card -notmatch '^[\w-]+$') { return }
    $cardText=Read-BoardUsageText (Join-Path $Root "card-$Card.md")
    if ($cardText -match '(?m)^[ \t]*작업실[ \t]*:[ \t]*([^ \t\r\n][^\r\n]*)') {
        Resolve-BoardRoom $Scope $Matches[1]
    }
}

function Read-BoardWorkerLaunch([string]$Path) {
    # Scope metadata, when provided, belongs at the start of a worker stream.
    try { $stream=[IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) }
    catch { return }
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
    try {
        $thread=$null
        for ($i=0; $i -lt 16; $i++) {
            $line=$reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -notmatch '"(?:cwd|working_directory|herdr_session|space|thread_id)"\s*:') { continue }
            try { $record=ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
            if ($record.type -notin $null,'thread.started','session_meta','worker.started') { continue }
            if ($record.type -eq 'thread.started' -and $record.thread_id -match '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$') {
                $thread=$record.thread_id
            }
            $meta=if ($record.payload) { $record.payload } else { $record }
            $session=if ($meta.herdr_session) { $meta.herdr_session } else { $meta.space }
            $cwd=if ($meta.cwd) { $meta.cwd } else { $meta.working_directory }
            if ($session -or $cwd) { return [pscustomobject]@{ Session=$session; Cwd=$cwd; Thread=$thread } }
        }
        if ($thread) { [pscustomobject]@{ Thread=$thread } }
    } finally { $reader.Dispose() }
}

function Get-BoardRolloutRoom($Scope,[string]$Thread,[IO.FileInfo]$EventLog) {
    if (!$Thread -or !$Scope.Rooms.Count) { return }
    if (!$Scope.Rollouts.ContainsKey($Thread)) {
        # Check normal session directories even when the general index is fresh.
        $days=@($EventLog.CreationTime.Date,$EventLog.LastWriteTime.Date)
        foreach ($day in ($days | Select-Object -Unique)) {
            foreach ($offset in 0,-1,1) {
                $folder=Join-Path $Scope.CodexSessionsPath ($day.AddDays($offset).ToString('yyyy/MM/dd',[Globalization.CultureInfo]::InvariantCulture))
                $found=Get-ChildItem -LiteralPath $folder -Filter "rollout-*-$Thread.jsonl" -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) {
                    $Scope.Rollouts[$Thread]=@{Path=$found.FullName;Room=$null}
                    break
                }
            }
            if ($found) { break }
        }
    }
    if (!$Scope.Rollouts.ContainsKey($Thread) -and
        ($EventLog.CreationTimeUtc -ge $Scope.RolloutsScanned -or ([DateTime]::UtcNow-$Scope.RolloutsScanned).TotalSeconds -ge 30)) {
        $Scope.RolloutsScanned=[DateTime]::UtcNow
        foreach ($file in (Get-ChildItem -LiteralPath $Scope.CodexSessionsPath -Filter 'rollout-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.BaseName -match '([a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12})$') {
                $id=$Matches[1]
                if (!$Scope.Rollouts.ContainsKey($id)) { $Scope.Rollouts[$id]=@{Path=$file.FullName;Room=$null} }
            }
        }
    }
    $rollout=$Scope.Rollouts[$Thread]
    if (!$rollout) { return }
    if (!$rollout.Room) {
        $launch=Read-BoardWorkerLaunch $rollout.Path
        $rollout.Room=Resolve-BoardRoom $Scope $launch.Session
        if (!$rollout.Room) { $rollout.Room=Find-BoardProjectSession $Scope.Rooms $launch.Cwd }
        if ($launch.Cwd -and !$rollout.Room) { $rollout.Room=$Scope.Work }
    }
    $rollout.Room
}

function Get-BoardWorkerLogIndex($Scope) {
    $roots=@($Scope.LogRoot,$Scope.SharedLogRoot)+@($Scope.Roots.Keys)
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (!$root) { continue }
        $files=@(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object {
            ($_.Extension -in '.log','.jsonl' -and $_.BaseName -match '^exec-[\w-]+$') -or
            ($_.Extension -eq '.md' -and $_.BaseName -match '^card-[\w-]+$')
        })
        foreach ($group in ($files | Group-Object { $_.BaseName.Substring(5) })) {
            $card=$group.Name
            $logs=@($group.Group | Where-Object Extension -in '.log','.jsonl')
            $cardFile=$group.Group | Where-Object Extension -eq '.md' | Select-Object -First 1
            $cardPath=if ($cardFile) { $cardFile.FullName }
            $eventLog=$logs | Where-Object Extension -eq '.jsonl' | Select-Object -First 1
            $tag=$null
            if ($cardFile) {
                $cardKey="card|$($cardFile.FullName)|$($cardFile.LastWriteTimeUtc.Ticks)|$($cardFile.Length)"
                if ($Scope.FileCache -and $Scope.FileCache.ContainsKey($cardKey)) { $tag=$Scope.FileCache[$cardKey] }
                else {
                    $tag=Get-BoardCardRoom $Scope $root $card
                    if ($Scope.FileCache) { $Scope.FileCache[$cardKey]=$tag }
                }
            }
            $room=$tag
            if (!$room -and $eventLog) {
                $logKey="log|$($eventLog.FullName)|$($eventLog.LastWriteTimeUtc.Ticks)|$($eventLog.Length)"
                if ($Scope.FileCache -and $Scope.FileCache.ContainsKey($logKey)) { $launch=$Scope.FileCache[$logKey] }
                else {
                    $launch=Read-BoardWorkerLaunch $eventLog.FullName
                    if ($Scope.FileCache) { $Scope.FileCache[$logKey]=$launch }
                }
                $room=Resolve-BoardRoom $Scope $launch.Session
                if (!$room) { $room=Find-BoardProjectSession $Scope.Rooms $launch.Cwd }
                # Prefer the local room context for its own logs. Shared Codex logs
                # can carry only a thread ID, with the cwd in its session rollout.
                if (!$room -and !$Scope.Roots[$root]) { $room=Get-BoardRolloutRoom $Scope $launch.Thread $eventLog }
            }
            if (!$room) { $room=$Scope.Roots[$root] }
            if (!$room) { $room=$Scope.Work }
            [pscustomobject]@{
                Card=$card; Root=$root; Session=$room; Tag=$tag; CardPath=$cardPath; EventLog=$eventLog; Files=$logs
            }
        }
    }
}

function Get-BoardLaunchCwd([string[]]$Flags) {
    for ($i=0; $i -lt $Flags.Count; $i++) {
        $option=$Flags[$i]
        if ($option -cmatch '^(?:-C|--cd|--cwd)=(.+)$') { return $Matches[1] }
        if ($option -cin '-C','--cd','--cwd' -and ($i+1) -lt $Flags.Count) { return $Flags[$i+1] }
        if ($option -notmatch '^-' -and $option -ne 'exec') { break }
        if ($option -in '-m','--model','-c','--config','--effort','-p','--profile','-s','--sandbox','-a','--ask-for-approval','--add-dir','--output-schema','-o','--output-last-message','--enable','--disable') { $i++ }
    }
}


function Read-BoardClaudeWorkerSession([string]$Root,[int]$ProcessId) {
    $text=Read-BoardUsageText (Join-Path $Root "$ProcessId.json")
    if (!$text) { return }
    try { ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch {}
}
