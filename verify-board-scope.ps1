$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('board-scope-'+[guid]::NewGuid().ToString('N'))
$utf8=[Text.UTF8Encoding]::new($false)
$consoleOut=[Console]::Out
$consoleEncoding=[Console]::OutputEncoding
$envSession=$env:HERDR_SESSION
$envSocket=$env:HERDR_SOCKET_PATH
$envCodex=$env:CODEX_HOME
$checks=0

function Write-Fixture([string]$Name,[string]$Value) {
    $path=Join-Path $fixture $Name
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path,$Value,$utf8)
}
function Add-Job([string]$Root,[string]$Card,[string]$Title,[string]$Room,[string]$Cwd,[string]$Summary) {
    $lines=@()
    if ($Cwd) { $lines+=(@{type='worker.started';cwd=$Cwd} | ConvertTo-Json -Compress) }
    if ($Summary) {
        $lines+=(@{type='item.completed';item=@{type='agent_message';text=$Summary}} | ConvertTo-Json -Compress)
        $lines+='{"type":"turn.completed"}'
    } else { $lines+='{"type":"turn.started"}' }
    $text=if ($Room) { "# $Title"+[Environment]::NewLine+"작업실: $Room" } else { "# $Title" }
    Write-Fixture "$Root/card-$Card.md" $text
    Write-Fixture "$Root/exec-$Card.jsonl" ($lines -join [Environment]::NewLine)
}
function New-FixtureWorker([int]$Id,[string]$Command) {
    [pscustomobject]@{Name='codex.exe';ProcessId=$Id;ParentProcessId=0;CreationDate=(Get-Date).AddMinutes(-2);CommandLine=$Command}
}
function Get-CimInstance { $global:BoardScopeFixtureWorkers }
function Invoke-FixtureHerdr { '{"result":{"agents":[],"panes":[]}}'; $global:LASTEXITCODE=0 }
function Read-FixtureFrame([string]$Name,[hashtable]$Arguments) {
    $output=[IO.StringWriter]::new()
    [Console]::SetOut($output)
    try {
        & (Join-Path $fixture $Name) @Arguments -Once -Width 120 -Height 40
        $output.ToString() -replace '\x1b\[[0-9;]*m',''
    } finally { [Console]::SetOut($consoleOut); $output.Dispose() }
}
function Assert-Frame([string]$Frame,[string[]]$Required,[string[]]$Forbidden,[string]$Label) {
    foreach ($marker in $Required) {
        if (!$Frame.Contains($marker)) { throw "$Label is missing $marker" }
        $script:checks++
    }
    foreach ($marker in $Forbidden) {
        if ($Frame.Contains($marker)) { throw "$Label leaked $marker" }
        $script:checks++
    }
}

[void][IO.Directory]::CreateDirectory($fixture)
try {
    Copy-Item -LiteralPath @('board.ps1','bg-view.ps1','board-usage.ps1','board-workers.ps1','board-scope.ps1','board-render.ps1','board-demo.ps1' |
        ForEach-Object { Join-Path $PSScriptRoot $_ }) -Destination $fixture
    $env:HERDR_SOCKET_PATH=$null
    $env:CODEX_HOME=$fixture
    $alphaPath=Join-Path $fixture 'project alpha'
    $betaPath=Join-Path $fixture 'project beta'
    foreach ($room in @(@{Name='alpha';ProjectPath=$alphaPath;CatalogProject='Project Alpha'},@{Name='beta';ProjectPath=$betaPath;CatalogProject='Project Beta'})) {
        Write-Fixture "spaces/$($room.Name)/effective-space.json" ($room | ConvertTo-Json)
    }
    Add-Job 'logs' 'tag' 'AlphaTaggedRunning' 'Project Alpha' $betaPath
    Add-Job 'logs' 'cwd' 'BetaCwdRunning' '' $betaPath
    Add-Job 'logs' 'legacy' 'WorkLegacyRunning'
    Add-Job 'logs' 'alpha-done' 'AlphaDoneTitle' 'alpha' '' 'AlphaDoneSummary'
    Add-Job 'logs' 'beta-done' 'BetaDoneTitle' '' $betaPath 'BetaDoneSummary'
    Add-Job 'logs' 'work-done' 'WorkDoneTitle' '' '' 'WorkDoneSummary'
    $thread='2fc1b691-2bc0-41d7-a016-6082f05462f3'
    $nativeLog=@(
        @{type='thread.started';thread_id=$thread} | ConvertTo-Json -Compress
        '{"type":"item.completed","item":{"type":"agent_message","text":"BetaNativeSummary"}}'
        '{"type":"turn.completed"}'
    ) -join [Environment]::NewLine
    Write-Fixture 'logs/exec-native.jsonl' $nativeLog
    Write-Fixture "sessions/2026/01/01/rollout-2026-01-01T02-03-04-$thread.jsonl" (@{type='session_meta';payload=@{cwd=$betaPath;base_instructions=('x'*40000)}} | ConvertTo-Json -Depth 3 -Compress)
    [IO.File]::SetLastWriteTimeUtc((Join-Path $fixture 'logs/exec-native.jsonl'),[DateTime]::UtcNow.AddMinutes(1))
    Add-Job 'spaces/alpha/logs' 'collision' 'AlphaCollisionRunning'
    Add-Job 'spaces/beta/logs' 'collision' 'BetaCollisionRunning'
    Add-Job 'logs' 'overlap' 'WorkSimilarPrefix' '' ($betaPath+'-extra')
    Write-Fixture 'logs/backlog.md' '| 1 | ForeignBacklogMarker (card-tag.md) | Codex | working |'
    Write-Fixture 'spaces/alpha/logs/card-local-no-log.md' '# AlphaLocalCardOnly'
    Write-Fixture 'spaces/beta/logs/card-local-no-log.md' '# BetaLocalCardOnly'

    $global:BoardScopeFixtureWorkers=@(
        (New-FixtureWorker 1 "codex.exe exec -C ""$betaPath"" card-tag.md"),
        (New-FixtureWorker 2 "codex.exe exec -c model_reasoning_effort=low --cd ""$betaPath"" card-cwd.md"),
        (New-FixtureWorker 3 "codex.exe exec ""A quoted prompt says --cd '$betaPath'"" card-legacy.md"),
        (New-FixtureWorker 4 "codex.exe exec -C ""$alphaPath"" card-collision.md"),
        (New-FixtureWorker 5 "codex.exe exec -C ""$betaPath"" card-collision.md"),
        (New-FixtureWorker 6 ('codex.exe exec "'+(Join-Path $fixture 'spaces/alpha/logs/card-local-no-log.md').Replace('\','/')+'"')),
        (New-FixtureWorker 7 ('codex.exe exec "'+(Join-Path $fixture 'spaces/beta/logs/card-local-no-log.md').Replace('/','\')+'"')),
        (New-FixtureWorker 8 "codex.exe exec --cd ""$($betaPath)-extra"" card-overlap.md"),
        (New-FixtureWorker 9 'codex.exe exec card-collision.md')
    )

    $frames=@{}
    foreach ($session in 'space-alpha','space-beta','work-herdr') {
        $env:HERDR_SESSION=$session
        Write-Fixture 'settings.json' (@{BoardTitle='Fixture';Agents=@();HerdrCommand='Invoke-FixtureHerdr'} | ConvertTo-Json)
        $board=Read-FixtureFrame 'board.ps1' @{ConfigPath=(Join-Path $fixture 'settings.json')}
        $bg=Read-FixtureFrame 'bg-view.ps1' @{}
        $frames[$session]=@{Board=$board;Background=$bg}
    }
    $active=@{
        'space-alpha'=@('AlphaTaggedRunning','AlphaCollisionRunning','AlphaLocalCardOnly')
        'space-beta'=@('BetaCwdRunning','BetaCollisionRunning','BetaLocalCardOnly')
        'work-herdr'=@('WorkLegacyRunning','WorkSimilarPrefix')
    }
    $summary=@{'space-alpha'='AlphaDoneSummary';'space-beta'='BetaNativeSummary';'work-herdr'='WorkDoneSummary'}
    foreach ($session in $active.Keys) {
        $others=@(foreach ($other in $active.Keys) { if ($other -ne $session) { $active[$other] } })
        $foreignSummaries=@($summary.Values | Where-Object { $_ -ne $summary[$session] })
        Assert-Frame $frames[$session].Board ($active[$session]+@('v2.11')) ($others+@('ForeignBacklogMarker')) "$session board"
        Assert-Frame $frames[$session].Background ($active[$session]+@($summary[$session],'v2.11')) ($others+$foreignSummaries+@('BetaDoneSummary' | Where-Object { $session -ne 'space-beta' })) "$session background"
        $working=[regex]::Matches($frames[$session].Background,'(?m)^working ').Count
        if ($working -ne $active[$session].Count) { throw "$session displayed $working workers for $($active[$session].Count) owned jobs. $($frames[$session].Background)" }
        $checks++
    }

    $env:HERDR_SESSION=$null
    $env:HERDR_SOCKET_PATH=Join-Path $fixture 'herdr/sessions/space-beta/herdr.sock'
    $socketFrame=Read-FixtureFrame 'bg-view.ps1' @{}
    Assert-Frame $socketFrame @('BetaCwdRunning','BetaNativeSummary') @('AlphaTaggedRunning','WorkDoneSummary') 'Socket scope'
    [void][IO.Directory]::CreateDirectory($alphaPath)
    $env:HERDR_SOCKET_PATH=$null
    Push-Location -LiteralPath $alphaPath
    try { $cwdFrame=Read-FixtureFrame 'bg-view.ps1' @{} } finally { Pop-Location }
    Assert-Frame $cwdFrame @('AlphaTaggedRunning','AlphaDoneSummary') @('BetaCwdRunning','WorkDoneSummary') 'Project cwd scope'

    # A freshly created rollout is visible in an already running dashboard.
    . (Join-Path $fixture 'board-scope.ps1')
    . (Join-Path $fixture 'board-usage.ps1')
    $scope=New-BoardWorkerScope -Session 'work-herdr'
    [void]@(Get-BoardWorkerLogIndex $scope)
    $newThread='3d5d7adf-6c03-4807-95a2-f851ae3f6001'
    $today=(Get-Date).ToString('yyyy/MM/dd',[Globalization.CultureInfo]::InvariantCulture)
    Write-Fixture 'logs/exec-late.jsonl' (@{type='thread.started';thread_id=$newThread} | ConvertTo-Json -Compress)
    if ((Get-BoardWorkerLogIndex $scope | Where-Object Card -eq 'late').Session -ne 'work-herdr') {
        throw 'A shared log without available launch metadata must default to Work.'
    }
    Write-Fixture "sessions/$today/rollout-fixture-$newThread.jsonl" (@{type='session_meta';payload=@{cwd=$alphaPath}} | ConvertTo-Json -Depth 3 -Compress)
    if ((Get-BoardWorkerLogIndex $scope | Where-Object Card -eq 'late').Session -ne 'space-alpha') {
        throw 'A cached rollout index hid a newly available working directory.'
    }
    $checks+=2

    "Worker scope checks passed: $checks ($($PSVersionTable.PSVersion))"
} finally {
    Remove-Variable BoardScopeFixtureWorkers -Scope Global -ErrorAction SilentlyContinue
    $env:HERDR_SESSION=$envSession
    $env:HERDR_SOCKET_PATH=$envSocket
    $env:CODEX_HOME=$envCodex
    [Console]::SetOut($consoleOut)
    [Console]::OutputEncoding=$consoleEncoding
    [IO.Directory]::Delete($fixture,$true)
}
