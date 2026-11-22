$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('board-matrix-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$encoding=[Text.UTF8Encoding]::new($false)
$originalOut=[Console]::Out
$originalEncoding=[Console]::OutputEncoding
$originalSocket=$env:HERDR_SOCKET_PATH
$originalCodexHome=$env:CODEX_HOME
$ansi='\x1b\[[0-9;]*m'
$strictEncoding=[Text.UTF8Encoding]::new($false,$true)
$configPath=Join-Path $fixture 'board.json'
$logs=Join-Path $fixture 'logs'
$checks=0
. (Join-Path $root 'board-render.ps1')

function Invoke-MatrixHerdr {
    if('agent' -in $args){
        @{result=@{agents=$global:H3MatrixAgents}} | ConvertTo-Json -Depth 6 -Compress
    } else { '{"result":{"panes":[]}}' }
    $global:LASTEXITCODE=0
}
function Get-CimInstance { $global:H3MatrixProcesses | Where-Object { $_ } }
function Write-Fixture([string]$Path,[string]$Text){ [IO.File]::WriteAllText($Path,$Text,$encoding) }
function Clear-FixtureLogs {
    if(![IO.Directory]::Exists($logs)){ return }
    foreach($file in [IO.Directory]::EnumerateFiles($logs)){ [IO.File]::Delete($file) }
    [IO.Directory]::Delete($logs)
}
function Read-Frame([string]$Script,[hashtable]$Arguments){
    $writer=[IO.StringWriter]::new()
    [Console]::SetOut($writer)
    try {
        & (Join-Path $root $Script) @Arguments
        ($writer.ToString() -replace $ansi,'') -split '\r?\n'
    } finally { [Console]::SetOut($originalOut); $writer.Dispose() }
}
function Assert-Frame($Lines,[int]$Width,[string]$Context){
    foreach($line in $Lines){
        [void]$strictEncoding.GetBytes($line)
        $cells=0
        for($index=0;$index -lt $line.Length;$index++){
            $point=[char]::ConvertToUtf32($line,$index)
            if($point -gt 0xffff){ $index++ }
            if($point -ge 0xac00 -and $point -le 0xd7a3 -or $point -ge 0x1f300){ $cells+=2 } else { $cells++ }
        }
        if($cells -gt ($Width-1) -or $line -match '[\x00-\x1f\x7f-\x9f\ufffd]'){ throw "$Context invalid row at $Width cells: $line" }
    }
}

try {
    $emoji='한국 test '+('❤️'*10)
    if((Get-BoardTextWidth $emoji) -ne 30 -or (Fit-BoardLine $emoji 29) -notmatch '…'){
        throw 'Emoji presentation characters can wrap at a 30-column pane.'
    }
    if((Fit-BoardLine 'sample 👩‍💻 title' 10) -match '[👩💻]' -or (Get-BoardTextWidth '1️⃣') -ne 2){
        throw 'A clipped title separated an emoji sequence or underestimated a keycap.'
    }
    $env:HERDR_SOCKET_PATH=$null
    $env:CODEX_HOME=$fixture
    $platforms=@('claude','codex','codex','agy','claude','agy')
    foreach($count in 1..6){
        Clear-FixtureLogs
        $working=@(0,1,15)[($count-1)%3]
        if($count -gt 1){ [void][IO.Directory]::CreateDirectory($logs) }
        $configAgents=@(for($index=0;$index -lt $count;$index++){
            @{Pane="test:p$index";Key=$platforms[$index];Name=$platforms[$index];Role="역할 $index"}
        })
        $global:H3MatrixAgents=@(foreach($entry in $configAgents){ @{pane_id=$entry.Pane;agent=$entry.Key;agent_status='working'} })
        $config=@{BoardTitle='Test board';Session="fixture-$count";HerdrCommand='Invoke-MatrixHerdr';LogRoot='logs';Agents=$configAgents}
        Write-Fixture $configPath ($config | ConvertTo-Json -Depth 5)
        $global:H3MatrixProcesses=@(for($job=1;$job -le $working;$job++){
            $name="sample-$job"
            Write-Fixture (Join-Path $logs "card-$name.md") "# $name 한글 long🚀🚀🚀name`n기기: Remote Lab"
            if($count -eq 3){ Write-Fixture (Join-Path $logs "exec-$name.jsonl") "bad json`n{" }
            [pscustomobject]@{Name='codex.exe';ProcessId=$job;ParentProcessId=0;CommandLine="codex.exe exec card-$name.md";CreationDate=(Get-Date).AddMinutes(-3)}
        })
        if($count -in 2,5){
            Write-Fixture (Join-Path $logs 'backlog.md') ''
            Write-Fixture (Join-Path $logs 'exec-empty.jsonl') ''
        } elseif($count -in 3,6){
            Write-Fixture (Join-Path $logs 'backlog.md') "| 88 | broken |`n| 99 | Finish sample backlog 점검 🚀 | Claude | queued |`nrandom text"
        }
        foreach($width in 30,55,80,120){
            foreach($height in 10,20,40){
                $board=Read-Frame 'board.ps1' @{ConfigPath=$configPath;Once=$true;Width=$width;Height=$height}
                $background=Read-Frame 'bg-view.ps1' @{LogRoot=$logs;Once=$true;Width=$width;Height=$height}
                Assert-Frame $board $width 'Board'
                Assert-Frame $background $width 'Background'
                if(@($board -match '^ .*│ working\s*│').Count -ne $working -or @($background -match '^working').Count -ne $working){
                    throw "Working rows lost at $width x $height with $count agents and $working working tasks."
                }
                if($width -eq 120 -and $height -eq 40){
                    if(@($board -match '│ 역할').Count -ne $count){ throw 'Profile agents lost or merged.' }
                    if($working -and ($board -join "`n") -notmatch '\[Remote Lab\].*한글 long🚀'){ throw 'Device or mixed-language sample missing.' }
                }
                $checks+=2
            }
        }
    }
    "Board matrix: $checks frames passed ($($PSVersionTable.PSVersion))"
} finally {
    Remove-Variable H3MatrixAgents,H3MatrixProcesses -Scope Global -ErrorAction SilentlyContinue
    $env:CODEX_HOME=$originalCodexHome
    $env:HERDR_SOCKET_PATH=$originalSocket
    [Console]::OutputEncoding=$originalEncoding
    [Console]::SetOut($originalOut)
    Clear-FixtureLogs
    [IO.File]::Delete($configPath)
    [IO.Directory]::Delete($fixture)
}
