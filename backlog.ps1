[CmdletBinding(DefaultParameterSetName='Add')]
param(
 [Parameter(Mandatory=$true,ParameterSetName='Add')][string]$Add,
 [Parameter(ParameterSetName='Add')][string]$Owner='Codex',
 [Parameter(Mandatory=$true,ParameterSetName='Set')][int]$Set,
 [Parameter(Mandatory=$true,ParameterSetName='Done')][int]$Done,
 [Parameter(ParameterSetName='Add')][Parameter(Mandatory=$true,ParameterSetName='Set')]
 [ValidateSet('working','to do','queued','blocked')][string]$State='to do',
 [string]$LogRoot,
 [ValidateRange(1,60)][int]$LockTimeoutSeconds=10
)
$ErrorActionPreference='Stop'
if(!$LogRoot -and $env:HERDR_SESSION -match '^space-(.+)$' -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "spaces\$($Matches[1]).json"))){ $LogRoot=Join-Path $PSScriptRoot "spaces\$($Matches[1])\logs" }
if(!$LogRoot){ $LogRoot=Join-Path $PSScriptRoot 'logs' }
$utf8=[Text.UTF8Encoding]::new($true)
$LogRoot=[IO.Path]::GetFullPath($LogRoot)
[void][IO.Directory]::CreateDirectory($LogRoot)
$paths=@((Join-Path $LogRoot 'backlog.md'),(Join-Path $LogRoot 'backlog-done.md'))
$journalPath=Join-Path $LogRoot 'backlog.transaction.json'
$lockPath=Join-Path $LogRoot 'backlog.lock'
$lock=$null
$files=@()

function Read-OpenFile($Stream){
 $Stream.Position=0
 $reader=[IO.StreamReader]::new($Stream,[Text.Encoding]::UTF8,$true,4096,$true)
 try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Write-OpenFile($Stream,[string]$Text){
 $bytes=$utf8.GetPreamble()+$utf8.GetBytes($Text)
 $Stream.Position=0
 $Stream.Write($bytes,0,$bytes.Length)
 $Stream.SetLength($bytes.Length)
 $Stream.Flush($true)
}
function Get-Rows([string]$Text){
 foreach($line in ($Text -split '\r?\n')){
  if($line -match '^\|\s*(\d+)\s*\|'){
   $cells=@($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
   if($cells.Count -ne 4 -and !($cells.Count -eq 5 -and $cells[3] -eq "완료")){ throw "Invalid backlog row: $line" }
   [pscustomobject]@{Id=[int]$cells[0];Title=$cells[1];Owner=$cells[2];State=$cells[3];Line=$line}
  }
 }
}
function Append-Row([string]$Text,[string]$Row){ $Text.TrimEnd()+"`r`n"+$Row+"`r`n" }
function Remove-Row([string]$Text,[int]$Id){
 (($Text -split '\r?\n' | Where-Object { $_ -notmatch ('^\|\s*'+$Id+'\s*\|') }) -join "`r`n").TrimEnd()+"`r`n"
}
try {
 $deadline=[DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
 while(-not $lock){
  try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
  catch [IO.IOException] { if([DateTime]::UtcNow -ge $deadline){ throw 'Backlog lock timed out.' }; Start-Sleep -Milliseconds 100 }
 }
 # Holding both files denies concurrent legacy writers as well as other tool calls.
 foreach($path in $paths){
  $files+=,[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
 }
 $texts=@(Read-OpenFile $files[0]; Read-OpenFile $files[1])
 if(Test-Path -LiteralPath $journalPath){
  $pending=[IO.File]::ReadAllText($journalPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
  if($pending.version -ne 1 -or @($pending.before).Count -ne 2 -or @($pending.after).Count -ne 2){ throw 'Invalid backlog transaction journal.' }
  for($i=0;$i -lt 2;$i++){
   if($texts[$i] -cne $pending.before[$i] -and $texts[$i] -cne $pending.after[$i]){
    throw 'Backlog changed after an interrupted transaction. Preserve the journal and reconcile the files before retrying.'
   }
  }
  for($i=0;$i -lt 2;$i++){ Write-OpenFile $files[$i] $pending.after[$i] }
  [IO.File]::Delete($journalPath)
  $texts=@($pending.after)
 }
 $before=@($texts)
 if(-not $texts[0]){ $texts[0]="# 백로그`r`n| # | 할 일 | 담당 | 상태 |`r`n|---|---|---|---|`r`n" }
 if(-not $texts[1]){ $texts[1]="# 끝낸 일`r`n| # | 할 일 | 담당 | 상태 |`r`n|---|---|---|---|`r`n" }
 $open=@(Get-Rows $texts[0]); $closed=@(Get-Rows $texts[1]); $all=@($open)+@($closed)
 $duplicates=@($all | Group-Object Id | Where-Object Count -gt 1)
 if($duplicates.Count){ throw 'Duplicate backlog IDs require reconciliation before editing.' }
 $resultState=$State
 if($PSCmdlet.ParameterSetName -eq 'Add'){
  foreach($value in @($Add,$Owner)){ if([string]::IsNullOrWhiteSpace($value) -or $value -match '[|\r\n\x00-\x1f]'){ throw 'Title and owner must be nonempty single-line table cells.' } }
  $id=1
  if($all.Count){ $id=1+[int](($all | Measure-Object Id -Maximum).Maximum) }
  $texts[0]=Append-Row $texts[0] "| $id | $($Add.Trim()) | $($Owner.Trim()) | $State |"
 } else {
  $id=if($PSCmdlet.ParameterSetName -eq 'Done'){$Done}else{$Set}
  $row=@($open | Where-Object Id -eq $id)
  if(-not $row.Count){
   if($PSCmdlet.ParameterSetName -eq 'Done' -and @($closed | Where-Object Id -eq $id).Count){
    [pscustomobject]@{Id=$id;State='done';Changed=$false}; return
   }
   throw "Open backlog item $id does not exist."
  }
  $row=$row[0]
  if($PSCmdlet.ParameterSetName -eq 'Done'){
   $texts[0]=Remove-Row $texts[0] $id
   $texts[1]=$texts[1] -replace '(?m)^\| # \| 할 일 \| 담당 \| 상태 \|\r?$', '| # | 할 일 | 담당 | 상태 | 완료 시각 |' -replace '(?m)^\|---\|---\|---\|---\|\r?$', '|---|---|---|---|---|'
   $texts[1]=Append-Row $texts[1] "| $id | $($row.Title) | $($row.Owner) | 완료 | $([DateTimeOffset]::Now.ToString('o')) |"
   $resultState='done'
  } else {
   $replacement="| $id | $($row.Title) | $($row.Owner) | $State |"
   $texts[0]=(($texts[0] -split '\r?\n' | ForEach-Object { if($_ -match ('^\|\s*'+$id+'\s*\|')){$replacement}else{$_} }) -join "`r`n").TrimEnd()+"`r`n"
  }
 }
 # Write-ahead journal makes a completed first file recoverable on the next call.
 $journal=[ordered]@{version=1;before=$before;after=$texts}|ConvertTo-Json -Depth 4
 [IO.File]::WriteAllText($journalPath,$journal,$utf8)
 try {
  for($i=0;$i -lt 2;$i++){ Write-OpenFile $files[$i] $texts[$i] }
 } catch {
  $writeError=$_
  for($i=0;$i -lt 2;$i++){ Write-OpenFile $files[$i] $before[$i] }
  [IO.File]::Delete($journalPath)
  throw $writeError
 }
 [IO.File]::Delete($journalPath)
 [pscustomobject]@{Id=$id;State=$resultState;Changed=$true}
} finally {
 foreach($file in $files){ if($file){$file.Dispose()} }
 if($lock){ $lock.Dispose() }
}
