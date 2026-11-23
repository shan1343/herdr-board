param([ValidateRange(1,3600)][int]$Refresh=5,[ValidateRange(1,3600)][int]$IdleRefresh=15,[switch]$Once,[int]$Width,[int]$Height,[string]$LogRoot,[switch]$Demo,
      [string]$Session,[string]$SharedLogRoot,[string]$ProjectPath,[string]$CodexSessionsPath)
# Live background jobs with their latest steps and one completed summary. Token-free (reads logs\exec-*.jsonl).
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if(!$Once){ $Host.UI.RawUI.WindowTitle='백그라운드' }
. (Join-Path $PSScriptRoot 'board-workers.ps1')
. (Join-Path $PSScriptRoot 'board-usage.ps1')
. (Join-Path $PSScriptRoot 'board-render.ps1')
. (Join-Path $PSScriptRoot 'board-demo.ps1')
$workerScope=if (!$Demo) { New-BoardWorkerScope $LogRoot $Session $SharedLogRoot $ProjectPath $CodexSessionsPath }
$claudeSessions=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude\sessions'
$e=[char]27; $cB="$e[1m"; $cC="$e[36m"; $cG="$e[32m"; $cM="$e[90m"; $cX="$e[0m"
$platformNames=@{claude='Claude';codex='Codex';agy='agy'}
$platformColors=@{claude="$e[38;2;250;179;135m";codex="$e[38;2;137;180;250m";agy="$e[38;2;166;227;161m"}
function DispW([char]$ch){ $c=[int]$ch; if(($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFF00 -and $c -le 0xFF60)){2}else{1} }
function Fit([string]$s,[int]$max){ $o='';$w=0; $i=0; $lastCell=0; while($i -lt $s.Length){ if($s[$i] -eq $e){ $j=$s.IndexOf('m',$i); if($j -lt 0){break}; $o+=$s.Substring($i,$j-$i+1); $i=$j+1; continue }; $cw=DispW $s[$i]; if($w+$cw -gt $max){ if($w -eq $max){$o=$o.Substring(0,$lastCell)}; $o+="…$cX"; break }; $lastCell=$o.Length; $o+=$s[$i]; $w+=$cw; $i++ }; $o }
function Read-WorkerEvents($Log){
  foreach($line in ((Read-BoardUsageText $Log 200000) -split '\r?\n')){
    if(!$line.Trim()){ continue }
    try{ $line | ConvertFrom-Json -ErrorAction Stop }catch{}
  }
}
function Get-WorkerStep($Event){
  $item=$Event.item
  if($Event.type -in 'turn.failed','error' -or ($null -ne $item.exit_code -and $item.exit_code -ne 0)){
    return "$e[31m오류 처리 중$cX"
  }
  switch($item.type){
    'reasoning' { return '생각 중' }
    'file_change' {
      $file=Clean-BoardText (([string]($item.changes | Select-Object -First 1).path -split '[/\\]')[-1])
      if($file){ return "고치는 중($file)" }
      return '고치는 중'
    }
    'command_execution' {
      $command=[string]$item.command
      if($command -match '(?i)\bherdr(?:\.exe)?\s+.*?\bpane\s+(?:read|capture)\b|\b(?:screenshot|capture-pane)\b'){ return '화면 확인 중' }
      if($command -match '(?i)\b(?:apply_patch|Set-Content|Add-Content|write_text|WriteAllText)\b'){ return '고치는 중' }
      $read=[regex]::Match($command,'(?i)\b(?:Get-Content|Select-String|rg|cat|read_text|type)\b')
      if($read.Success){
        $file=[regex]::Match($command.Substring($read.Index+$read.Length),'[\w가-힣.-]+\.(?:ps1|mjs|js|py|md|jsonl?|toml|txt|yaml|yml)\b').Value
        if($file){ return "파일 읽는 중($file)" }
        return '파일 읽는 중'
      }
      if($command -match '(?i)\b(?:verify|test|pytest|check|lint|build|assert)[-\w]*\b'){ return '검사 중' }
      return '작업 중'
    }
  }
  if($Event.type -eq 'turn.completed'){ return '정리 중' }
  '작업 중'
}
while($true){
  $now=[DateTimeOffset]::Now
  $refreshAt=$now.UtcDateTime.AddSeconds($Refresh)
  $size=$Host.UI.RawUI.WindowSize
  $cols=if($Width){$Width}elseif($size.Width -gt 0){$size.Width}else{100}
  $w=[Math]::Max(1,$cols-1)
  $limit=[Math]::Max(1, $(if($Height){$Height}else{$size.Height})-1)
  $out=[Collections.Generic.List[string]]::new()
  $out.Add("$e[1;97;48;2;233;84;32m  백그라운드  $($now.ToString('HH:mm:ss'))  v2.11  $cX")
  $jobs=@()
  if($Demo){ $running=@((Get-BoardDemo $now).Workers.Active) }
  else{
    $snapshot=Get-BoardWorkers $workerScope.LogRoot $claudeSessions $workerScope
    $jobs=@($snapshot.Jobs | Where-Object EventLog | Sort-Object { $_.EventLog.LastWriteTimeUtc } -Descending)
    $running=@($snapshot.Active)
  }
  $doneLine=$null
  if($out.Count+$running.Count -lt $limit){
    foreach($job in $jobs){
      $key=$job.Card
      if($key -in $running.Card){ continue }
      $events=@(Read-WorkerEvents $job.EventLog.FullName)
      if(!$events.Count -or $events[-1].type -ne 'turn.completed'){ continue }
      $message=($events | Where-Object {$_.item.type -eq 'agent_message'} | Select-Object -Last 1).item.text
      $sentence=(([string]$message -replace '[\x00-\x1f\x7f-\x9f]',' ' ).Trim() -split '(?<=[.!?。])\s+',2)[0]
      $chars=[Globalization.StringInfo]::new($sentence)
      if($chars.LengthInTextElements -gt 40){ $sentence=$chars.SubstringByTextElements(0,39)+'…' }
      $title=Clean-BoardText (Get-BoardCardTitle $job.Root $key $key)
      $doneLine="${cG}done$cX  $title  $sentence"
      break
    }
  }
  $details=[Math]::Max(0,$limit-$out.Count-$running.Count-[int][bool]$doneLine)
  foreach($worker in $running){
    $stale=if ($worker.Root) { Test-BoardStale $worker.Root $worker.Card $now } else { $false }
    $elapsed=Format-BoardElapsed $worker.Minutes -Stale:$stale
    $elapsedWidth=Get-BoardTextWidth ($elapsed -replace '\x1b\[[0-9;]*m','')
    $title="${cC}working$cX  $cB$(Clean-BoardText $worker.Title)$cX"
    $out.Add("$(Fit-BoardLine $title ([Math]::Max(1,$w-$elapsedWidth-2)))  $elapsed")
    if($details -gt 0){
      $details--
      $platform=$platformNames[$worker.Agent]
      $model=([string]$worker.Model -replace '[\x00-\x1f\x7f-\x9f]',' ').Trim()
      $effort=([string]$worker.Effort -replace '[\x00-\x1f\x7f-\x9f]',' ').Trim()
      if($model -match '\s+\((low|medium|high|xhigh|max|ultra)\)$'){
        if(!$effort){ $effort=$Matches[1] }
        $model=$model.Substring(0,$model.Length-$Matches[0].Length)
      }
      if(!$model){ $model='—' }
      if(!$effort){ $effort='—' }
      $last=if($worker.LogPath){ Read-WorkerEvents $worker.LogPath | Select-Object -Last 1 }
      $out.Add("    $cM$platform · $model · $effort · 지금: $(Get-WorkerStep $last)$cX")
    }
  }
  if($doneLine){ $out.Add($doneLine) }
  elseif(!$running.Count -and $out.Count -lt $limit){ $out.Add("  $cM"+"백그라운드 작업 없음$cX") }
  $frame=@($out | ForEach-Object { Fit-BoardLine $_ $w })
  if($Once){ [Console]::Write(($frame -join [Environment]::NewLine)); break }
  Write-BoardFrame $frame
  $waitSeconds=if($running.Count){ $Refresh }else{ [Math]::Max($Refresh,$IdleRefresh) }
  $refreshAt=$now.UtcDateTime.AddSeconds($waitSeconds)
  while([DateTime]::UtcNow -lt $refreshAt){
    Start-Sleep -Milliseconds 100
    $current=$Host.UI.RawUI.WindowSize
    if($current.Width -ne $size.Width -or $current.Height -ne $size.Height){ break }
  }
}
