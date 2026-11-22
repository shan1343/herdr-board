param(
    [ValidateRange(1,3600)][int]$Refresh=30,
    [string]$ConfigPath=(Join-Path $PSScriptRoot 'board.config.json'),
    [ValidateRange(1,1000)][int]$Width,
    [ValidateRange(1,1000)][int]$Height,
    [switch]$Demo,
    [switch]$Once
)

$Version='v2.8'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. "$PSScriptRoot\board-demo.ps1"
. "$PSScriptRoot\board-render.ps1"
. "$PSScriptRoot\board-workers.ps1"
. "$PSScriptRoot\board-usage.ps1"

$configFile=Get-Item -LiteralPath $ConfigPath -ErrorAction Stop
$config=Get-Content -LiteralPath $configFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if(!$config.LogRoot){ $config | Add-Member -NotePropertyName LogRoot -NotePropertyValue 'logs' -Force }
foreach($key in 'LogRoot','ClaudeUsageFile','ClaudeSessionsPath','AgyUsageFile','CodexSessionsPath','HerdrSocketPath'){
    if(!$config.$key){ continue }
    $path=[Environment]::ExpandEnvironmentVariables([string]$config.$key)
    if(![IO.Path]::IsPathRooted($path)){ $path=Join-Path $configFile.DirectoryName $path }
    $config.$key=$path
}
if(!$Demo -and !$env:HERDR_SOCKET_PATH -and $config.HerdrSocketPath){ $env:HERDR_SOCKET_PATH=$config.HerdrSocketPath }
$herdrArgs=@()
$context=$null
$hasConfiguredAgents=$null -ne $config.PSObject.Properties['Agents']
if(!$Demo){
    if($hasConfiguredAgents){
        if($config.Session){ $herdrArgs=@('--session',[string]$config.Session) }
    }else{
        . "$PSScriptRoot\session-context.ps1"
        . "$PSScriptRoot\session-registry.ps1"
        $context=if($config.Session){Get-WorkHerdrContext -Session $config.Session}else{Get-WorkHerdrContext}
        $herdrArgs=@('--session',$context.Session)
    }
}
if(!$Once){ $Host.UI.RawUI.WindowTitle=$config.BoardTitle }
$logRoot=$config.LogRoot
$esc=[char]27
$reset="$esc[0m"
$bold="$esc[1m"
$muted="$esc[90m"
$tagColor="$esc[38;2;218;196;139m"
$agentColors=@{
    claude="$esc[38;2;250;179;135m"
    codex="$esc[38;2;137;180;250m"
    agy="$esc[38;2;166;227;161m"
    you="$esc[38;2;233;84;32m"
}
$agentNames=@{claude='Claude';codex='Codex';agy='agy';you='You'}
$taskStatuses=@{
    '진행'='working';'working'='working'
    '내 차례'='to do';'to do'='to do'
    '대기'='queued';'queued'='queued'
    '막힘'='blocked';'실패'='blocked';'blocked'='blocked'
}
$stateColors=@{
    working="$esc[36m";idle=$muted;'to do'="$esc[33m";queued=$muted
    blocked="$esc[31m";done="$esc[32m"
}
$nameWidth=7
$middleWidth=10
$separator=" $muted│$reset "
$taskOrder=@{'working'=0;'to do'=2;'queued'=3;'blocked'=1}

function Format-BoardColumn([string]$Value,[int]$Limit){
    $clipped=Fit-BoardLine (Clean-BoardText $Value) $Limit
    $width=Get-BoardTextWidth ($clipped -replace '\x1b\[[0-9;]*m','')
    $clipped+(' '*($Limit-$width))
}
function Format-BoardRow([string]$Name,[string]$Kind,[string]$Middle,[string]$MiddleColor,[string]$Content){
    $nameColor=if($Kind){$agentColors[$Kind]}
    " $nameColor$(Format-BoardColumn $Name $nameWidth)$reset$separator$MiddleColor$(Format-BoardColumn $Middle $middleWidth)$reset$separator$Content"
}
function Get-BoardWorkingMinutes([string]$Key){
    $firstSeen=$startedWorking[$Key]
    if(!$firstSeen){ $firstSeen=$now }
    $workingThisFrame[$Key]=$firstSeen
    [int][Math]::Floor([Math]::Max(0,($now-$firstSeen).TotalMinutes))
}
function Format-BoardQuota($Left,$ResetAt,[DateTimeOffset]$Now,[switch]$Weekly){
    if($null -eq $Left -or $Left -lt 0 -or $Left -gt 100 -or ($ResetAt -and $ResetAt -le $Now)){ return '—' }
    $duration=''
    if($ResetAt){
        $minutes=[int][Math]::Ceiling(($ResetAt-$Now).TotalMinutes)
        $hours=[int][Math]::Floor($minutes/60)
        if($Weekly -and $hours -ge 24){ $duration=" ($([int][Math]::Floor($hours/24))d$($hours%24)h)" }
        elseif($hours -or $Weekly){ $duration=" ($($hours)h$($minutes%60)m)" }
        else{ $duration=" ($($minutes)m)" }
    }
    if($duration){
        $threshold=if($Weekly){1440}else{60}
        $resetColor=if(($ResetAt-$Now).TotalMinutes -le $threshold){"$esc[33m"}else{$muted}
        $duration="$resetColor$duration$reset"
    }
    $percent=[Math]::Round([double]$Left)
    $color=if($percent -ge 50){32}elseif($percent -ge 20){33}else{31}
    "$esc[${color}m$percent% left$reset$duration"
}
function Get-BoardHerdrList([string]$Resource){
    $response=& $config.HerdrCommand @herdrArgs $Resource list 2>$null | Out-String | ConvertFrom-Json -ErrorAction Stop
    if($LASTEXITCODE -ne 0 -or !$response.result){ throw "Herdr $Resource list failed." }
    $response.result
}
function Get-BoardTaskRows([string]$Backlog,$Workers,$Sessions,$UsageRows,[switch]$Completed){
    $ordinal=0
    if(!$Completed){
        foreach($worker in $Workers.Active){
            $ordinal++
            [pscustomobject]@{Kind=$worker.Agent;Owner=$agentNames[$worker.Agent];State='working';Title=$worker.Title;Minutes=$worker.Minutes;Model=$worker.Model;Effort=$worker.Effort;Device=$worker.Device;Card=$worker.Card;Order=$ordinal}
        }
    }
    foreach($line in ($Backlog -split '\r?\n')){
        if($line -notmatch '^\|\s*(\d+)\s*\|'){ continue }
        $cells=@($line.Trim().Trim('|') -split '\|' | ForEach-Object Trim)
        $completedAt=$null
        if($Completed){
            if($cells.Count -ne 5){ continue }
            $completedAt=ConvertTo-BoardUsageDate $cells[4]
            if(!$completedAt -or $completedAt -lt $now.AddHours(-24) -or $completedAt -gt $now){ continue }
        }elseif($cells.Count -ne 4){ continue }
        if(!$Completed -and $cells[3] -in 'done','완료'){ continue }
        $state=if($Completed){'done'}else{$taskStatuses[$cells[3]]}
        if(!$state){ $state=$cells[3] }
        $owner=$cells[2]
        $kind=$null
        $session=$Sessions | Where-Object { $owner -in @($_.Id,$_.ProfileId,$_.Role) } | Select-Object -First 1
        if($session){ $kind=$session.Kind }
        elseif($owner -match '^(claude|codex|agy|you)(?:-\d+|\(bg\))?$'){ $kind=$Matches[1] }
        elseif($owner -like '사용자*'){ $kind='you' }
        elseif($owner -eq '일꾼'){ $kind='codex' }
        if($kind){ $owner=$agentNames[$kind] }
        $card=if(!$Demo){ Get-BoardBacklogCard $logRoot $cells[0] $cells[1] }
        if($state -eq 'working' -and ($Workers.Active | Where-Object {
            ($_.Card -and $_.Card -eq $card) -or ($_.Title -eq $cells[1] -and $_.Agent -eq $kind)
        })){ continue }
        $ordinal++
        $usage=$null
        if($state -eq 'working' -and $kind){
            if(!$session){
                $platformSessions=@($Sessions | Where-Object Kind -eq $kind)
                if($platformSessions.Count -eq 1){ $session=$platformSessions[0] }
            }
            if($session){ $usage=$UsageRows | Where-Object Id -eq $session.Id | Select-Object -First 1 }
        }
        $minutes=if($state -eq 'working'){Get-BoardWorkingMinutes "task:$($cells[0])"}
        $device=if($card){ Get-BoardCardDevice $logRoot $card }
        [pscustomobject]@{Kind=$kind;Owner=$owner;State=$state;Title=$cells[1];SourceState=$cells[3];Minutes=$minutes;Model=$usage.Model;Effort=$usage.Effort;Device=$device;Card=$card;CompletedAt=$completedAt;Order=$ordinal}
    }
}
function Format-BoardTask($Task){
    $content=Clean-BoardText $Task.Title
    $device=Clean-BoardText (Resolve-BoardDevice $Task.Device $config.MachineLabels $machines)
    if($device){ $content="$tagColor[$device]$reset $content" }
    if($Task.State -eq 'working'){
        $stale=Test-BoardStale $logRoot $Task.Card $now
        $elapsed=" · $(Format-BoardElapsed $Task.Minutes -Stale:$stale)"
        $contentWidth=$w-$nameWidth-$middleWidth-7
        $titleWidth=$contentWidth-(Get-BoardTextWidth ($elapsed -replace '\x1b\[[0-9;]*m',''))
        $model=switch -Regex ($Task.Model){
            '^gpt-[\d.]+-sol(?:\s+\(|$)' {'sol';break}
            '\bOpus\b' {'opus';break}
            '\bNeon\b' {'neon';break}
        }
        $effort=([string]$Task.Effort).ToLowerInvariant()
        if(!$effort -and $Task.Model -match '\((low|medium|high|xhigh|max|ultra)\)$'){ $effort=$Matches[1].ToLowerInvariant() }
        if($effort -eq 'medium'){ $effort='med' }
        $alias=if($model){ " · $model"; if($effort){ "·$effort" } }
        $alias=$alias -join ''
        if($alias -and (Get-BoardTextWidth ($content -replace '\x1b\[[0-9;]*m','')) + $alias.Length -le $titleWidth){
            $elapsed+="$muted$alias$reset"
        }
        $content=(Fit-BoardLine $content ([Math]::Max(1,$titleWidth)))+$elapsed
    }elseif($Task.State -eq 'blocked' -and $Task.SourceState -ne '실패'){
        $suffix=" · $esc[31m입력 필요$reset"
        $titleWidth=$w-$nameWidth-$middleWidth-7-(Get-BoardTextWidth ($suffix -replace '\x1b\[[0-9;]*m',''))
        $content=(Fit-BoardLine $content ([Math]::Max(1,$titleWidth)))+$suffix
    }
    Format-BoardRow $Task.Owner $Task.Kind $Task.State $stateColors[$Task.State] $content
}

$lastSessions=@()
$startedWorking=@{}
$machines=$null
while($true){
    $size=$Host.UI.RawUI.WindowSize
    $cols=if($Width){$Width}else{$size.Width}
    $rows=if($Height){$Height}else{$size.Height}
    if($cols -le 0){ $cols=100 }
    $w=[Math]::Max(1,$cols-1)
    $now=[DateTimeOffset]::Now
    $workingThisFrame=@{}

    if($Demo){ $data=Get-BoardDemo $now }
    else{
        $agents=@()
        try{ $agents=@((Get-BoardHerdrList 'agent').agents | Where-Object pane_id) }catch{}
        $sessions=@()
        if($agents.Count){
            if($hasConfiguredAgents){
                $sessions=@(foreach($entry in $config.Agents){
                    $live=$agents | Where-Object pane_id -eq $entry.Pane | Select-Object -First 1
                    if(!$live -or $entry.Key -notin 'claude','codex','agy','edu'){ continue }
                    $kind=if($entry.Key -eq 'edu'){'codex'}else{$entry.Key}
                    [pscustomobject]@{Id=$entry.Pane;ProfileId=$entry.Key;Kind=$kind;Name=$entry.Name;Role=$entry.Role;Pane=$entry.Pane;Conversation=$live.agent_session.value}
                })
            }else{
                try{
                    $panes=@((Get-BoardHerdrList 'pane').panes)
                    $registry=Read-WorkRegistry $context
                    $plan=Get-WorkSessionPlan $context $agents $panes
                    $sessions=@($plan.Sessions | Where-Object Active | Where-Object { $_.Pane -in $agents.pane_id })
                    $lastSessions=$sessions
                    $moved=@($sessions | Where-Object {
                        $id=$_.Id
                        $pane=$_.Pane
                        $registry.Sessions | Where-Object { $_.Active -and $_.Id -eq $id -and $_.Pane -ne $pane }
                    })
                    if($moved.Count){ Save-WorkSessionPlan $context $plan }
                }catch{
                    Write-Verbose "Session refresh: $_"
                    $sessions=@($lastSessions | Where-Object {
                        $previous=$_
                        $agents | Where-Object { $_.pane_id -eq $previous.Pane -and $_.terminal_id -eq $previous.TerminalId }
                    })
                }
            }
        }
        $data=[pscustomobject]@{
            Sessions=$sessions; Agents=$agents
            Workers=(Get-BoardWorkers $logRoot $config.ClaudeSessionsPath)
            Backlog=(Read-BoardUsageText (Join-Path $logRoot 'backlog.md'))
            Done=(Read-BoardUsageText (Join-Path $logRoot 'backlog-done.md'))
            Usage=@(Get-BoardUsage $config $sessions)
        }
    }

    $header="현황판  $($now.ToString('HH:mm'))"
    $gap=$w-(Get-BoardTextWidth $header)-$Version.Length
    $versionLabel=if($gap -gt 0){(' '*$gap)+"$muted$Version$reset"}
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add("$esc[1;97;48;2;233;84;32m$header$reset$versionLabel")
    $lines.Add('')
    $lines.Add("${bold}에이전트$reset")
    $agentStart=$lines.Count
    $accounts=@{}
    $backgroundCounts=@{}
    foreach($worker in $data.Workers.Active){ $backgroundCounts[$worker.Agent]++ }
    $shownPlatforms=@{}
    foreach($session in $data.Sessions){
        $live=$data.Agents | Where-Object pane_id -eq $session.Pane | Select-Object -First 1
        $state=if($live.agent_status -in 'working','blocked','done'){$live.agent_status}else{'idle'}
        $activity="$($stateColors[$state])$state$reset"
        $backgroundCount=$backgroundCounts[$session.Kind]
        if($backgroundCount -and !$shownPlatforms[$session.Kind]){
            $activity="$($stateColors.working)working$reset · bg $backgroundCount"
        }elseif($state -eq 'working'){
            $activity+=" · $(Format-BoardElapsed (Get-BoardWorkingMinutes "agent:$($session.Pane)"))"
        }
        if($state -eq "blocked"){ $activity="$esc[31m입력 필요$reset" }
        $shownPlatforms[$session.Kind]=$true
        $name=if($session.Name){ $session.Name }else{ $agentNames[$session.Kind] }
        $lines.Add((Format-BoardRow $name $session.Kind $session.Role '' $activity))
        $usage=$data.Usage | Where-Object Id -eq $session.Id | Select-Object -First 1
        $account=$usage.Account
        if(!$account -and $session.Kind -eq 'codex'){ $account='codex-default' }
        $detail=Format-BoardModel $usage.Model $usage.Effort
        if(!$account -or !$accounts[$account]){
            if($account){ $accounts[$account]=$true }
            $five=Format-BoardQuota $usage.FiveLeft $usage.FiveReset $now
            $week=Format-BoardQuota $usage.WeekLeft $usage.WeekReset $now -Weekly
            $detail+=" · 5h $five · wk $week"
        }
        $lines.Add("   $detail")
    }
    $agentRows=$lines.Count-$agentStart
    $tasks=@(Get-BoardTaskRows $data.Backlog $data.Workers $data.Sessions $data.Usage | Sort-Object { if($taskOrder.ContainsKey($_.State)){$taskOrder[$_.State]}else{4} },Order)
    $visibleTasks=@($tasks)
    $done=@(Get-BoardTaskRows $data.Done $null $data.Sessions -Completed)
    $recentDone=@($done | Sort-Object CompletedAt,Order -Descending | Select-Object -First 5)
    try{ if($context){ $machines=(Read-WorkJson (Get-WorkCatalogPath $context)).machines } }
    catch{ Write-Verbose "Machine catalog refresh: $_" }
    $lines.Add('')
    $lines.Add("$($bold)작업 $($tasks.Count)$reset")
    $taskStart=$lines.Count
    foreach($task in $visibleTasks){ $lines.Add((Format-BoardTask $task)) }
    $lines.Add('')
    $footer="$($bold)끝낸 일 $($done.Count)$reset"
    $lines.Add($footer)
    foreach($task in $recentDone){ $lines.Add((Format-BoardTask $task)) }
    $startedWorking=$workingThisFrame
    if((!$Once -or $Height) -and $rows -gt 0){
        $limit=[Math]::Max(1,$rows-1)
        for($i=$visibleTasks.Count-1; $i -ge 0 -and $lines.Count -gt $limit; $i--){
            if($visibleTasks[$i].State -in 'queued','to do'){ $lines.RemoveAt($taskStart+$i) }
        }
        $doneToRemove=[Math]::Min([Math]::Max(0,$lines.Count-$limit),$recentDone.Count)
        if($doneToRemove){ $lines.RemoveRange($lines.Count-$doneToRemove,$doneToRemove) }
        if($lines.Count -gt $limit){ $lines.RemoveAll([Predicate[string]]{param($line) !$line}) | Out-Null }
        if($lines.Count -gt $limit -and $agentRows){
            $remove=[Math]::Min($agentRows,2*[int][Math]::Ceiling(($lines.Count-$limit)/2))
            $lines.RemoveRange($agentStart-1+$agentRows-$remove,$remove)
        }
    }

    $frame=@($lines | ForEach-Object { Fit-BoardLine $_ $w })
    if($Once){ [Console]::Write(($frame -join [Environment]::NewLine)); break }
    Write-BoardFrame $frame
    $refreshAt=[DateTime]::UtcNow.AddSeconds($Refresh)
    do{
        Start-Sleep -Milliseconds 100
        $current=$Host.UI.RawUI.WindowSize
    }while([DateTime]::UtcNow -lt $refreshAt -and $current.Width -eq $size.Width -and $current.Height -eq $size.Height)
}
